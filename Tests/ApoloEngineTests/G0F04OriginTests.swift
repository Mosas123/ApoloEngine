import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AudioToolbox
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ApoloEngine

/// F04D.4: actual engine bridge with known timestamp origin and an explicit
/// forward discontinuity. Same-rate PCM intentionally isolates the clock
/// from filter latency. A nonempty SWR tail is NOT exercised by this fixture.
final class G0F04OriginTests: XCTestCase {
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
                print("G0_F04D4_NATIVE fixture=\(url.lastPathComponent) start=\(tick) frames=\(n)")
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

    private func bridge(_ url: URL, offset: Double) throws -> Result {
        let decoder = AudioDecoder()
        decoder.limiterEnabled = false
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }
        decoder.startOffsetSeconds = offset
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
                  abs(duration.seconds * 48000 - Double(n)) < 0.001,
                  let desc = CMSampleBufferGetFormatDescription(b),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  asbd.pointee.mSampleRate == 48000, asbd.pointee.mChannelsPerFrame == 2,
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                  asbd.pointee.mBitsPerChannel == 32, asbd.pointee.mBytesPerFrame == 8,
                  (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
                  let block = CMSampleBufferGetDataBuffer(b),
                  CMBlockBufferGetDataLength(block) == n * 8,
                  r.pcm.count+n*2 <= 100000 else { throw LabError.bridge }
            let tick = CMTimeConvertScale(pts, timescale: 48000, method: .roundHalfAwayFromZero).value
            guard abs(pts.seconds * 48000 - Double(tick)) < 0.001 else { throw LabError.bridge }
            var pcm = [Float](repeating: 0, count: n*2)
            let rc = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n*8, destination: $0.baseAddress!)
            }
            guard rc == noErr, pcm.allSatisfy({ $0.isFinite }) else { throw LabError.bridge }
            r.spans.append(Span(start: tick, frames: n))
            r.pcm.append(contentsOf: pcm)
            print("G0_F04D4_BRIDGE fixture=\(url.lastPathComponent) offset=\(offset) start=\(tick) frames=\(n)")
        }
        throw LabError.bound
    }

    func testG0F04D4RealBridgeOrigin() throws {
        let cases: [(String,Int64,[Int64])] = [
            ("zero",0,[]), ("origin",12345,[]), ("gap",0,[2400]),
            ("originGap",12345,[2400])
        ]
        let offsets = [0.0,1.25,0.0007]
        var attempted = 0, observed = 0, pcmExact = 0, clockExact = 0, quantized = 0, errors = 0, values = 0
        for (name,origin,gaps) in cases {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "nut", subdirectory: "Fixtures/G0F04D4"))
            let raw = try native(url)
            let refURL = try XCTUnwrap(Bundle.module.url(forResource: "source", withExtension: "s16", subdirectory: "Fixtures/G0F04D4"))
            let bytes = try Data(contentsOf: refURL)
            let expected = bytes.withUnsafeBytes { p in
                (0..<(bytes.count/2)).map { Float(Int16(littleEndian: p.loadUnaligned(fromByteOffset:$0*2,as:Int16.self)))/32768 }
            }
            guard raw.pcm.count == 16391*2, raw.pcm == expected,
                  raw.spans.first?.start == origin, raw.gaps == gaps else {
                print("G0_F04D4_FIXTURE_MISMATCH fixture=\(name) origin=\(raw.spans.first?.start ?? -1) gaps=\(raw.gaps) samples=\(raw.pcm.count/2)")
                throw LabError.frame
            }
            for offset in offsets {
                attempted += 1
                do {
                    let actual = try bridge(url, offset: offset)
                    let shift = CMTimeConvertScale(CMTime(seconds: offset, preferredTimescale: 600), timescale: 48000, method: .roundHalfAwayFromZero).value
                    let requested = offset * 48000
                    let offsetError = Double(shift) - requested
                    if abs(offsetError) > 0.5 { quantized += 1 }
                    let exact = raw.pcm.count == actual.pcm.count && zip(raw.pcm,actual.pcm).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
                    let sameClock = raw.spans.count == actual.spans.count && zip(raw.spans,actual.spans).allSatisfy { $0.0.start+shift == $0.1.start && $0.0.frames == $0.1.frames }
                    if exact { pcmExact += 1; values += raw.pcm.count }
                    if sameClock { clockExact += 1 }
                    observed += 1
                    print("G0_F04D4_CASE fixture=\(name) offset=\(offset) requestedTicks=\(requested) offsetTicks=\(shift) offsetError=\(offsetError) nativeFirst=\(raw.spans.first?.start ?? -1) bridgeFirst=\(actual.spans.first?.start ?? -1) nativeEnd=\(raw.end) bridgeEnd=\(actual.end) nativeGaps=\(raw.gaps) bridgeGaps=\(actual.gaps) samples=\(actual.pcm.count/2) buffers=\(actual.spans.count) streamTB=\(raw.timeBase) streamStart=\(raw.start) pcmExact=\(exact) clockExact=\(sameClock) pcmSHA256=\(hash(actual.pcm)) eof=true")
                } catch {
                    errors += 1
                    print("G0_F04D4_ERROR fixture=\(name) offset=\(offset) error=\(error)")
                }
            }
        }
        print("G0_F04D4_SUMMARY attempted=\(attempted) observed=\(observed) pcmExact=\(pcmExact) clockExact=\(clockExact) offsetQuantized=\(quantized) comparedValues=\(values) errors=\(errors)")
        XCTAssertEqual(attempted,12)
        XCTAssertEqual(observed,12)
        XCTAssertEqual(pcmExact,12)
        XCTAssertEqual(errors,0)
        // Clock deviations are observations. No claim of nonempty SWR tail,
        // missing PTS fallback, arbitrary seeks or physical renderer behavior.
    }
}
