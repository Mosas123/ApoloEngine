import AetherLibavutil
import AetherLibswresample
import AudioToolbox
import CoreMedia
import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

final class G0F04ChannelTests: XCTestCase {
    private enum LabError: Error { case layout, conversion, fixture, coreMedia }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }

    private func names(_ layout: inout AVChannelLayout) -> [String] {
        (0..<Int(layout.nb_channels)).map { i in
            let id = av_channel_layout_channel_from_index(&layout, UInt32(i))
            var buf = [CChar](repeating: 0, count: 64)
            let rc = buf.withUnsafeMutableBufferPointer {
                av_channel_name($0.baseAddress, $0.count, id)
            }
            return rc >= 0 ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "unknown"
        }
    }

    private func fixture(mask: UInt32, channels: Int, frames: Int, pcm: [Int16]) -> Data {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func put<T: FixedWidthInteger>(_ x: T) {
            var value = x.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        let size = frames * channels * 2
        ascii("RIFF"); put(UInt32(60 + size)); ascii("WAVE")
        ascii("fmt "); put(UInt32(40)); put(UInt16(0xfffe))
        put(UInt16(channels)); put(UInt32(48000)); put(UInt32(48000 * channels * 2))
        put(UInt16(channels * 2)); put(UInt16(16)); put(UInt16(22)); put(UInt16(16)); put(mask)
        // KSDATAFORMAT_SUBTYPE_PCM GUID in RIFF byte order.
        data.append(contentsOf: [1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113])
        ascii("data"); put(UInt32(size))
        for x in pcm { put(x) }
        return data
    }

    private func reference(_ pcm: [Int16], channels: Int,
                           input: inout AVChannelLayout, output: inout AVChannelLayout) throws -> [Float] {
        var context: OpaquePointer?
        defer { swr_free(&context) }
        guard swr_alloc_set_opts2(&context, &output, AV_SAMPLE_FMT_FLT, 48000,
                                  &input, AV_SAMPLE_FMT_S16, 48000, 0, nil) >= 0,
              let swr = context, swr_init(swr) >= 0
        else { throw LabError.conversion }
        let frames = pcm.count / channels
        let upper = swr_get_out_samples(swr, Int32(frames))
        guard upper >= Int32(frames), upper <= 8192 else { throw LabError.conversion }
        var out = [Float](repeating: 0, count: Int(upper) * channels)
        let got = pcm.withUnsafeBytes { raw in
            var src: UnsafePointer<UInt8>? = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return out.withUnsafeMutableBytes { dst in
                var ptr: UnsafeMutablePointer<UInt8>? = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return withUnsafePointer(to: &src) { source in
                    withUnsafeMutablePointer(to: &ptr) { dest in
                        swr_convert(swr, dest, upper, source, Int32(frames))
                    }
                }
            }
        }
        guard got == Int32(frames), swr_get_delay(swr, 48000) == 0 else { throw LabError.conversion }
        return Array(out.prefix(Int(got) * channels))
    }

    // Expand the actual tag through the Apple SDK, not a guessed label order.
    private func appleLabels(_ tag: AudioChannelLayoutTag, channels: Int) throws -> [UInt32] {
        var value = tag
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                         UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &value, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size), size <= 4096
        else { throw LabError.layout }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                     UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &value, &size, storage) == noErr
        else { throw LabError.layout }
        let expanded = storage.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        guard expanded.mNumberChannelDescriptions == UInt32(channels),
              let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions),
              offset + channels * MemoryLayout<AudioChannelDescription>.stride <= Int(size)
        else { throw LabError.layout }
        let entries = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<channels).map { entries[$0].mChannelLabel }
    }

    private func engine(_ url: URL, channels: Int, frames: Int) throws -> (pcm: [Float], tag: UInt32, timeline: Bool, asbd: Bool) {
        let decoder = AudioDecoder()
        decoder.limiterEnabled = false
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }
        var pcm: [Float] = [], tag: UInt32?
        var done = false, timeline = true, asbdValid = true
        for _ in 0..<128 {
            guard let b = try decoder.readNextBuffer() else { done = true; break }
            let n = CMSampleBufferGetNumSamples(b)
            guard n > 0, let block = CMSampleBufferGetDataBuffer(b),
                  let desc = CMSampleBufferGetFormatDescription(b),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            else { throw LabError.coreMedia }
            let shape = asbd.pointee
            asbdValid = asbdValid && shape.mSampleRate == 48000
                && shape.mChannelsPerFrame == UInt32(channels) && shape.mBitsPerChannel == 32
                && shape.mFormatID == kAudioFormatLinearPCM && shape.mBytesPerFrame == UInt32(channels * 4)
                && (shape.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && (shape.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            var size = 0
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &size),
                  size >= 12 else { throw LabError.layout }
            let t = layout.pointee.mChannelLayoutTag
            guard tag == nil || tag == t else { throw LabError.layout }
            tag = t
            let stamp = CMSampleBufferGetPresentationTimeStamp(b).seconds
            timeline = timeline && stamp.isFinite && abs(stamp * 48000 - Double(pcm.count / channels)) < 0.001
            let count = n * channels
            guard count <= frames * channels, pcm.count + count <= frames * channels,
                  CMBlockBufferGetDataLength(block) == count * 4 else { throw LabError.fixture }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
            }
            guard status == noErr, chunk.allSatisfy({ $0.isFinite }) else { throw LabError.coreMedia }
            pcm.append(contentsOf: chunk)
        }
        guard done, try decoder.readNextBuffer() == nil, let tag else { throw LabError.coreMedia }
        return (pcm, tag, timeline, asbdValid)
    }

    func testG0F04CChannelMatrixAndAppleLabels() throws {
        // Explicit WAVE speaker masks, including alternatives with equal counts.
        let cases: [(String, UInt32, Int)] = [
            ("mono",0x4,1), ("stereo",0x3,2), ("2.1",0xb,3), ("3.0",0x7,3),
            ("4.0",0x107,4), ("quad",0x33,4),
            ("5.0-back",0x37,5), ("5.0-side",0x607,5),
            ("5.1-back",0x3f,6), ("5.1-side",0x60f,6),
            ("6.1",0x70f,7), ("6.1-back",0x13f,7),
            ("7.1",0x63f,8), ("7.1-wide-back",0xff,8)
        ]
        let slot = 257
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("g0-f04c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var attempted = 0, complete = 0, bridgeExact = 0, identity = 0, expanded = 0, errors = 0
        var compared = 0
        for (name, mask, ch) in cases {
            attempted += 1
            do {
                var input = AVChannelLayout(), output = AVChannelLayout()
                defer { av_channel_layout_uninit(&input); av_channel_layout_uninit(&output) }
                guard av_channel_layout_from_mask(&input, UInt64(mask)) >= 0,
                      input.nb_channels == Int32(ch) else { throw LabError.layout }
                AudioDecoder.makeResamplerOutputLayout(channels: Int32(ch), into: &output)
                let inNames = names(&input), outNames = names(&output)
                let frames = slot * ch
                var pcm = [Int16](repeating: 0, count: frames * ch)
                // Disjoint time slots, each excites exactly one input channel.
                for c in 0..<ch {
                    for i in 0..<slot {
                        pcm[(c * slot + i) * ch + c] = Int16(8192 + (i % 7) * 512)
                    }
                }
                let oracle = pcm.map { Float($0) / 32768 }
                let raw = try reference(pcm, channels: ch, input: &input, output: &output)
                let file = fixture(mask: mask, channels: ch, frames: frames, pcm: pcm)
                let url = root.appendingPathComponent(name + ".wav")
                try file.write(to: url)
                let actual = try engine(url, channels: ch, frames: frames)
                let exact = raw.count == actual.pcm.count && zip(raw, actual.pcm).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
                let same = oracle.count == raw.count && zip(oracle, raw).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
                if exact { bridgeExact += 1; compared += raw.count }
                if same { identity += 1 }
                let labels: String
                do {
                    labels = try appleLabels(actual.tag, channels: ch).map(String.init).joined(separator: ",")
                    expanded += 1
                } catch {
                    labels = "unavailable"
                }
                var matrix: [String] = []
                for c in 0..<ch {
                    let f = c * slot + 128
                    let divisor = Float(pcm[f * ch + c]) / 32768
                    matrix.append((0..<ch).map { String(format: "%.8f", raw[f * ch + $0] / divisor) }.joined(separator: ","))
                }
                if raw.count == frames * ch && actual.pcm.count == frames * ch && actual.timeline && actual.asbd && exact { complete += 1 }
                print("G0_F04C_CASE name=\(name) mask=\(mask) channels=\(ch) input=\(inNames.joined(separator: ",")) output=\(outNames.joined(separator: ",")) appleTag=\(actual.tag) appleLabels=\(labels) frames=\(actual.pcm.count / ch) sourceIdentity=\(same) bridgeExact=\(exact) timeline=\(actual.timeline) asbd=\(actual.asbd) matrix=\(matrix.joined(separator: ";")) pcmSHA256=\(hash(actual.pcm))")
            } catch {
                errors += 1
                print("G0_F04C_ERROR name=\(name) error=\(error)")
            }
        }
        print("G0_F04C_SUMMARY attempted=\(attempted) complete=\(complete) bridgeExact=\(bridgeExact) sourceIdentity=\(identity) appleExpanded=\(expanded) comparedValues=\(compared) errors=\(errors)")
        XCTAssertEqual(attempted, 14)
        XCTAssertEqual(complete, 14)
        XCTAssertEqual(bridgeExact, 14)
        XCTAssertEqual(errors, 0)
        // Semantic label/order and source-rematrix observations are deliberately
        // not equated to PCM bridge success. Review them independently.
    }
}
