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

final class G0F04DynamicTests: XCTestCase {
    private enum LabError: Error { case setup, packet, frame, bound, bridge }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }
    private struct Segment {
        var rate: Int32
        var format: Int32
        var frames: Int = 0
        var samples: Int = 0
        var firstPTS: Int64
        var lastPTS: Int64
        var text: String { "\(rate):\(format):\(frames):\(samples):\(firstPTS):\(lastPTS)" }
    }
    private struct Native {
        var segments: [Segment] = []
        var pcm: [Float] = []
        var streamRate: Int32 = 0
        var timeBase = ""
        var packets = 0
        var seconds: Double { segments.reduce(0) { $0 + Double($1.samples) / Double($1.rate) } }
    }
    private func native(_ url: URL) throws -> Native {
        let source = try OpenedSource.open(url: url)
        defer { source.close() }
        var format = source.takeFormatContext()
        defer { avformat_close_input(&format) }
        guard let ctx = format, ctx.pointee.nb_streams == 1,
              let stream = ctx.pointee.streams[0], let p = stream.pointee.codecpar,
              p.pointee.codec_id == AV_CODEC_ID_AAC,
              let definition = avcodec_find_decoder(p.pointee.codec_id),
              let decoder = avcodec_alloc_context3(definition)
        else { throw LabError.setup }
        var owned: UnsafeMutablePointer<AVCodecContext>? = decoder
        defer { avcodec_free_context(&owned) }
        guard avcodec_parameters_to_context(decoder, p) >= 0,
              avcodec_open2(decoder, definition, nil) >= 0 else { throw LabError.setup }
        var po = av_packet_alloc(), fo = av_frame_alloc()
        defer { av_packet_free(&po); av_frame_free(&fo) }
        guard let packet = po, let frame = fo else { throw LabError.setup }
        let eof: Int32 = -541_478_725
        let again = -Int32(EAGAIN)
        var result = Native()
        result.streamRate = p.pointee.sample_rate
        result.timeBase = "\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den)"
        func drain() throws -> Int32 {
            for _ in 0..<512 {
                let rc = avcodec_receive_frame(decoder, frame)
                if rc == eof || rc == again { return rc }
                guard rc >= 0 else { throw LabError.frame }
                defer { av_frame_unref(frame) }
                let f = frame.pointee
                let n = Int(f.nb_samples)
                // Refuse to invoke the unchanged engine if the shape changes
                // in other dimensions. This first experiment is rate-only.
                guard f.ch_layout.nb_channels == 2, f.sample_rate == 44100 || f.sample_rate == 48000,
                      f.format == AV_SAMPLE_FMT_FLTP.rawValue, n > 0, n <= 4096,
                      result.pcm.count + n * 2 <= 1_000_000,
                      let data = f.extended_data, let left = data[0], let right = data[1]
                else { throw LabError.bound }
                if result.segments.last?.rate != f.sample_rate || result.segments.last?.format != f.format {
                    result.segments.append(Segment(rate: f.sample_rate, format: f.format, firstPTS: f.pts, lastPTS: f.pts))
                }
                let i = result.segments.count - 1
                result.segments[i].frames += 1
                result.segments[i].samples += n
                result.segments[i].lastPTS = f.pts
                for j in 0..<n {
                    let a = UnsafeRawPointer(left).loadUnaligned(fromByteOffset: j * 4, as: Float.self)
                    let b = UnsafeRawPointer(right).loadUnaligned(fromByteOffset: j * 4, as: Float.self)
                    guard a.isFinite, b.isFinite else { throw LabError.frame }
                    result.pcm.append(a); result.pcm.append(b)
                }
                print("G0_F04D1_NATIVE_FRAME fixture=\(url.lastPathComponent) packet=\(result.packets) rate=\(f.sample_rate) samples=\(n) pts=\(f.pts) duration=\(f.duration) format=\(f.format)")
            }
            throw LabError.bound
        }
        for _ in 0..<512 {
            let rc = av_read_frame(ctx, packet)
            if rc == eof {
                let sent = avcodec_send_packet(decoder, nil)
                guard sent >= 0 || sent == eof, try drain() == eof, !result.pcm.isEmpty else { throw LabError.frame }
                return result
            }
            guard rc >= 0 else { throw LabError.packet }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == 0 else { continue }
            result.packets += 1
            guard avcodec_send_packet(decoder, packet) >= 0 else { throw LabError.packet }
            _ = try drain()
        }
        throw LabError.bound
    }

    private struct Bridge {
        var pcm: [Float] = []
        var rates: Set<Int> = []
        var first: Double?
        var end: Double?
        var duration = 0.0
        var gaps = 0
        var maxGap = 0.0
        var buffers = 0
    }
    private func bridge(_ url: URL) throws -> Bridge {
        let decoder = AudioDecoder()
        decoder.limiterEnabled = false
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }
        var r = Bridge()
        for _ in 0..<512 {
            guard let buffer = try decoder.readNextBuffer() else {
                guard try decoder.readNextBuffer() == nil, !r.pcm.isEmpty else { throw LabError.bridge }
                return r
            }
            let n = CMSampleBufferGetNumSamples(buffer)
            guard n > 0, n <= 8192,
                  let desc = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  asbd.pointee.mChannelsPerFrame == 2,
                  asbd.pointee.mBitsPerChannel == 32,
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                  asbd.pointee.mBytesPerFrame == 8,
                  (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
                  let block = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferGetDataLength(block) == n * 8,
                  r.pcm.count + n * 2 <= 1_000_000 else { throw LabError.bridge }
            let rate = asbd.pointee.mSampleRate
            guard rate == 44100 || rate == 48000 else { throw LabError.bridge }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let duration = CMSampleBufferGetDuration(buffer).seconds
            guard pts.isFinite, duration.isFinite, abs(duration - Double(n)/rate) < 1e-8 else { throw LabError.bridge }
            if r.first == nil { r.first = pts }
            if let end = r.end {
                let gap = abs(pts - end)
                if gap > 0.5 / rate { r.gaps += 1 }
                r.maxGap = max(r.maxGap, gap)
            }
            r.end = pts + duration
            r.duration += duration
            r.rates.insert(Int(rate)); r.buffers += 1
            var pcm = [Float](repeating: 0, count: n * 2)
            let status = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 8, destination: $0.baseAddress!)
            }
            guard status == noErr, pcm.allSatisfy({ $0.isFinite }) else { throw LabError.bridge }
            r.pcm.append(contentsOf: pcm)
            print("G0_F04D1_BRIDGE_FRAME fixture=\(url.lastPathComponent) index=\(r.buffers) rate=\(rate) samples=\(n) pts=\(pts) duration=\(duration)")
        }
        throw LabError.bound
    }

    func testG0F04D1DynamicRateObservation() throws {
        let cases: [(String,[Int32])] = [
            ("constant441", [44100]), ("constant480", [48000]),
            ("switch441to480", [44100,48000]), ("switch480to441", [48000,44100])
        ]
        var observed = 0, switched = 0, controls = 0, errors = 0
        for (name, expectedRates) in cases {
            do {
                let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "aac", subdirectory: "Fixtures/G0F04D1"))
                let raw = try native(url)
                let sequence = raw.segments.map { $0.rate }
                guard sequence == expectedRates else {
                    print("G0_F04D1_UNEXPECTED fixture=\(name) expected=\(expectedRates) actual=\(sequence)")
                    throw LabError.frame
                }
                if expectedRates.count > 1 { switched += 1 }
                let actual = try bridge(url)
                let equalCount = raw.pcm.count == actual.pcm.count
                var different = -1, peak = Double.infinity
                if equalCount {
                    different = 0; peak = 0
                    for (a,b) in zip(raw.pcm,actual.pcm) {
                        if a.bitPattern != b.bitPattern { different += 1 }
                        peak = max(peak, abs(Double(a)-Double(b)))
                    }
                }
                let delta = actual.duration - raw.seconds
                if expectedRates.count == 1 && different == 0 && abs(delta) < 1e-8 && actual.gaps == 0 { controls += 1 }
                observed += 1
                print("G0_F04D1_CASE fixture=\(name) streamRate=\(raw.streamRate) streamTB=\(raw.timeBase) nativeSegments=\(raw.segments.map { $0.text }.joined(separator: ";")) nativeSamples=\(raw.pcm.count/2) nativeSeconds=\(raw.seconds) bridgeRates=\(actual.rates.sorted()) bridgeSamples=\(actual.pcm.count/2) bridgeSeconds=\(actual.duration) durationDelta=\(delta) bridgeFirst=\(actual.first ?? -1) bridgeEnd=\(actual.end ?? -1) gaps=\(actual.gaps) maxGap=\(actual.maxGap) different=\(different) peak=\(peak) nativeSHA256=\(hash(raw.pcm)) bridgeSHA256=\(hash(actual.pcm)) eof=true")
            } catch {
                errors += 1
                print("G0_F04D1_ERROR fixture=\(name) error=\(error)")
            }
        }
        print("G0_F04D1_SUMMARY attempted=4 observed=\(observed) nativeSwitches=\(switched) constantControls=\(controls) errors=\(errors)")
        XCTAssertEqual(observed, 4)
        XCTAssertEqual(switched, 2)
        XCTAssertEqual(controls, 2)
        XCTAssertEqual(errors, 0)
        // Dynamic discrepancies are diagnostic observations, not suppressed
        // production assertions; do not claim a dynamic-format fix.
    }
}
