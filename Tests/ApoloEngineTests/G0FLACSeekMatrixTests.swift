import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

/// B03 correctness matrix using the *linked* FFmpeg binaries, not the CLI
/// used solely for generating the identical paired input fixtures.
/// An observed decoder or seek failure fails the diagnostic job explicitly;
/// it does NOT change ApoloEngine or propose a playback workaround.
final class G0FLACSeekMatrixTests: XCTestCase {
    private enum MatrixError: Error {
        case invalidFixture
        case missingFormatContext
        case missingStream
        case missingPacket
        case missingPCM
        case invalidTimestamp
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1",
            "B03 correctness matrix runs only in the isolated lab workflow"
        )
    }

    private func fixture(_ tag: String, withSeektable: Bool) throws -> URL {
        let suffix = withSeektable ? "table" : "no_table"
        return try XCTUnwrap(
            Bundle.module.url(
                forResource: "seek_\(tag)_\(suffix)",
                withExtension: "flac",
                subdirectory: "Fixtures/G0"
            ),
            "Missing generated G0 fixture \(tag) \(suffix)"
        )
    }

    /// Same API and bounds used by ApoloEngine; records raw FFmpeg return codes
    /// without modifying AudioDecoder's public interface.
    private func rawSeek(
        url: URL,
        seconds: Double,
        useAvSeekFrame: Bool
    ) throws -> (code: Int32, packetPTS: Int64?) {
        let source = try OpenedSource.open(url: url)
        var owned: UnsafeMutablePointer<AVFormatContext>? = source.takeFormatContext()
        defer { avformat_close_input(&owned) }
        guard let context = owned else { throw MatrixError.missingFormatContext }
        guard let index = source.info.audioTracks.first?.index,
              index >= 0,
              let stream = context.pointee.streams[index],
              stream.pointee.time_base.num > 0,
              stream.pointee.time_base.den > 0
        else { throw MatrixError.missingStream }

        let tb = stream.pointee.time_base
        let ticks = Int64(seconds / (Double(tb.num) / Double(tb.den)))
        let streamIndex = Int32(index)
        let code: Int32
        if useAvSeekFrame {
            code = av_seek_frame(context, streamIndex, ticks, AVSEEK_FLAG_BACKWARD)
        } else {
            code = avformat_seek_file(
                context, streamIndex, Int64.min, ticks, Int64.max,
                AVSEEK_FLAG_BACKWARD
            )
        }
        guard code >= 0 else { return (code, nil) }

        var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&ownedPacket) }
        guard let packet = ownedPacket else { throw MatrixError.missingPacket }
        var pts: Int64?
        for _ in 0..<64 {
            let rc = av_read_frame(context, packet)
            if rc < 0 { break }
            if packet.pointee.stream_index == streamIndex {
                let t = packet.pointee.pts != Int64.min
                    ? packet.pointee.pts : packet.pointee.dts
                if t != Int64.min { pts = t }
                av_packet_unref(packet)
                break
            }
            av_packet_unref(packet)
        }
        return (code, pts)
    }

    /// Independently decodes raw AVFrames after the exact avformat_seek_file
    /// call. This is diagnosis, not a competing player or proposed fix.
    /// Track frames that straddle the target but which the production
    /// AudioDecoder append() rule would discard in their entirety.
    private func traceDecodedFrames(url: URL, seconds: Double) throws -> String {
        let source = try OpenedSource.open(url: url)
        var ownedFormat = source.takeFormatContext()
        defer { avformat_close_input(&ownedFormat) }
        guard let context = ownedFormat,
              let index = source.info.audioTracks.first?.index,
              index >= 0,
              let stream = context.pointee.streams[index],
              let codecParameters = stream.pointee.codecpar,
              stream.pointee.time_base.num > 0,
              stream.pointee.time_base.den > 0
        else { throw MatrixError.missingStream }

        guard let decoder = avcodec_find_decoder(codecParameters.pointee.codec_id),
              let allocated = avcodec_alloc_context3(decoder)
        else { return "codecSetup=unavailable" }
        var ownedDecoder: UnsafeMutablePointer<AVCodecContext>? = allocated
        defer { avcodec_free_context(&ownedDecoder) }
        let copied = avcodec_parameters_to_context(allocated, codecParameters)
        guard copied >= 0 else { return "codecSetup=parametersError(\(copied))" }
        let opened = avcodec_open2(allocated, decoder, nil)
        guard opened >= 0 else { return "codecSetup=openError(\(opened))" }

        let timeBase = stream.pointee.time_base
        let targetTicks = Int64(seconds / (Double(timeBase.num) / Double(timeBase.den)))
        let seekCode = avformat_seek_file(
            context, Int32(index), Int64.min, targetTicks, Int64.max,
            AVSEEK_FLAG_BACKWARD
        )
        guard seekCode >= 0 else { return "seekCode=\(seekCode) frames=notAttempted" }

        var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var ownedFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&ownedPacket)
            av_frame_free(&ownedFrame)
        }
        guard let packet = ownedPacket else { throw MatrixError.missingPacket }
        guard let frame = ownedFrame else { return "frameAlloc=failed" }

        var decodedCount = 0
        var discardedWholeFrames = 0
        var wouldDropCovering = 0
        var firstOverlapping: String = "none"
        var firstRetainedPTS: String = "none"
        var lastFrame: String = "none"
        var effectiveTargetSample: Int64?
        var requestedSampleNearest: Int64?
        var droppedTargetTailSamples: Int64?
        var firstWouldRetainSample: Int64?
        var readEndCode: Int32 = 0
        var sendError: Int32 = 0

        func consumeReadyFrames() {
            while avcodec_receive_frame(allocated, frame) >= 0 {
                defer { av_frame_unref(frame) }
                decodedCount += 1
                let rate = frame.pointee.sample_rate > 0
                    ? frame.pointee.sample_rate : codecParameters.pointee.sample_rate
                guard rate > 0, frame.pointee.pts != Int64.min else { continue }
                let start = Double(frame.pointee.pts)
                    * Double(timeBase.num) / Double(timeBase.den)
                let count = Int(frame.pointee.nb_samples)
                let end = start + Double(count) / Double(rate)
                // Compute on the exact sample grid of the decoded frame.
                // The engine quantizes a requested second to Int64 stream
                // ticks before seeking; capture BOTH requested and effective.
                let sampleTimebase = AVRational(num: 1, den: rate)
                let startSample = av_rescale_q(
                    frame.pointee.pts, timeBase, sampleTimebase
                )
                let targetSample = av_rescale_q(
                    targetTicks, timeBase, sampleTimebase
                )
                let endSample = startSample + Int64(count)
                effectiveTargetSample = targetSample
                requestedSampleNearest = Int64(
                    (seconds * Double(rate)).rounded()
                )
                if startSample < targetSample && endSample > targetSample
                    && droppedTargetTailSamples == nil {
                    // These are decoded PCM samples that would survive a
                    // sample-granular trim but are dropped by the current
                    // whole-frame rule. Not measured audible lost samples.
                    droppedTargetTailSamples = endSample - targetSample
                }
                if startSample >= targetSample
                    && firstWouldRetainSample == nil {
                    firstWouldRetainSample = startSample
                }
                lastFrame = String(
                    format: "start=%.9f end=%.9f samples=%d", start, end, count
                )
                // Half-open frame interval [start, end); this is a nominal
                // timestamp window, not a bit-perfect PCM comparison.
                if start <= seconds && end > seconds && firstOverlapping == "none" {
                    firstOverlapping = lastFrame
                }
                if start < seconds {
                    discardedWholeFrames += 1
                    if end > seconds { wouldDropCovering += 1 }
                } else if firstRetainedPTS == "none" {
                    firstRetainedPTS = String(format: "%.9f", start)
                }
            }
        }

        for _ in 0..<512 {
            let readCode = av_read_frame(context, packet)
            if readCode < 0 {
                readEndCode = readCode
                sendError = avcodec_send_packet(allocated, nil)
                consumeReadyFrames()
                break
            }
            if packet.pointee.stream_index == Int32(index) {
                let code = avcodec_send_packet(allocated, packet)
                if code < 0 { sendError = code }
                consumeReadyFrames()
            }
            av_packet_unref(packet)
        }

        return "seekCode=\(seekCode) decodedFrames=\(decodedCount) "
            + "discardedWhole=\(discardedWholeFrames) "
            + "droppedTargetCovering=\(wouldDropCovering) "
            + "targetFrame={\(firstOverlapping)} "
            + "firstWouldRetainPTS=\(firstRetainedPTS) "
            + "effectiveTargetSample=\(effectiveTargetSample.map(String.init) ?? "none") "
            + "requestedSampleNearest=\(requestedSampleNearest.map(String.init) ?? "none") "
            + "droppedTargetTailSamples=\(droppedTargetTailSamples.map(String.init) ?? "none") "
            + "firstWouldRetainSample=\(firstWouldRetainSample.map(String.init) ?? "none") "
            + "lastFrame={\(lastFrame)} readEnd=\(readEndCode) "
            + "sendError=\(sendError)"
    }

    private func engineSeek(url: URL, seconds: Double) throws -> (Double, Int) {
        let source = try OpenedSource.open(url: url)
        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }
        guard try decoder.readNextBuffer() != nil else {
            throw MatrixError.missingPCM
        }
        try decoder.seek(to: seconds)
        guard let sample = try decoder.readNextBuffer() else {
            throw MatrixError.missingPCM
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard pts.isFinite else { throw MatrixError.invalidTimestamp }
        return (pts, CMSampleBufferGetNumSamples(sample))
    }

    func testG0B03FLACSeek32Cases() throws {
        let durations: [(tag: String, seconds: Double)] = [
            ("025", 0.25), ("050", 0.50),
            ("200", 2.0), ("1000", 10.0),
        ]
        let positions: [(label: String, fraction: Double)] = [
            ("start", 0.0), ("quarter", 0.25),
            ("middle", 0.50), ("near-end", 0.90),
        ]
        var attempted = 0
        var failures: [String] = []
        for item in durations {
            for seektable in [false, true] {
                let url = try fixture(item.tag, withSeektable: seektable)
                for position in positions {
                    let target = item.seconds * position.fraction
                    let caseID = "duration=\(item.seconds) table=\(seektable) "
                        + "position=\(position.label) target=\(target)"
                    attempted += 1
                    let native: String
                    let alternate: String
                    let swift: String
                    var failure = false
                    do {
                        let result = try rawSeek(
                            url: url, seconds: target, useAvSeekFrame: false
                        )
                        native = "code=\(result.code) firstPacketPTS="
                            + "\(result.packetPTS.map(String.init) ?? "none")"
                        if result.code < 0 { failure = true }
                    } catch {
                        native = "error=\(error)"
                        failure = true
                    }
                    do {
                        let result = try rawSeek(
                            url: url, seconds: target, useAvSeekFrame: true
                        )
                        alternate = "code=\(result.code) firstPacketPTS="
                            + "\(result.packetPTS.map(String.init) ?? "none")"
                    } catch {
                        alternate = "error=\(error)"
                    }
                    do {
                        let (pts, count) = try engineSeek(url: url, seconds: target)
                        swift = "firstPCMPTS=\(String(format: "%.9f", pts)) frames=\(count)"
                        if count <= 0 { failure = true }
                    } catch {
                        swift = "error=\(error)"
                        failure = true
                    }
                    let frameEvidence: String
                    do {
                        frameEvidence = try traceDecodedFrames(url: url, seconds: target)
                    } catch {
                        frameEvidence = "traceError=\(error)"
                    }
                    print("G0_B03_FRAMES \(caseID) \(frameEvidence)")
                    print(
                        "G0_B03 \(caseID) avformat_seek_file=\(native) "
                            + "av_seek_frame=\(alternate) ApoloEngine=\(swift) "
                            + "outcome=\(failure ? "failure" : "success")"
                    )
                    if failure { failures.append(caseID) }
                }
            }
        }
        print(
            "G0_B03_SUMMARY attempted=\(attempted) failed=\(failures.count) "
                + "status=\(failures.isEmpty ? "clear" : "open")"
        )
        XCTAssertEqual(attempted, 32)
        XCTAssertTrue(
            failures.isEmpty,
            "G0-B03 remains OPEN: \(failures.count)/32 FLAC seek cases failed; "
                + "inspect G0_B03 lines. No production fixes are allowed in this PR."
        )
    }
}
