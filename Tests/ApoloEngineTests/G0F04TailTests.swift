import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import AudioToolbox
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ApoloEngine

/// F04D.5: actual bridge under a lab-only output-rate override.
/// All conversion, append, timestamp and EOF methods are unchanged.
final class G0F04TailTests: XCTestCase {
    private enum LabError: Error { case setup, frame, packet, bound, bridge }
    private struct Span {
        let start: Int64
        let frames: Int
    }
    private struct Result {
        var spans: [Span] = []
        var pcm: [Float] = []
        var timeBase = ""
        var start: Int64 = 0
        var end: Int64 { spans.last.map { $0.start + Int64($0.frames) } ?? 0 }
        var gaps: [Int64] {
            zip(spans, spans.dropFirst()).map { $1.start - ($0.start + Int64($0.frames)) }.filter { $0 != 0 }
        }
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }
    private func native(_ url: URL) throws -> Result {
        let source = try OpenedSource.open(url: url)
        defer { source.close() }
        var format = source.takeFormatContext()
        defer { avformat_close_input(&format) }
        guard let ctx = format, ctx.pointee.nb_streams == 1,
              let stream = ctx.pointee.streams[0], let par = stream.pointee.codecpar,
              par.pointee.codec_id == AV_CODEC_ID_PCM_S16LE,
              par.pointee.sample_rate == 48000, par.pointee.ch_layout.nb_channels == 2,
              let definition = avcodec_find_decoder(par.pointee.codec_id),
              let decoder = avcodec_alloc_context3(definition)
        else { throw LabError.setup }
        var owner: UnsafeMutablePointer<AVCodecContext>? = decoder
        defer { avcodec_free_context(&owner) }
        guard avcodec_parameters_to_context(decoder, par) >= 0,
              avcodec_open2(decoder, definition, nil) >= 0 else { throw LabError.setup }
        var po = av_packet_alloc(), fo = av_frame_alloc()
        defer { av_packet_free(&po); av_frame_free(&fo) }
        guard let packet = po, let frame = fo else { throw LabError.setup }
        let eof: Int32 = -541_478_725, again = -Int32(EAGAIN)
        let tb = stream.pointee.time_base
        var r = Result()
        r.timeBase = "\(tb.num)/\(tb.den)"
        r.start = stream.pointee.start_time
        func drain() throws -> Int32 {
            for _ in 0..<512 {
                let rc = avcodec_receive_frame(decoder, frame)
                if rc == eof || rc == again { return rc }
                guard rc >= 0 else { throw LabError.frame }
                defer { av_frame_unref(frame) }
                let f = frame.pointee
                let n = Int(f.nb_samples)
                guard n > 0, n <= 16384, f.sample_rate == 48000,
                      f.ch_layout.nb_channels == 2, f.format == AV_SAMPLE_FMT_S16.rawValue,
                      f.pts != Int64.min, r.pcm.count + n * 2 <= 100000,
                      let planes = f.extended_data, let data = planes[0]
                else { throw LabError.bound }
                let tick = av_rescale_q(f.pts, tb, AVRational(num: 1, den: 48000))
                r.spans.append(Span(start: tick, frames: n))
                let p = UnsafeRawPointer(data)
                for i in 0..<(n*2) {
                    r.pcm.append(Float(p.loadUnaligned(fromByteOffset: i*2, as: Int16.self)) / 32768)
                }
                print("G0_F04D5_NATIVE fixture=\(url.lastPathComponent) start=\(tick) frames=\(n)")
            }
            throw LabError.bound
        }
        for _ in 0..<512 {
            let rc = av_read_frame(ctx, packet)
            if rc == eof {
                let sent = avcodec_send_packet(decoder, nil)
                guard sent >= 0 || sent == eof, try drain() == eof, !r.pcm.isEmpty else { throw LabError.frame }
                return r
            }
            guard rc >= 0 else { throw LabError.packet }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == 0 else { continue }
            guard avcodec_send_packet(decoder, packet) >= 0 else { throw LabError.packet }
            _ = try drain()
        }
        throw LabError.bound
    }

    private func bridge(_ url: URL, rate: Int32) throws -> Result {
        guard setenv("APOLO_G0_F04D5_RATE", String(rate), 1) == 0 else { throw LabError.setup }
        defer { unsetenv("APOLO_G0_F04D5_RATE") }
        let decoder = AudioDecoder()
        decoder.limiterEnabled = false
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }
        var r = Result()
        for _ in 0..<512 {
            guard let b = try decoder.readNextBuffer() else {
                guard try decoder.readNextBuffer() == nil, !r.pcm.isEmpty else { throw LabError.bridge }
                return r
            }
            let n = CMSampleBufferGetNumSamples(b)
            let pts = CMSampleBufferGetPresentationTimeStamp(b)
            let duration = CMSampleBufferGetDuration(b)
            guard n > 0, n <= 16384, pts.seconds.isFinite, duration.seconds.isFinite,
                  abs(duration.seconds * Double(rate) - Double(n)) < 0.001,
                  let desc = CMSampleBufferGetFormatDescription(b),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  asbd.pointee.mSampleRate == Double(rate), asbd.pointee.mChannelsPerFrame == 2,
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                  asbd.pointee.mBitsPerChannel == 32, asbd.pointee.mBytesPerFrame == 8,
                  (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
                  let block = CMSampleBufferGetDataBuffer(b),
                  CMBlockBufferGetDataLength(block) == n * 8,
                  r.pcm.count+n*2 <= 100000 else { throw LabError.bridge }
            let tick = CMTimeConvertScale(pts, timescale: rate, method: .roundHalfAwayFromZero).value
            guard abs(pts.seconds * Double(rate) - Double(tick)) < 0.001 else { throw LabError.bridge }
            var pcm = [Float](repeating: 0, count: n*2)
            let rc = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n*8, destination: $0.baseAddress!)
            }
            guard rc == noErr, pcm.allSatisfy({ $0.isFinite }) else { throw LabError.bridge }
            r.spans.append(Span(start: tick, frames: n))
            r.pcm.append(contentsOf: pcm)
            print("G0_F04D5_BRIDGE fixture=\(url.lastPathComponent) outRate=\(rate) start=\(tick) frames=\(n)")
        }
        throw LabError.bound
    }

    private struct Reference {
        var pcm: [Float] = []
        var chunks: [Int] = []
        var tail = 0
        var firstDrain = 0
        var delay: Int64 = 0
    }
    private func reference(_ bytes: Data, spans: [Span], rate: Int32) throws -> Reference {
        var input = AVChannelLayout(), output = AVChannelLayout()
        av_channel_layout_default(&input,2)
        av_channel_layout_default(&output,2)
        defer { av_channel_layout_uninit(&input); av_channel_layout_uninit(&output) }
        var owned: OpaquePointer?
        defer { swr_free(&owned) }
        guard swr_alloc_set_opts2(&owned,&output,AV_SAMPLE_FMT_FLT,rate,
                                  &input,AV_SAMPLE_FMT_S16,48000,0,nil) >= 0,
              let swr = owned, swr_init(swr) >= 0 else { throw LabError.setup }
        var r = Reference()
        func step(_ src: UnsafePointer<UnsafePointer<UInt8>?>?, _ n: Int) throws -> Int {
            let cap = swr_get_out_samples(swr,Int32(n))
            guard cap >= 0, cap <= 65536 else { throw LabError.bound }
            var dst = [Float](repeating:0,count:max(1,Int(cap))*2)
            let rc = dst.withUnsafeMutableBytes { raw -> Int32 in
                var p: UnsafeMutablePointer<UInt8>? = raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
                return withUnsafeMutablePointer(to:&p) { swr_convert(swr,$0,max(1,cap),src,Int32(n)) }
            }
            guard rc >= 0, rc <= max(1,cap) else { throw LabError.frame }
            r.pcm.append(contentsOf:dst.prefix(Int(rc)*2))
            if rc > 0 { r.chunks.append(Int(rc)) }
            return Int(rc)
        }
        var cursor = 0
        try bytes.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
            for s in spans {
                guard cursor+s.frames <= bytes.count/4 else { throw LabError.bound }
                var src: UnsafePointer<UInt8>? = p.advanced(by:cursor*4)
                _ = try withUnsafePointer(to:&src) { try step($0,s.frames) }
                cursor += s.frames
            }
        }
        guard cursor == bytes.count/4 else { throw LabError.bound }
        r.delay = swr_get_delay(swr,48000)
        var terminal = false
        for i in 0..<128 {
            let n = try step(nil,0)
            if i == 0 { r.firstDrain = n }
            r.tail += n
            if n == 0 { terminal = true; break }
        }
        guard terminal, r.pcm.allSatisfy({ $0.isFinite }) else { throw LabError.frame }
        return r
    }

    func testG0F04D5RealBridgeTail() throws {
        let refURL = try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"s16",subdirectory:"Fixtures/G0F04D5"))
        let bytes = try Data(contentsOf:refURL)
        let expected = bytes.withUnsafeBytes { p in
            (0..<(bytes.count/2)).map { Float(Int16(littleEndian:p.loadUnaligned(fromByteOffset:$0*2,as:Int16.self)))/32768 }
        }
        var observed = 0, pcmExact = 0, tailCases = 0, tailExact = 0, controls = 0, values = 0, errors = 0
        for (name,origin) in [("zero",Int64(0)),("origin",Int64(12336))] {
            let url = try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"mka",subdirectory:"Fixtures/G0F04D5"))
            let native = try native(url)
            guard native.pcm == expected, native.pcm.count == 16391*2,
                  native.spans.first?.start == origin, native.gaps.isEmpty else { throw LabError.frame }
            for rate: Int32 in [44100,48000,96000] {
                do {
                    let ref = try reference(bytes,spans:native.spans,rate:rate)
                    let actual = try bridge(url,rate:rate)
                    let exact = ref.pcm.count == actual.pcm.count && zip(ref.pcm,actual.pcm).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
                    if exact { pcmExact += 1; values += ref.pcm.count }
                    let count = actual.pcm.count/2
                    let chunkMatch = ref.chunks == actual.spans.map { $0.frames }
                    let expectedOrigin = av_rescale_q(origin,AVRational(num:1,den:48000),AVRational(num:1,den:rate))
                    let expectedEnd = expectedOrigin+Int64(ref.pcm.count/2)
                    var tailGap: Int64 = 0
                    var tailStart: Int64 = -1
                    var tailMatches = false
                    if ref.tail > 0 {
                        tailCases += 1
                        if let last = actual.spans.last, actual.spans.count >= 2 {
                            let prior = actual.spans[actual.spans.count-2]
                            tailGap = last.start-prior.start-Int64(prior.frames)
                            tailStart = last.start
                            tailMatches = last.frames == ref.tail && exact && chunkMatch
                        }
                        if tailMatches { tailExact += 1 }
                    } else if rate == 48000 && exact && chunkMatch && actual.gaps.isEmpty && actual.end == expectedEnd {
                        controls += 1
                    }
                    observed += 1
                    print("G0_F04D5_CASE fixture=\(name) outRate=\(rate) nativeSamples=\(native.pcm.count/2) referenceSamples=\(ref.pcm.count/2) bridgeSamples=\(count) delayBeforeDrain=\(ref.delay) referenceTail=\(ref.tail) referenceFirstDrain=\(ref.firstDrain) tailExact=\(tailMatches) tailStart=\(tailStart) tailGap=\(tailGap) expectedOrigin=\(expectedOrigin) bridgeFirst=\(actual.spans.first?.start ?? -1) expectedEnd=\(expectedEnd) bridgeEnd=\(actual.end) endError=\(actual.end-expectedEnd) gaps=\(actual.gaps) chunkMatch=\(chunkMatch) pcmExact=\(exact) referenceSHA256=\(hash(ref.pcm)) bridgeSHA256=\(hash(actual.pcm)) eof=true")
                } catch {
                    errors += 1
                    print("G0_F04D5_ERROR fixture=\(name) outRate=\(rate) error=\(error)")
                }
            }
        }
        print("G0_F04D5_SUMMARY attempted=6 observed=\(observed) pcmExact=\(pcmExact) tailCases=\(tailCases) tailExact=\(tailExact) sameRateControls=\(controls) comparedValues=\(values) errors=\(errors)")
        XCTAssertEqual(observed,6)
        XCTAssertEqual(pcmExact,6)
        XCTAssertEqual(tailCases,4)
        XCTAssertEqual(tailExact,4)
        XCTAssertEqual(controls,2)
        XCTAssertEqual(errors,0)
        // Timing deviations remain observations, not a production fix.
    }
}
