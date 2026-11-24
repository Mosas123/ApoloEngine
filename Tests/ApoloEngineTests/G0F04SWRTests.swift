import AetherLibavutil
import AetherLibswresample
import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

/// F04A: isolate the linked SWR numeric conversion before testing CoreMedia,
/// rematrixing or different-rate resampling. All layouts are identical in/out.
final class G0F04SWRTests: XCTestCase {
    private enum LabError: Error { case setup, conversion, bound }
    private enum Kind: String, CaseIterable {
        case u8, s16, s32, f32, f64
        var width: Int {
            switch self {
            case .u8: return 1
            case .s16: return 2
            case .s32, .f32: return 4
            case .f64: return 8
            }
        }
        func format(_ planar: Bool) -> AVSampleFormat {
            switch self {
            case .u8: return planar ? AV_SAMPLE_FMT_U8P : AV_SAMPLE_FMT_U8
            case .s16: return planar ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S16
            case .s32: return planar ? AV_SAMPLE_FMT_S32P : AV_SAMPLE_FMT_S32
            case .f32: return planar ? AV_SAMPLE_FMT_FLTP : AV_SAMPLE_FMT_FLT
            case .f64: return planar ? AV_SAMPLE_FMT_DBLP : AV_SAMPLE_FMT_DBL
            }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func bytes<T>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    private func scalar(_ kind: Kind, frame: Int, channel: Int) -> ([UInt8], Float) {
        // Boundary and tiny values, distinct per channel. Input bytes are exact;
        // expected Float32 is independently computed from the integer or double.
        let i = (frame + channel * 13) % 17
        let values: [Int32] = [Int32.min, Int32.max, -1, 0, 1, -256, 256,
                               -65536, 65536, -16777217, 16777217,
                               -1073741824, 1073741824, -2147483392,
                               2147483392, -123456789, 987654321]
        let v = values[i]
        switch kind {
        case .u8:
            let x = UInt8(Int(v >> 24) + 128)
            return ([x], Float(Int(x) - 128) / 128)
        case .s16:
            let x = Int16(v >> 16)
            return (bytes(x), Float(x) / 32768)
        case .s32:
            return (bytes(v), Float(Double(v) / 2147483648))
        case .f32:
            let x = Float(Double(v) / 2147483648)
            return (bytes(x), x)
        case .f64:
            let x = Double(v) / 2147483648
            return (bytes(x), Float(x))
        }
    }

    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }

    private func measure(kind: Kind, planar: Bool, rate: Int32, channels: Int) throws -> (Int, Int, Double, String, Int64, Int) {
        var input = AVChannelLayout()
        var output = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &input)
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &output)
        defer {
            av_channel_layout_uninit(&input)
            av_channel_layout_uninit(&output)
        }
        var context: OpaquePointer?
        defer { swr_free(&context) }
        guard swr_alloc_set_opts2(&context, &output, AV_SAMPLE_FMT_FLT, rate,
                                  &input, kind.format(planar), rate, 0, nil) >= 0,
              let swr = context, swr_init(swr) >= 0
        else { throw LabError.setup }
        var actual: [Float] = [], expected: [Float] = []
        var cursor = 0
        var maxDelay: Int64 = 0
        func convert(_ source: UnsafePointer<UnsafePointer<UInt8>?>?, _ count: Int32) throws -> Int {
            let upper = swr_get_out_samples(swr, count)
            guard upper >= 0, upper <= 8192 else { throw LabError.bound }
            let capacity = max(Int(upper), 1)
            var chunk = [Float](repeating: 0, count: capacity * channels)
            let got = chunk.withUnsafeMutableBytes { dst -> Int32 in
                var ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self) as UnsafeMutablePointer<UInt8>?
                return withUnsafeMutablePointer(to: &ptr) {
                    swr_convert(swr, $0, Int32(capacity), source, count)
                }
            }
            guard got >= 0, got <= Int32(capacity) else { throw LabError.conversion }
            actual.append(contentsOf: chunk.prefix(Int(got) * channels))
            maxDelay = max(maxDelay, swr_get_delay(swr, Int64(rate)))
            return Int(got)
        }
        for n in [1, 7, 31, 64, 154] {
            var data = [UInt8](repeating: 0, count: n * channels * kind.width)
            for f in 0..<n {
                for c in 0..<channels {
                    let (b, x) = scalar(kind, frame: cursor + f, channel: c)
                    expected.append(x)
                    let offset = (planar ? c * n + f : f * channels + c) * kind.width
                    data.replaceSubrange(offset..<(offset + kind.width), with: b)
                }
            }
            _ = try data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let planes: [UnsafePointer<UInt8>?] = (0..<(planar ? channels : 1)).map {
                    base.advanced(by: $0 * n * kind.width)
                }
                return try planes.withUnsafeBufferPointer {
                    try convert($0.baseAddress, Int32(n))
                }
            }
            cursor += n
        }
        var tail = 0
        var drained = false
        for _ in 0..<16 {
            let got = try convert(nil, 0)
            tail += got
            if got == 0 { drained = true; break }
        }
        guard drained, actual.allSatisfy({ $0.isFinite }) else { throw LabError.bound }
        var different = -1, peak = Double.infinity
        if actual.count == expected.count {
            different = 0; peak = 0
            for (a, b) in zip(actual, expected) {
                if a.bitPattern != b.bitPattern { different += 1 }
                peak = max(peak, abs(Double(a) - Double(b)))
            }
        }
        return (actual.count / channels, different, peak, hash(actual), maxDelay, tail)
    }

    func testG0F04ASameRateNumericIdentity() throws {
        var attempted = 0, exact = 0, errors = 0, values = 0
        let rates: [Int32] = [44100, 48000, 96000, 192000]
        for rate in rates {
            for channels in [1, 2, 6, 8] {
                for kind in Kind.allCases {
                    for planar in [false, true] {
                        attempted += 1
                        let label = "rate=\(rate) channels=\(channels) format=\(kind.rawValue) planar=\(planar)"
                        do {
                            let (frames, different, peak, digest, delay, tail) = try measure(kind: kind, planar: planar, rate: rate, channels: channels)
                            let ok = frames == 257 && different == 0 && delay == 0 && tail == 0
                            if ok { exact += 1; values += frames * channels }
                            print("G0_F04A_CASE \(label) frames=\(frames) different=\(different) peak=\(peak) pcmSHA256=\(digest) maxDelay=\(delay) tail=\(tail) exact=\(ok)")
                        } catch {
                            errors += 1
                            print("G0_F04A_ERROR \(label) error=\(error)")
                        }
                    }
                }
            }
        }
        print("G0_F04A_SUMMARY attempted=\(attempted) exact=\(exact) comparedValues=\(values) errors=\(errors)")
        XCTAssertEqual(attempted, 160)
        XCTAssertEqual(exact, 160)
        XCTAssertEqual(values, 174760)
        XCTAssertEqual(errors, 0)
    }
}
