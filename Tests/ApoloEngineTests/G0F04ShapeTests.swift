import AetherLibavutil
import AetherLibswresample
import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

/// F04D.2: metadata-aware public API controls only. Never submit mismatched
/// plane pointers to the production raw swr_convert path.
final class G0F04ShapeTests: XCTestCase {
    private enum LabError: Error { case allocation, layout, format, conversion }
    private struct Shape {
        let name: String
        let mask: UInt64
        let format: AVSampleFormat
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func setup(_ frame: UnsafeMutablePointer<AVFrame>, _ shape: Shape, output: Bool) throws {
        frame.pointee.sample_rate = 48000
        frame.pointee.format = output ? AV_SAMPLE_FMT_FLT.rawValue : shape.format.rawValue
        guard av_channel_layout_from_mask(&frame.pointee.ch_layout, shape.mask) >= 0
        else { throw LabError.layout }
    }

    private func fill(_ frame: UnsafeMutablePointer<AVFrame>, _ shape: Shape) throws -> [Float] {
        let n = 257
        frame.pointee.nb_samples = Int32(n)
        guard av_frame_get_buffer(frame, 0) >= 0, let planes = frame.pointee.extended_data
        else { throw LabError.allocation }
        let channels = Int(frame.pointee.ch_layout.nb_channels)
        let planar = av_sample_fmt_is_planar(shape.format) != 0
        let width = Int(av_get_bytes_per_sample(shape.format))
        guard channels > 0, channels <= 8, width == 2 || width == 4 else { throw LabError.format }
        var oracle: [Float] = []
        for i in 0..<n {
            for c in 0..<channels {
                let sample = Int16((i * 113 + c * 997) % 30001 - 15000)
                let x = Float(sample) / 32768
                oracle.append(x)
                guard let plane = planes[planar ? c : 0] else { throw LabError.allocation }
                let ptr = UnsafeMutableRawPointer(plane)
                let offset = (planar ? i : i * channels + c) * width
                if shape.format == AV_SAMPLE_FMT_S16 || shape.format == AV_SAMPLE_FMT_S16P {
                    ptr.storeBytes(of: sample, toByteOffset: offset, as: Int16.self)
                } else if shape.format == AV_SAMPLE_FMT_FLT || shape.format == AV_SAMPLE_FMT_FLTP {
                    ptr.storeBytes(of: x, toByteOffset: offset, as: Float.self)
                } else { throw LabError.format }
            }
        }
        return oracle
    }

    private func extract(_ frame: UnsafeMutablePointer<AVFrame>, expected: Int) throws -> [Float] {
        let n = Int(frame.pointee.nb_samples)
        let ch = Int(frame.pointee.ch_layout.nb_channels)
        guard n == 257, ch > 0, ch <= 8, n * ch == expected,
              frame.pointee.format == AV_SAMPLE_FMT_FLT.rawValue,
              let planes = frame.pointee.extended_data, let plane = planes[0]
        else { throw LabError.conversion }
        let p = UnsafeRawPointer(plane)
        let pcm = (0..<expected).map { p.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        guard pcm.allSatisfy({ $0.isFinite }) else { throw LabError.conversion }
        return pcm
    }

    private func digest(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }

    private func exact(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a,b).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
    }

    private func observe(_ first: Shape, _ next: Shape, changed: Bool) throws -> (Int32, Bool, Bool, Int, String) {
        var a = av_frame_alloc(), b = av_frame_alloc(), oa = av_frame_alloc()
        var stale = av_frame_alloc(), freshOut = av_frame_alloc()
        var current = swr_alloc(), fresh = swr_alloc()
        defer {
            av_frame_free(&a); av_frame_free(&b); av_frame_free(&oa)
            av_frame_free(&stale); av_frame_free(&freshOut)
            swr_free(&current); swr_free(&fresh)
        }
        guard let inputA = a, let inputB = b, let outA = oa, let outStale = stale,
              let outFresh = freshOut, let swr = current, let reset = fresh else { throw LabError.allocation }
        try setup(inputA, first, output: false)
        try setup(inputB, next, output: false)
        try setup(outA, first, output: true)
        try setup(outStale, first, output: true)
        try setup(outFresh, next, output: true)
        let refA = try fill(inputA, first), refB = try fill(inputB, next)
        guard swr_convert_frame(swr, outA, inputA) == 0,
              exact(try extract(outA, expected: refA.count), refA),
              swr_get_delay(swr, 48000) == 0 else { throw LabError.conversion }

        // Output shape unchanged, so only the input-change flag is expected.
        // AVERROR_INPUT_CHANGED == -0x636e6701 in libavutil/error.h.
        let rc = swr_convert_frame(swr, outStale, inputB)
        let rejectedOrExact: Bool
        if changed {
            rejectedOrExact = rc == -0x636e6701 && outStale.pointee.nb_samples == 0
        } else {
            rejectedOrExact = rc == 0 && (try extract(outStale, expected: refB.count)).elementsEqual(refB)
        }
        // Independent fresh context with the next frame's full metadata.
        // This is a control, not an engine reconfiguration implementation.
        guard swr_convert_frame(reset, outFresh, inputB) == 0,
              swr_get_delay(reset, 48000) == 0 else { throw LabError.conversion }
        let pcm = try extract(outFresh, expected: refB.count)
        return (rc, rejectedOrExact, exact(pcm, refB), pcm.count, digest(pcm))
    }

    func testG0F04D2FrameShapeControls() throws {
        let mono = Shape(name:"mono-s16p",mask:0x4,format:AV_SAMPLE_FMT_S16P)
        let stereo = Shape(name:"stereo-s16p",mask:0x3,format:AV_SAMPLE_FMT_S16P)
        let stereoPacked = Shape(name:"stereo-s16",mask:0x3,format:AV_SAMPLE_FMT_S16)
        let floatPlanar = Shape(name:"stereo-fltp",mask:0x3,format:AV_SAMPLE_FMT_FLTP)
        let floatPacked = Shape(name:"stereo-flt",mask:0x3,format:AV_SAMPLE_FMT_FLT)
        let back = Shape(name:"5.1-back-s16p",mask:0x3f,format:AV_SAMPLE_FMT_S16P)
        let side = Shape(name:"5.1-side-s16p",mask:0x60f,format:AV_SAMPLE_FMT_S16P)
        let three = Shape(name:"3.0-s16p",mask:0x7,format:AV_SAMPLE_FMT_S16P)
        let twoOne = Shape(name:"2.1-s16p",mask:0xb,format:AV_SAMPLE_FMT_S16P)
        let cases: [(Shape,Shape,Bool)] = [
            (stereo,stereo,false), (floatPacked,floatPacked,false),
            (mono,stereo,true), (stereo,mono,true),
            (stereo,back,true), (back,stereo,true),
            (back,side,true), (side,back,true),
            (three,twoOne,true), (twoOne,three,true),
            (stereo,stereoPacked,true), (stereoPacked,stereo,true),
            (stereo,floatPlanar,true), (floatPlanar,stereo,true),
            (floatPlanar,floatPacked,true), (floatPacked,floatPlanar,true)
        ]
        var accepted = 0, rejected = 0, unchanged = 0, freshExact = 0, values = 0, errors = 0
        for (a,b,changed) in cases {
            do {
                let (rc, ok, fresh, n, hash) = try observe(a,b,changed:changed)
                if ok { accepted += 1; if changed { rejected += 1 } else { unchanged += 1 } }
                if fresh { freshExact += 1; values += n }
                print("G0_F04D2_CASE from=\(a.name) to=\(b.name) changed=\(changed) staleRC=\(rc) expectedResponse=\(ok) freshExact=\(fresh) scalarValues=\(n) pcmSHA256=\(hash)")
            } catch {
                errors += 1
                print("G0_F04D2_ERROR from=\(a.name) to=\(b.name) error=\(error)")
            }
        }
        print("G0_F04D2_SUMMARY attempted=\(cases.count) accepted=\(accepted) changedRejected=\(rejected) unchanged=\(unchanged) freshExact=\(freshExact) comparedValues=\(values) errors=\(errors)")
        XCTAssertEqual(accepted, 16)
        XCTAssertEqual(rejected, 14)
        XCTAssertEqual(unchanged, 2)
        XCTAssertEqual(freshExact, 16)
        XCTAssertEqual(errors, 0)
    }
}
