import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CryptoKit
import CoreMedia
import AudioToolbox
import Foundation
import Darwin
import XCTest
@testable import ApoloEngine

/// F03B.2: direct linked decoder observations. No playback/timestamp mutation.
final class G0F03BNativeTests: XCTestCase {
    private enum LabError: Error { case invalid, unsupportedFormat, codec, packet, frame, bound }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private struct Result {
        var pcm: [Float] = []
        var packets = 0
        var frames = 0
        var missing = 0
        var discontinuities = 0
        var first: Int64?
        var end: Int64?
        var cursorError: Int64 = 0
        var stepError: Int64 = 0
        var formats: Set<Int32> = []
        var timeBase = ""
        var packetTimeBase = ""
        var decoderName = ""
    }

    private func decode(_ url: URL, codec: String, rate: Int32, channels: Int,
                        maxFrames: Int, control: Bool) throws -> Result {
        let mode = control ? "pktTB" : "original"
        let source = try OpenedSource.open(url: url)
        defer { source.close() }
        var format = source.takeFormatContext()
        defer { avformat_close_input(&format) }
        guard let context = format, context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0], let params = stream.pointee.codecpar,
              String(cString: avcodec_get_name(params.pointee.codec_id)) == codec,
              params.pointee.sample_rate == rate,
              Int(params.pointee.ch_layout.nb_channels) == channels,
              stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0,
              let definition = avcodec_find_decoder(params.pointee.codec_id),
              let decoder = avcodec_alloc_context3(definition)
        else { throw LabError.codec }
        var ownedDecoder: UnsafeMutablePointer<AVCodecContext>? = decoder
        defer { avcodec_free_context(&ownedDecoder) }
        guard avcodec_parameters_to_context(decoder, params) >= 0 else { throw LabError.codec }
        if control { decoder.pointee.pkt_timebase = stream.pointee.time_base }
        guard avcodec_open2(decoder, definition, nil) >= 0 else { throw LabError.codec }
        var packetOwner = av_packet_alloc()
        var frameOwner = av_frame_alloc()
        defer { av_frame_free(&frameOwner); av_packet_free(&packetOwner) }
        guard let packet = packetOwner, let frame = frameOwner else { throw LabError.invalid }

        var result = Result()
        let tb = stream.pointee.time_base
        let pcmTB = AVRational(num: 1, den: rate)
        result.timeBase = "\(tb.num)/\(tb.den)"
        result.packetTimeBase = "\(decoder.pointee.pkt_timebase.num)/\(decoder.pointee.pkt_timebase.den)"
        result.decoderName = String(cString: definition.pointee.name)
        print("G0_F03B2_OPEN fixture=\(url.lastPathComponent) mode=\(mode) decoder=\(result.decoderName) streamTB=\(result.timeBase) packetTB=\(result.packetTimeBase) start=\(stream.pointee.start_time) duration=\(stream.pointee.duration) initialPadding=\(params.pointee.initial_padding) trailingPadding=\(params.pointee.trailing_padding)")
        let eof: Int32 = -541_478_725
        let again = -Int32(EAGAIN)

        func drain() throws -> Int32 {
            for _ in 0..<2048 {
                let rc = avcodec_receive_frame(decoder, frame)
                if rc == eof || rc == again { return rc }
                guard rc >= 0 else { throw LabError.frame }
                defer { av_frame_unref(frame) }
                let v = frame.pointee
                let n = Int(v.nb_samples)
                let fmt = AVSampleFormat(rawValue: v.format)
                guard n > 0, v.sample_rate == rate, Int(v.ch_layout.nb_channels) == channels,
                      result.pcm.count + n * channels <= maxFrames * channels,
                      let planes = v.extended_data else { throw LabError.bound }
                let planar = av_sample_fmt_is_planar(fmt) != 0
                let packed = av_get_packed_sample_fmt(fmt)
                let width = Int(av_get_bytes_per_sample(fmt))
                guard width > 0 else { throw LabError.unsupportedFormat }
                let cursor = Int64(result.pcm.count / channels)
                result.frames += 1
                result.formats.insert(v.format)
                if v.pts == Int64.min {
                    result.missing += 1
                    result.end = nil
                } else {
                    let tick = av_rescale_q(v.pts, tb, pcmTB)
                    guard tick > -1_000_000_000, tick < 1_000_000_000 else { throw LabError.bound }
                    if result.first == nil { result.first = tick }
                    result.cursorError = max(result.cursorError, abs(tick - cursor))
                    if let previous = result.end, previous != tick {
                        result.discontinuities += 1
                        result.stepError = max(result.stepError, abs(tick - previous))
                    }
                    result.end = tick + Int64(n)
                }
                print("G0_F03B2_FRAME fixture=\(url.lastPathComponent) mode=\(mode) packet=\(result.packets) frame=\(result.frames) pts=\(v.pts) bestEffort=\(v.best_effort_timestamp) duration=\(v.duration) samples=\(n) cursor=\(cursor) format=\(v.format)")
                for i in 0..<n {
                    for c in 0..<channels {
                        guard let plane = planes[planar ? c : 0] else { throw LabError.frame }
                        let p = UnsafeRawPointer(plane.advanced(by: (planar ? i : i * channels + c) * width))
                        let x: Float
                        switch packed {
                        case AV_SAMPLE_FMT_U8: x = (Float(p.loadUnaligned(as: UInt8.self)) - 128) / 128
                        case AV_SAMPLE_FMT_S16: x = Float(p.loadUnaligned(as: Int16.self)) / 32768
                        case AV_SAMPLE_FMT_S32: x = Float(Double(p.loadUnaligned(as: Int32.self)) / 2147483648)
                        case AV_SAMPLE_FMT_FLT: x = p.loadUnaligned(as: Float.self)
                        case AV_SAMPLE_FMT_DBL: x = Float(p.loadUnaligned(as: Double.self))
                        default: throw LabError.unsupportedFormat
                        }
                        guard x.isFinite else { throw LabError.frame }
                        result.pcm.append(x)
                    }
                }
            }
            throw LabError.bound
        }

        for _ in 0..<2048 {
            let rc = av_read_frame(context, packet)
            if rc == eof {
                let sent = avcodec_send_packet(decoder, nil)
                guard sent >= 0 || sent == eof, try drain() == eof, !result.pcm.isEmpty else { throw LabError.frame }
                return result
            }
            guard rc >= 0 else { throw LabError.packet }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == 0 else { continue }
            result.packets += 1
            var skip: UInt32 = 0, discard: UInt32 = 0
            if let sides = packet.pointee.side_data {
                for i in 0..<Int(packet.pointee.side_data_elems) {
                    let item = sides[i]
                    if item.type == AV_PKT_DATA_SKIP_SAMPLES, item.size >= 10, let data = item.data {
                        let p = UnsafeRawPointer(data)
                        skip = UInt32(littleEndian: p.loadUnaligned(as: UInt32.self))
                        discard = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    }
                }
            }
            print("G0_F03B2_PACKET fixture=\(url.lastPathComponent) mode=\(mode) index=\(result.packets) pts=\(packet.pointee.pts) dts=\(packet.pointee.dts) duration=\(packet.pointee.duration) skip=\(skip) discard=\(discard)")
            guard avcodec_send_packet(decoder, packet) >= 0 else { throw LabError.packet }
            _ = try drain()
        }
        throw LabError.bound
    }

    private func metrics(_ a: [Float], _ b: [Float]) -> (different: Int, peak: Double, rms: Double) {
        guard a.count == b.count, !a.isEmpty else { return (-1, .infinity, .infinity) }
        var different = 0, peak = 0.0, sum = 0.0
        for (x, y) in zip(a, b) {
            if x.bitPattern != y.bitPattern { different += 1 }
            let delta = abs(Double(x) - Double(y))
            peak = max(peak, delta)
            sum += delta * delta
        }
        return (different, peak, sqrt(sum / Double(a.count)))
    }

    private func digest(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        let hash = bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func testG0F03B2NativePairedObservation() throws {
        let cases: [(String,String,String,Int32,Int,Int,Int)] = [
            ("f03b_mp3_cbr_44100_2_48123","mp3","mp3",44100,2,48123,48123),
            ("f03b_mp3_vbr_48000_1_48017","mp3","mp3",48000,1,48017,48017),
            ("f03b_mp3_no_xing_44100_2_48019","mp3","mp3",44100,2,48019,49536),
            ("f03b_vorbis_q5_44100_2_48123","ogg","vorbis",44100,2,48123,48123),
            ("f03b_vorbis_q4_48000_1_48017","ogg","vorbis",48000,1,48017,47889),
            ("f03b_vorbis_q6_48000_2_48239","ogg","vorbis",48000,2,48239,48111),
            ("f03b_musepack8_sv8_44100_2_48123","mpc","musepack8",44100,2,48123,49536),
            ("f03b_musepack8_sv8_48000_2_48017","mpc","musepack8",48000,2,48017,49536)
        ]
        var complete = 0, hostCountMatches = 0, controlExact = 0, errors = 0, values = 0
        for (name, ext, codec, rate, ch, sourceCount, hostCount) in cases {
            do {
                let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/G0F03B"))
                let refURL = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Fixtures/G0F03B"))
                let bytes = try Data(contentsOf: refURL)
                guard bytes.count == hostCount * ch * 4 else { throw LabError.invalid }
                let host: [Float] = bytes.withUnsafeBytes { p in
                    (0..<(bytes.count / 4)).map {
                        Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self)))
                    }
                }
                guard host.allSatisfy({ $0.isFinite }) else { throw LabError.invalid }
                let raw = try decode(url, codec: codec, rate: rate, channels: ch, maxFrames: sourceCount + 8192, control: false)
                let candidate = try decode(url, codec: codec, rate: rate, channels: ch, maxFrames: sourceCount + 8192, control: true)
                let h = metrics(raw.pcm, host), delta = metrics(raw.pcm, candidate.pcm)
                complete += 1
                if raw.pcm.count == host.count { hostCountMatches += 1 }
                if delta.different == 0 { controlExact += 1; values += raw.pcm.count }
                for (mode, result) in [("original",raw),("pktTB",candidate)] {
                    print("G0_F03B2_NATIVE fixture=\(name) mode=\(mode) decoder=\(result.decoderName) sourceFrames=\(sourceCount) hostFrames=\(hostCount) decodedFrames=\(result.pcm.count/ch) packets=\(result.packets) frames=\(result.frames) formats=\(result.formats.sorted()) first=\(result.first.map(String.init) ?? "none") end=\(result.end.map(String.init) ?? "none") missingPTS=\(result.missing) discontinuities=\(result.discontinuities) cursorError=\(result.cursorError) stepError=\(result.stepError) streamTB=\(result.timeBase) packetTB=\(result.packetTimeBase) pcmSHA256=\(digest(result.pcm)) eof=true")
                }
                print("G0_F03B2_CASE fixture=\(name) hostDifferent=\(h.different) hostPeak=\(h.peak) hostRMS=\(h.rms) controlDifferent=\(delta.different) controlPeak=\(delta.peak) controlRMS=\(delta.rms)")
            } catch {
                errors += 1
                print("G0_F03B2_ERROR fixture=\(name) error=\(error)")
            }
        }
        print("G0_F03B2_SUMMARY attempted=\(cases.count) complete=\(complete) hostCountMatches=\(hostCountMatches) controlExact=\(controlExact) errors=\(errors) comparedValues=\(values)")
        XCTAssertEqual(complete, cases.count)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(hostCountMatches, cases.count, "Host count discrepancy is an observation to investigate, not a production fix.")
        XCTAssertEqual(controlExact, cases.count, "Packet timebase control must not change PCM.")
    }

    /// Observe the actual AudioDecoder -> CMSampleBuffer bridge, without
    /// modifying its clock, decoding policy, trimming or DSP implementation.
    func testG0F03B3CoreMediaBridgeObservation() throws {
        let cases: [(String,String,String,Int32,Int,Int,Int)] = [
            ("f03b_mp3_cbr_44100_2_48123","mp3","mp3",44100,2,48123,48123),
            ("f03b_mp3_vbr_48000_1_48017","mp3","mp3",48000,1,48017,48017),
            ("f03b_mp3_no_xing_44100_2_48019","mp3","mp3",44100,2,48019,49536),
            ("f03b_vorbis_q5_44100_2_48123","ogg","vorbis",44100,2,48123,48123),
            ("f03b_vorbis_q4_48000_1_48017","ogg","vorbis",48000,1,48017,47889),
            ("f03b_vorbis_q6_48000_2_48239","ogg","vorbis",48000,2,48239,48111),
            ("f03b_musepack8_sv8_44100_2_48123","mpc","musepack8",44100,2,48123,49536),
            ("f03b_musepack8_sv8_48000_2_48017","mpc","musepack8",48000,2,48017,49536)
        ]
        var complete = 0, bridgeExact = 0, nativeMatches = 0, errors = 0, compared = 0
        var timelineValid = 0
        for (name, ext, codec, rate, ch, sourceCount, hostCount) in cases {
            do {
                let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/G0F03B"))
                let native = try decode(url, codec: codec, rate: rate, channels: ch, maxFrames: sourceCount + 8192, control: false)
                let source = try OpenedSource.open(url: url)
                defer { source.close() }
                let decoder = AudioDecoder()
                decoder.limiterEnabled = false
                try decoder.adopt(source)
                defer { decoder.close() }

                var pcm: [Float] = []
                var first: Int64?, end: Int64?
                var buffers = 0, invalidPTS = 0, offGrid = 0, negativePTS = 0
                var discontinuities = 0, invalidDuration = 0, durationMismatch = 0
                var cursorError: Int64 = 0, stepError: Int64 = 0
                var eof = false
                for _ in 0..<2048 {
                    guard let sample = try decoder.readNextBuffer() else { eof = true; break }
                    buffers += 1
                    let count = CMSampleBufferGetNumSamples(sample)
                    let cursor = pcm.count / ch
                    guard count > 0, cursor + count <= sourceCount + 8192,
                          let desc = CMSampleBufferGetFormatDescription(sample),
                          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                          let block = CMSampleBufferGetDataBuffer(sample)
                    else { throw LabError.invalid }
                    let shape = asbd.pointee
                    guard shape.mSampleRate == Double(rate),
                          shape.mChannelsPerFrame == UInt32(ch),
                          shape.mFormatID == kAudioFormatLinearPCM,
                          shape.mBitsPerChannel == 32,
                          shape.mBytesPerFrame == UInt32(ch * 4),
                          (shape.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                          (shape.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
                          CMBlockBufferGetDataLength(block) == count * ch * 4
                    else { throw LabError.invalid }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let duration = CMSampleBufferGetDuration(sample)
                    var tick: Int64?
                    if pts.seconds.isFinite, abs(pts.seconds) < 60 {
                        let scaled = pts.seconds * Double(rate)
                        let t = Int64(scaled.rounded())
                        tick = t
                        if first == nil { first = t }
                        if t < 0 { negativePTS += 1 }
                        if abs(scaled - Double(t)) >= 0.001 { offGrid += 1 }
                        cursorError = max(cursorError, abs(t - Int64(cursor)))
                        if let previous = end, previous != t {
                            discontinuities += 1
                            stepError = max(stepError, abs(t - previous))
                        }
                        end = t + Int64(count)
                    } else {
                        invalidPTS += 1
                        end = nil
                    }
                    if duration.seconds.isFinite, duration.seconds > 0 {
                        if abs(duration.seconds * Double(rate) - Double(count)) >= 0.001 {
                            durationMismatch += 1
                        }
                    } else { invalidDuration += 1 }
                    print("G0_F03B3_BUFFER fixture=\(name) index=\(buffers) ptsValue=\(pts.value) ptsScale=\(pts.timescale) tick=\(tick.map(String.init) ?? "none") durationValue=\(duration.value) durationScale=\(duration.timescale) samples=\(count) cursor=\(cursor)")

                    var chunk = [Float](repeating: 0, count: count * ch)
                    let status = chunk.withUnsafeMutableBytes { bytes in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                    }
                    guard status == 0, chunk.allSatisfy({ $0.isFinite }) else { throw LabError.frame }
                    pcm.append(contentsOf: chunk)
                }
                guard eof, !pcm.isEmpty else { throw LabError.bound }
                // A second read documents terminal behavior; do not call again
                // indefinitely if the underlying decoder does not reach EOF.
                let terminal = try decoder.readNextBuffer() == nil
                let difference = metrics(pcm, native.pcm)
                let exact = difference.different == 0
                let strictTimeline = first == 0 && end == Int64(pcm.count / ch)
                    && discontinuities == 0 && invalidPTS == 0 && offGrid == 0
                    && negativePTS == 0 && invalidDuration == 0 && durationMismatch == 0
                complete += 1
                if native.pcm.count == hostCount * ch { nativeMatches += 1 }
                if exact && terminal { bridgeExact += 1; compared += pcm.count }
                if strictTimeline { timelineValid += 1 }
                print("G0_F03B3_NATIVE fixture=\(name) frames=\(native.pcm.count/ch) packets=\(native.packets) decodedBlocks=\(native.frames) missingPTS=\(native.missing) first=\(native.first.map(String.init) ?? "none") end=\(native.end.map(String.init) ?? "none") pcmSHA256=\(digest(native.pcm))")
                print("G0_F03B3_ENGINE fixture=\(name) sourceFrames=\(sourceCount) hostFrames=\(hostCount) engineFrames=\(pcm.count/ch) buffers=\(buffers) first=\(first.map(String.init) ?? "none") end=\(end.map(String.init) ?? "none") invalidPTS=\(invalidPTS) negativePTS=\(negativePTS) offGrid=\(offGrid) discontinuities=\(discontinuities) cursorError=\(cursorError) stepError=\(stepError) invalidDuration=\(invalidDuration) durationMismatch=\(durationMismatch) bridgeDifferent=\(difference.different) bridgePeak=\(difference.peak) bridgeRMS=\(difference.rms) pcmSHA256=\(digest(pcm)) asbdValid=true eof=\(eof) repeatedEOF=\(terminal) timelineValid=\(strictTimeline)")
            } catch {
                errors += 1
                print("G0_F03B3_ERROR fixture=\(name) error=\(error)")
            }
        }
        print("G0_F03B3_SUMMARY attempted=\(cases.count) complete=\(complete) nativeMatches=\(nativeMatches) bridgeExact=\(bridgeExact) timelineValid=\(timelineValid) comparedValues=\(compared) errors=\(errors)")
        XCTAssertEqual(complete, cases.count)
        XCTAssertEqual(nativeMatches, cases.count)
        XCTAssertEqual(bridgeExact, cases.count, "Keep bridge differences or repeated EOF failures visible; do not repair in G0.")
        XCTAssertEqual(compared, 681836)
        XCTAssertEqual(errors, 0)
        // Strict timeline is reported independently, not silently normalized.
    }
}
