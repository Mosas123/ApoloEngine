import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import AudioToolbox
import CoreMedia
import Darwin
import Dispatch
import Foundation
import Network
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

    /// B03-R2: isolate FFmpeg's demuxer seek route from AudioDecoder.
    /// FAST_SEEK must be enabled before avformat_open_input, because
    /// flac_read_header() only imports SEEKTABLE entries under that flag.
    /// Every variant gets a fresh context to avoid contaminated indexes.
    private enum RawSeekVariant: String, CaseIterable {
        case formatUnbounded
        case formatNonnegativeBounds
        case formatAtOrBefore
        case frameBackward
        case frameForward
        case frameAny
    }

    private func probeDemuxerSeek(
        url: URL,
        seconds: Double,
        duration: Double,
        fastSeek: Bool,
        variant: RawSeekVariant
    ) throws -> String {
        var owned = avformat_alloc_context()
        guard let allocated = owned else { throw MatrixError.missingFormatContext }
        if fastSeek {
            allocated.pointee.flags |= Int32(AVFMT_FLAG_FAST_SEEK)
        }
        defer {
            if owned != nil { avformat_close_input(&owned) }
        }
        let openCode = url.path.withCString {
            avformat_open_input(&owned, $0, nil, nil)
        }
        guard openCode >= 0, let context = owned else {
            return "openCode=\(openCode)"
        }
        let infoCode = avformat_find_stream_info(context, nil)
        guard infoCode >= 0 else {
            return "streamInfoCode=\(infoCode)"
        }
        // The fixture generator creates one audio-only FLAC stream.
        guard context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
              stream.pointee.time_base.num > 0,
              stream.pointee.time_base.den > 0
        else { throw MatrixError.missingStream }

        let rate = Double(stream.pointee.time_base.num)
            / Double(stream.pointee.time_base.den)
        let target = Int64(seconds / rate)
        let end = Int64(duration / rate)
        let seekCode: Int32
        switch variant {
        case .formatUnbounded:
            seekCode = avformat_seek_file(
                context, 0, Int64.min, target, Int64.max, AVSEEK_FLAG_BACKWARD
            )
        case .formatNonnegativeBounds:
            seekCode = avformat_seek_file(context, 0, 0, target, end, 0)
        case .formatAtOrBefore:
            seekCode = avformat_seek_file(
                context, 0, Int64.min, target, target, 0
            )
        case .frameBackward:
            seekCode = av_seek_frame(context, 0, target, AVSEEK_FLAG_BACKWARD)
        case .frameForward:
            seekCode = av_seek_frame(context, 0, target, 0)
        case .frameAny:
            seekCode = av_seek_frame(context, 0, target, AVSEEK_FLAG_ANY)
        }

        var readCode: Int32 = Int32.min
        var packetPTS = "none"
        var packetPosition = "none"
        if seekCode >= 0 {
            var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            defer { av_packet_free(&ownedPacket) }
            guard let packet = ownedPacket else { throw MatrixError.missingPacket }
            // A successful return is not necessarily correct media delivery:
            // record the next packet's actual PTS/byte position as evidence.
            readCode = av_read_frame(context, packet)
            if readCode >= 0 {
                packetPTS = String(packet.pointee.pts)
                packetPosition = String(packet.pointee.pos)
            }
        }
        let actualFastSeek = context.pointee.flags & Int32(AVFMT_FLAG_FAST_SEEK)
        return "opened=1 streamInfoCode=\(infoCode) "
            + "timeBase=\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den) "
            + "targetTicks=\(target) endTicks=\(end) "
            + "fastSeekFlag=\(actualFastSeek != 0) "
            + "seekCode=\(seekCode) nextReadCode=\(readCode) "
            + "nextPacketPTS=\(packetPTS) nextPacketPos=\(packetPosition)"
    }

    /// Targeted failing timestamps plus a positive 10-second seek control.
    /// This is intentionally an OBSERVATION: the existing 32-case test
    /// remains the strict failure gate. No alternate seek path is a fix.
    func testG0B03LibavformatRouteObservation() throws {
        let targets: [(tag: String, duration: Double, target: Double)] = [
            ("025", 0.25, 0.0625), // existing raw seek -1
            ("050", 0.50, 0.25),   // existing raw seek -1
            ("200", 2.00, 1.80),   // existing raw seek -1
            ("1000", 10.00, 9.00)  // existing working control
        ]
        var recorded = 0
        var errors = 0
        for item in targets {
            for seektable in [false, true] {
                let url = try fixture(item.tag, withSeektable: seektable)
                for fastSeek in [false, true] {
                    for variant in RawSeekVariant.allCases {
                        let label = "duration=\(item.duration) target=\(item.target) "
                            + "table=\(seektable) fastSeek=\(fastSeek) "
                            + "variant=\(variant.rawValue)"
                        do {
                            let result = try probeDemuxerSeek(
                                url: url,
                                seconds: item.target,
                                duration: item.duration,
                                fastSeek: fastSeek,
                                variant: variant
                            )
                            print("G0_B03_ROUTE \(label) \(result)")
                            if !result.contains("seekCode=") { errors += 1 }
                        } catch {
                            print("G0_B03_ROUTE \(label) setupError=\(error)")
                            errors += 1
                        }
                        recorded += 1
                    }
                }
            }
        }
        print("G0_B03_ROUTE_SUMMARY attempted=\(recorded) setupErrors=\(errors)")
        XCTAssertEqual(recorded, 96)
        XCTAssertEqual(errors, 0, "Cannot trust an incomplete route observation")
    }

    /// R3 maps public demuxer behaviour around packet boundaries. FFmpeg's
    /// internal read_timestamp()/binary-search iterations are *not* exposed
    /// here; byte-position observations are external correlates only.
    /// No production fallback or seek flag is changed.
    private func probeSeekTick(
        url: URL,
        sampleTick: Int64,
        fastSeek: Bool
    ) throws -> String {
        var owned = avformat_alloc_context()
        guard let allocated = owned else { throw MatrixError.missingFormatContext }
        if fastSeek {
            allocated.pointee.flags |= Int32(AVFMT_FLAG_FAST_SEEK)
        }
        defer { avformat_close_input(&owned) }
        let openCode = url.path.withCString {
            avformat_open_input(&owned, $0, nil, nil)
        }
        guard openCode >= 0, let context = owned else {
            return "openCode=\(openCode) setupFailed=1"
        }
        let streamCode = avformat_find_stream_info(context, nil)
        guard streamCode >= 0,
              context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              stream.pointee.time_base.num == 1,
              stream.pointee.time_base.den == 44100,
              let pb = context.pointee.pb
        else {
            return "streamInfoCode=\(streamCode) setupFailed=1"
        }

        let bytes = avio_size(pb)
        let positionBefore = avio_seek(pb, 0, SEEK_CUR)
        let seekCode = avformat_seek_file(
            context, 0, Int64.min, sampleTick, Int64.max,
            AVSEEK_FLAG_BACKWARD
        )
        let positionAfterSeek = avio_seek(pb, 0, SEEK_CUR)

        var readCode = "notAttempted"
        var packetPTS = "none"
        var packetPos = "none"
        var packetSize = "none"
        var positionAfterRead = "notAttempted"
        if seekCode >= 0 {
            var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            defer { av_packet_free(&ownedPacket) }
            guard let packet = ownedPacket else { throw MatrixError.missingPacket }
            let rc = av_read_frame(context, packet)
            readCode = String(rc)
            if rc >= 0 {
                packetPTS = String(packet.pointee.pts)
                packetPos = String(packet.pointee.pos)
                packetSize = String(packet.pointee.size)
            }
            positionAfterRead = String(avio_seek(pb, 0, SEEK_CUR))
        }
        let actualFastSeek = context.pointee.flags & Int32(AVFMT_FLAG_FAST_SEEK)
        return "timeBase=1/44100 fileBytes=\(bytes) "
            + "fastFlag=\(actualFastSeek != 0) beforeByte=\(positionBefore) "
            + "afterSeekByte=\(positionAfterSeek) seekCode=\(seekCode) "
            + "nextReadCode=\(readCode) nextPacketPTS=\(packetPTS) "
            + "nextPacketPos=\(packetPos) nextPacketBytes=\(packetSize) "
            + "afterReadByte=\(positionAfterRead)"
    }

    private func packetBoundaryMap(
        url: URL,
        focus: Int64
    ) throws -> String {
        let source = try OpenedSource.open(url: url)
        var owned = source.takeFormatContext()
        defer { avformat_close_input(&owned) }
        guard let context = owned,
              let pb = context.pointee.pb
        else { throw MatrixError.missingFormatContext }
        let fileBytes = avio_size(pb)
        var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&ownedPacket) }
        guard let packet = ownedPacket else { throw MatrixError.missingPacket }
        var count = 0
        var first = "none"
        var last = "none"
        var prior = "none"
        var following = "none"
        var lastPTS = Int64.min
        var monotonic = true
        for _ in 0..<512 {
            let rc = av_read_frame(context, packet)
            if rc < 0 { break }
            defer { av_packet_unref(packet) }
            if packet.pointee.stream_index != 0 { continue }
            let pts = packet.pointee.pts
            let entry = "\(pts)@\(packet.pointee.pos)+\(packet.pointee.size)"
            if count == 0 { first = entry }
            if pts < lastPTS { monotonic = false }
            lastPTS = pts
            if pts <= focus { prior = entry }
            if pts > focus && following == "none" { following = entry }
            last = entry
            count += 1
        }
        return "packets=\(count) fileBytes=\(fileBytes) "
            + "first=\(first) last=\(last) "
            + "atOrBefore=\(prior) after=\(following) "
            + "packetPTSMonotonic=\(monotonic)"
    }

    /// R3 intentionally uses exact integer 44.1-kHz ticks instead of Double
    /// seconds, to distinguish seek-index failures from clock quantization.
    /// Failing foci + nearest packet boundaries are paired with a 10s control.
    func testG0B03GenericSeekBoundaryObservation() throws {
        let inputs: [(tag: String, durationSamples: Int64,
                       focus: Int64, packetStart: Int64, packetEnd: Int64)] = [
            ("025", 11025, 2756, 0, 4608),
            ("050", 22050, 11025, 9216, 13824),
            ("200", 88200, 79380, 78336, 82944),
            ("1000", 441000, 396900, 396288, 400896),
        ]
        var attempted = 0
        var setupErrors = 0
        var observedFailedSeek = 0
        var observedAcceptedSeek = 0
        for item in inputs {
            var samples: Set<Int64> = [
                0, item.durationSamples - 1,
                item.focus - 1, item.focus, item.focus + 1,
                item.packetStart - 1, item.packetStart, item.packetStart + 1,
                item.packetEnd - 1, item.packetEnd, item.packetEnd + 1,
            ]
            samples = Set(samples.filter {
                $0 >= 0 && $0 < item.durationSamples
            })
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                do {
                    let geometry = try packetBoundaryMap(url: url, focus: item.focus)
                    print(
                        "G0_B03_R3_PACKET_MAP durationSamples=\(item.durationSamples) "
                            + "focus=\(item.focus) table=\(table) \(geometry)"
                    )
                } catch {
                    setupErrors += 1
                    print("G0_B03_R3_PACKET_MAP setupError=\(error)")
                }

                for fast in [false, true] {
                    for tick in samples.sorted() {
                        attempted += 1
                        let label = "durationSamples=\(item.durationSamples) "
                            + "focus=\(item.focus) table=\(table) "
                            + "fast=\(fast) sampleTick=\(tick)"
                        do {
                            let observation = try probeSeekTick(
                                url: url, sampleTick: tick, fastSeek: fast
                            )
                            print("G0_B03_R3 \(label) \(observation)")
                            if observation.contains("setupFailed=1") {
                                setupErrors += 1
                            } else if observation.contains("seekCode=-1 ") {
                                observedFailedSeek += 1
                            } else if observation.contains("seekCode=0 ") {
                                observedAcceptedSeek += 1
                            } else {
                                setupErrors += 1
                            }
                        } catch {
                            setupErrors += 1
                            print("G0_B03_R3 \(label) setupError=\(error)")
                        }
                    }
                }
            }
        }
        print(
            "G0_B03_R3_SUMMARY attempted=\(attempted) "
                + "accepted=\(observedAcceptedSeek) rejectedMinusOne=\(observedFailedSeek) "
                + "setupErrors=\(setupErrors)"
        )
        XCTAssertGreaterThanOrEqual(attempted, 140)
        XCTAssertEqual(setupErrors, 0, "R3 observation incomplete")
        XCTAssertEqual(
            observedAcceptedSeek + observedFailedSeek, attempted,
            "R3 requires one interpretable result per probe"
        )
    }

    /// R4 uses the linked FFmpeg's *existing* AV_LOG_TRACE output to expose
    /// ff_gen_search/read_timestamp brackets. Unlike R3, this deliberately
    /// avoids avio_size(), avio_seek(SEEK_CUR), and external packet scanning
    /// before seek: a second observation path must not perturb its target.
    ///
    /// AV_LOG_TRACE is process-global in libavutil. Set it only for the single
    /// synchronous seek, restore it in defer, and do not run this diagnostic
    /// alongside a concurrent codec workload. The test is LAB-ONLY.
    private func traceLinkedGenericSeek(
        url: URL,
        sampleTick: Int64,
        fastSeek: Bool,
        label: String,
        traceStage: String = "R4"
    ) throws -> String {
        var owned = avformat_alloc_context()
        guard let allocated = owned else { throw MatrixError.missingFormatContext }
        if fastSeek {
            allocated.pointee.flags |= Int32(AVFMT_FLAG_FAST_SEEK)
        }
        defer { avformat_close_input(&owned) }

        let openCode = url.path.withCString {
            avformat_open_input(&owned, $0, nil, nil)
        }
        guard openCode >= 0, let context = owned else {
            return "openCode=\(openCode) setupFailed=1"
        }
        let infoCode = avformat_find_stream_info(context, nil)
        guard infoCode >= 0,
              context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              stream.pointee.time_base.num == 1,
              stream.pointee.time_base.den == 44100
        else {
            return "streamInfoCode=\(infoCode) setupFailed=1"
        }

        let priorLogLevel = av_log_get_level()
        // NSLog writes to the same diagnostic stream as libavutil's default
        // av_log callback and supplies distinctive per-case boundaries.
        NSLog("G0_B03_\(traceStage)_TRACE_BEGIN \(label)")
        let seekCode: Int32
        do {
            av_log_set_level(AV_LOG_TRACE)
            defer { av_log_set_level(priorLogLevel) }
            seekCode = avformat_seek_file(
                context, 0, Int64.min, sampleTick, Int64.max,
                AVSEEK_FLAG_BACKWARD
            )
        }
        NSLog("G0_B03_\(traceStage)_TRACE_END \(label) seekCode=\(seekCode)")

        var nextReadCode = "notAttempted"
        var nextPacketPTS = "none"
        var nextPacketPos = "none"
        if seekCode >= 0 {
            var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            defer { av_packet_free(&ownedPacket) }
            guard let packet = ownedPacket else { throw MatrixError.missingPacket }
            let rc = av_read_frame(context, packet)
            nextReadCode = String(rc)
            if rc >= 0 {
                nextPacketPTS = String(packet.pointee.pts)
                nextPacketPos = String(packet.pointee.pos)
            }
        }
        return "streamInfoCode=\(infoCode) timeBase=1/44100 "
            + "targetTick=\(sampleTick) seekCode=\(seekCode) "
            + "nextReadCode=\(nextReadCode) "
            + "nextPacketPTS=\(nextPacketPTS) "
            + "nextPacketPos=\(nextPacketPos)"
    }

    /// Reproduce three failing generic-search targets, their nearest known
    /// working packet boundary, one long-file control, and the table+FAST
    /// bypass. The trace messages are FFmpeg's own, not an inferred model of
    /// read_timestamp. Neither source code nor production flags are patched.
    func testG0B03LinkedFFmpegInternalTraceObservation() throws {
        let cases: [(
            tag: String, tick: Int64, table: Bool,
            fast: Bool, expectedSuccess: Bool
        )] = [
            ("025", 2756, false, false, false),
            ("025", 4608, false, false, true),
            ("050", 11025, false, false, false),
            ("050", 13824, false, false, true),
            ("200", 79380, false, false, false),
            ("200", 82944, false, false, true),
            ("1000", 396900, false, false, true),
            ("200", 79380, true, true, true)
        ]
        var observed = 0
        var unexpected = 0
        for item in cases {
            let url = try fixture(item.tag, withSeektable: item.table)
            let label = "durationTag=\(item.tag) sampleTick=\(item.tick) "
                + "table=\(item.table) fastSeek=\(item.fast)"
            do {
                let observation = try traceLinkedGenericSeek(
                    url: url, sampleTick: item.tick,
                    fastSeek: item.fast, label: label
                )
                print("G0_B03_R4_RESULT \(label) \(observation)")
                let resultSuccessful = observation.contains("seekCode=0 ")
                let resultFailed = observation.contains("seekCode=-1 ")
                if observation.contains("setupFailed=1")
                    || !(resultSuccessful || resultFailed)
                    || resultSuccessful != item.expectedSuccess {
                    unexpected += 1
                }
            } catch {
                print("G0_B03_R4_RESULT \(label) setupError=\(error)")
                unexpected += 1
            }
            observed += 1
        }
        print("G0_B03_R4_SUMMARY attempted=\(observed) unexpected=\(unexpected)")
        XCTAssertEqual(observed, 8)
        XCTAssertEqual(
            unexpected, 0,
            "R4 setup or known control outcomes changed; inspect raw logs"
        )
    }

    /// R5 isolates the PUBLIC FLAC AVCodecParser (libavcodec parser API),
    /// not the production decoder. It mirrors flac_read_timestamp's parser
    /// setup but feeds fixed-size local byte slices to distinguish a short
    /// remainder from the parser's EOF-flush behavior.
    ///
    /// It is intentionally NOT a reimplementation of ff_raw_read_partial_packet:
    /// 1024/4096 are controlled input chunk sizes, not asserted AVIO sizes.
    /// Keep each parser and AVCodecContext independent across trials.
    private func probeFLACParserR5(
        url: URL,
        startByte: Int,
        chunkBytes: Int,
        flushAtEOF: Bool
    ) throws -> String {
        let input = Array(try Data(contentsOf: url))
        guard startByte >= 0, startByte < input.count,
              chunkBytes > 0, chunkBytes <= 4096
        else { throw MatrixError.invalidFixture }

        let source = try OpenedSource.open(url: url)
        var ownedFormat = source.takeFormatContext()
        defer { avformat_close_input(&ownedFormat) }
        guard let context = ownedFormat,
              context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_FLAC
        else { throw MatrixError.missingStream }

        guard let allocated = avcodec_alloc_context3(nil)
        else { throw MatrixError.missingFormatContext }
        var ownedCodec: UnsafeMutablePointer<AVCodecContext>? = allocated
        defer { avcodec_free_context(&ownedCodec) }
        let parameterCode = avcodec_parameters_to_context(allocated, codecpar)
        guard parameterCode >= 0 else {
            return "setupError=parameters(\(parameterCode))"
        }
        guard let parser = av_parser_init(Int32(codecpar.pointee.codec_id.rawValue))
        else { return "setupError=parserUnavailable" }
        defer { av_parser_close(parser) }
        parser.pointee.flags |= PARSER_FLAG_USE_CODEC_TS

        var cursor = startByte
        var calls = 0
        var outputs = 0
        var outputsWithoutPTS = 0
        var firstPTS = "none"
        var firstPTSOffset = "none"
        var firstOutputBytes = "none"
        var validFound = false
        var parserError = "none"
        var stalled = false

        func observe(_ emittedBytes: Int32) {
            guard emittedBytes > 0 else { return }
            outputs += 1
            let pts = parser.pointee.pts
            if pts == Int64.min {
                outputsWithoutPTS += 1
            } else if !validFound {
                validFound = true
                firstPTS = String(pts)
                firstPTSOffset = String(parser.pointee.next_frame_offset)
                firstOutputBytes = String(emittedBytes)
            }
        }

        // The real FLAC demuxer passes the initial *ppos as the parser's
        // position argument; do the same. Raw packets otherwise have NOPTS.
        while cursor < input.count && calls < 2048 && !validFound {
            let amount = min(chunkBytes, input.count - cursor)
            var padded = Array(input[cursor..<(cursor + amount)])
            padded.append(contentsOf: repeatElement(UInt8(0), count: 64))
            var outData: UnsafeMutablePointer<UInt8>?
            var outSize: Int32 = 0
            let consumed: Int32 = padded.withUnsafeBufferPointer { raw in
                av_parser_parse2(
                    parser, allocated, &outData, &outSize,
                    raw.baseAddress, Int32(amount),
                    Int64.min, Int64.min, Int64(startByte)
                )
            }
            calls += 1
            if consumed < 0 || Int(consumed) > amount {
                parserError = String(consumed)
                break
            }
            observe(outSize)
            cursor += Int(consumed)
            if consumed == 0 && outSize == 0 {
                stalled = true
                break
            }
        }

        var flushCalls = 0
        if flushAtEOF && cursor == input.count
            && !validFound && parserError == "none" && !stalled {
            for _ in 0..<4 {
                var outData: UnsafeMutablePointer<UInt8>?
                var outSize: Int32 = 0
                // A nonnull padded pointer with zero input length models
                // av_parser_parse2() at EOF without unpadded read risk.
                let padding = [UInt8](repeating: 0, count: 64)
                let ret: Int32 = padding.withUnsafeBufferPointer { raw in
                    av_parser_parse2(
                        parser, allocated, &outData, &outSize,
                        raw.baseAddress, 0, Int64.min,
                        Int64.min, Int64(startByte)
                    )
                }
                flushCalls += 1
                if ret < 0 {
                    parserError = "flush(\(ret))"
                    break
                }
                observe(outSize)
                if outSize == 0 || validFound { break }
            }
        }

        return "totalBytes=\(input.count) startByte=\(startByte) "
            + "availableBytes=\(input.count - startByte) chunkBytes=\(chunkBytes) "
            + "eofFlush=\(flushAtEOF) calls=\(calls) cursor=\(cursor) "
            + "flushCalls=\(flushCalls) outputs=\(outputs) "
            + "outputsWithoutPTS=\(outputsWithoutPTS) "
            + "firstValidPTS=\(firstPTS) firstValidNextFrameOffset=\(firstPTSOffset) "
            + "firstValidOutputBytes=\(firstOutputBytes) "
            + "parserError=\(parserError) stalled=\(stalled)"
    }

    /// R5 short-tail parser experiment: compare starts at actual FLAC frame
    /// boundaries with a byte inside that frame (from R4), against the next
    /// header. Includes long FLAC control and EOF flush on/off.
    /// All 48 cases are observational; behavior is not required to PASS.
    func testG0B03FLACParserEOFAndHeaderObservation() throws {
        let cases: [(tag: String, frameStart: Int, middle: Int, nextFrame: Int)] = [
            ("025", 8288, 9058, 9576),
            ("050", 10864, 11370, 12152),
            ("200", 30295, 30594, 31595),
            ("1000", 119396, 119603, 120688)
        ]
        var attempted = 0
        var setupErrors = 0
        for item in cases {
            let url = try fixture(item.tag, withSeektable: false)
            for start in [
                ("frameStart", item.frameStart),
                ("insideFrame", item.middle),
                ("nextFrame", item.nextFrame)
            ] {
                for chunk in [1024, 4096] {
                    for flush in [false, true] {
                        attempted += 1
                        let label = "durationTag=\(item.tag) "
                            + "startKind=\(start.0) startByte=\(start.1) "
                            + "chunkBytes=\(chunk) eofFlush=\(flush)"
                        do {
                            let observation = try probeFLACParserR5(
                                url: url, startByte: start.1,
                                chunkBytes: chunk, flushAtEOF: flush
                            )
                            print("G0_B03_R5_PARSER \(label) \(observation)")
                            if observation.contains("setupError=") {
                                setupErrors += 1
                            }
                        } catch {
                            setupErrors += 1
                            print("G0_B03_R5_PARSER \(label) setupError=\(error)")
                        }
                    }
                }
            }
        }
        print("G0_B03_R5_SUMMARY attempted=\(attempted) setupErrors=\(setupErrors)")
        XCTAssertEqual(attempted, 48)
        XCTAssertEqual(setupErrors, 0, "R5 parser observation incomplete")
    }

    /// R6: read actual demuxed packet geometry from the SAME FLAC fixture.
    /// Each recorded position is a packet start reported by the linked
    /// demuxer; it is not an independently CRC-verified FLAC header count.
    private func demuxedFLACPacketGeometryR6(
        url: URL
    ) throws -> [(position: Int, bytes: Int, pts: Int64)] {
        let source = try OpenedSource.open(url: url)
        var owned = source.takeFormatContext()
        defer { avformat_close_input(&owned) }
        guard let context = owned,
              context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              stream.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_FLAC
        else { throw MatrixError.missingStream }

        var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&ownedPacket) }
        guard let packet = ownedPacket else { throw MatrixError.missingPacket }

        var frames: [(position: Int, bytes: Int, pts: Int64)] = []
        for _ in 0..<2048 {
            let code = av_read_frame(context, packet)
            if code < 0 { break }
            if packet.pointee.stream_index == 0 {
                let pos = packet.pointee.pos
                let size = packet.pointee.size
                let pts = packet.pointee.pts
                // The generated deterministic G0 fixtures should all have
                // positioned, timestamped, positive-size FLAC packets.
                guard pos >= 0, size > 2, pts != Int64.min,
                      pos <= Int64(Int.max) - Int64(size)
                else {
                    av_packet_unref(packet)
                    throw MatrixError.invalidFixture
                }
                frames.append((Int(pos), Int(size), pts))
            }
            av_packet_unref(packet)
        }
        guard !frames.isEmpty else { throw MatrixError.invalidFixture }
        for i in 1..<frames.count {
            guard frames[i].position > frames[i - 1].position,
                  frames[i].pts >= frames[i - 1].pts
            else { throw MatrixError.invalidTimestamp }
        }
        return frames
    }

    /// R6 measures how many *demuxed packet starts* remain after each byte
    /// offset, rather than guessing the number from audio duration. The
    /// public parser is restarted for each trial and flushed at file EOF.
    /// This isolates remaining-media geometry; it does NOT expose the
    /// private FLAC parser's nb_headers_buffered or exactly reimplement
    /// flac_read_timestamp/ff_raw_read_partial_packet.
    func testG0B03FLACParserRemainingPacketStartsObservation() throws {
        let tags = ["025", "050", "200", "1000"]
        var attempted = 0
        var setupErrors = 0
        var validPTS = 0
        var missingPTS = 0

        for tag in tags {
            let url = try fixture(tag, withSeektable: false)
            let frames = try demuxedFLACPacketGeometryR6(url: url)
            // Last 16 packets expose the transition near EOF; one initial
            // packet is included as a long-tail positive control.
            let tailStart = max(0, frames.count - 16)
            var chosen = Array(tailStart..<frames.count)
            if !chosen.contains(0) { chosen.insert(0, at: 0) }
            print(
                "G0_B03_R6_PACKET_MAP durationTag=\(tag) "
                    + "totalDemuxedPackets=\(frames.count) "
                    + "selectedPackets=\(chosen.count)"
            )

            for index in chosen {
                let entry = frames[index]
                let lastByte = entry.position + entry.bytes - 1
                let insideOneByte = entry.position + 1
                let insideMiddle = min(
                    lastByte, entry.position + entry.bytes / 2
                )
                let points: [(kind: String, byte: Int)] = [
                    ("frameStart", entry.position),
                    ("insidePlusOne", insideOneByte),
                    ("insideMiddle", insideMiddle)
                ]
                for point in points {
                    attempted += 1
                    let remainingStarts = frames.count - index
                        - (point.kind == "frameStart" ? 0 : 1)
                    let label = "durationTag=\(tag) packetIndex=\(index) "
                        + "totalPackets=\(frames.count) "
                        + "remainingPacketStarts=\(remainingStarts) "
                        + "packetStartByte=\(entry.position) "
                        + "packetSize=\(entry.bytes) packetPTS=\(entry.pts) "
                        + "startKind=\(point.kind) startByte=\(point.byte)"
                    do {
                        let result = try probeFLACParserR5(
                            url: url, startByte: point.byte,
                            chunkBytes: 1024, flushAtEOF: true
                        )
                        let setupBad = result.contains("setupError=")
                            || result.contains("parserError=flush(")
                            || result.contains("stalled=true")
                        let hasPTS = !result.contains("firstValidPTS=none")
                            && result.contains("firstValidPTS=")
                        if setupBad {
                            setupErrors += 1
                        } else if hasPTS {
                            validPTS += 1
                        } else {
                            missingPTS += 1
                        }
                        print(
                            "G0_B03_R6_PROBE \(label) "
                                + "hasValidPTS=\(hasPTS) \(result)"
                        )
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R6_PROBE \(label) setupError=\(error)")
                    }
                }
            }
        }

        print(
            "G0_B03_R6_SUMMARY attempted=\(attempted) "
                + "validPTS=\(validPTS) missingPTS=\(missingPTS) "
                + "setupErrors=\(setupErrors)"
        )
        XCTAssertGreaterThan(attempted, 90, "R6 did not sample all packet tails")
        XCTAssertEqual(setupErrors, 0, "R6 parser observation incomplete")
        XCTAssertEqual(validPTS + missingPTS, attempted)
    }

    /// R7 correlates the *actual* byte start reported by FFmpeg's native
    /// generic-search trace with independently measured packet geometry.
    /// A requested sample inside a frame does NOT imply that FFmpeg will
    /// probe an offset inside that same frame. Do not classify the requested
    /// packet as the actual search probe; use the trace's start: field.
    ///
    /// No direct call to private flac_read_timestamp, no modified FFmpeg,
    /// no forced byte seek, no index insertion and no production fallback.
    func testG0B03NativeDemuxerTailTraceObservation() throws {
        let inputs: [(tag: String, totalSamples: Int64)] = [
            ("025", 11025), ("050", 22050),
            ("200", 88200), ("1000", 441000)
        ]
        var attempted = 0
        var setupErrors = 0
        var accepted = 0
        var rejected = 0
        var expected = 0

        for item in inputs {
            let url = try fixture(item.tag, withSeektable: false)
            // Separate demuxer context: no index or AVIO mutations to
            // the fresh contexts used by the actual seek probes below.
            let frames = try demuxedFLACPacketGeometryR6(url: url)
            let fileBytes = try Data(contentsOf: url).count
            let tailStart = max(0, frames.count - 5)
            let selected = Array(tailStart..<frames.count)
            print(
                "G0_B03_R7_MAP durationTag=\(item.tag) "
                    + "totalPackets=\(frames.count) fileBytes=\(fileBytes) "
                    + "selectedPackets=\(selected.count)"
            )
            // Emit the entire map, not just the tail: ff_gen_search may
            // interpolate to any byte interval in the input.
            for (index, frame) in frames.enumerated() {
                print(
                    "G0_B03_R7_PACKET durationTag=\(item.tag) "
                        + "packetIndex=\(index) pts=\(frame.pts) "
                        + "startByte=\(frame.position) bytes=\(frame.bytes)"
                )
            }

            for index in selected {
                let frame = frames[index]
                let endPTS = index + 1 < frames.count
                    ? frames[index + 1].pts : item.totalSamples
                guard frame.pts >= 0, endPTS > frame.pts + 1,
                      endPTS <= item.totalSamples
                else { throw MatrixError.invalidFixture }
                let midpoint = frame.pts + (endPTS - frame.pts) / 2
                let targets: [(kind: String, tick: Int64)] = [
                    ("boundary", frame.pts), ("midSample", midpoint)
                ]
                expected += targets.count
                for target in targets {
                    attempted += 1
                    let label = "durationTag=\(item.tag) "
                        + "packetIndex=\(index) "
                        + "targetKind=\(target.kind) "
                        + "sampleTick=\(target.tick) "
                        + "targetPacketStartByte=\(frame.position) "
                        + "targetPacketPTS=\(frame.pts) "
                        + "targetPacketEndPTS=\(endPTS) "
                        + "targetPacketStartsRemaining=\(frames.count - index)"
                    do {
                        let result = try traceLinkedGenericSeek(
                            url: url, sampleTick: target.tick,
                            fastSeek: false, label: label, traceStage: "R7"
                        )
                        print("G0_B03_R7_RESULT \(label) \(result)")
                        if result.contains("setupFailed=1") {
                            setupErrors += 1
                        } else if result.contains("seekCode=0 ") {
                            accepted += 1
                        } else if result.contains("seekCode=-1 ") {
                            rejected += 1
                        } else {
                            setupErrors += 1
                        }
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R7_RESULT \(label) setupError=\(error)")
                    }
                }
            }
        }

        print(
            "G0_B03_R7_SUMMARY attempted=\(attempted) expected=\(expected) "
                + "accepted=\(accepted) rejectedMinusOne=\(rejected) "
                + "setupErrors=\(setupErrors)"
        )
        // Four fixed fixtures: 3 + 5 + 5 + 5 tail packets, two
        // targets each. The strict B03 functional gate stays separate.
        XCTAssertEqual(expected, 36)
        XCTAssertEqual(attempted, expected)
        XCTAssertEqual(setupErrors, 0, "R7 observation incomplete")
        XCTAssertEqual(accepted + rejected, attempted)
    }

    /// R8 copies the actual interleaved Float32 PCM delivered to CoreMedia.
    /// No render device or timing estimate is substituted for sample data.
    private struct PCMSequenceR8 {
        var firstTick: Int64?
        var nextTick: Int64?
        var channels = 0
        var buffers = 0
        var samples: [Float] = []

        var frameCount: Int { channels > 0 ? samples.count / channels : 0 }

        mutating func append(_ buffer: CMSampleBuffer, rate: Int32 = 44100) throws {
            let count = CMSampleBufferGetNumSamples(buffer)
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard count > 0, seconds.isFinite, seconds >= 0,
                  let block = CMSampleBufferGetDataBuffer(buffer)
            else { throw MatrixError.invalidTimestamp }
            let tick = Int64((seconds * Double(rate)).rounded())
            guard abs(seconds * Double(rate) - Double(tick)) < 0.001,
                  nextTick == nil || nextTick == tick
            else { throw MatrixError.invalidTimestamp }

            let bytes = CMBlockBufferGetDataLength(block)
            let stride = MemoryLayout<Float>.stride
            guard bytes > 0, bytes % (count * stride) == 0
            else { throw MatrixError.invalidFixture }
            let channelCount = bytes / (count * stride)
            guard channelCount > 0,
                  channels == 0 || channels == channelCount
            else { throw MatrixError.invalidFixture }

            var floats = [Float](repeating: 0, count: bytes / stride)
            let status = floats.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: bytes,
                    destination: raw.baseAddress!
                )
            }
            guard status == 0, floats.allSatisfy({ $0.isFinite })
            else { throw MatrixError.invalidFixture }
            if firstTick == nil { firstTick = tick }
            nextTick = tick + Int64(count)
            channels = channelCount
            samples.append(contentsOf: floats)
            buffers += 1
        }
    }

    private func collectPCMSequenceR8(
        decoder: AudioDecoder
    ) throws -> PCMSequenceR8 {
        var output = PCMSequenceR8()
        for _ in 0..<2048 {
            guard let buffer = try decoder.readNextBuffer() else {
                return output
            }
            try output.append(buffer)
        }
        throw MatrixError.invalidFixture
    }

    /// Linear decode is the reference for the same fixture and linked
    /// library. Disable optional DSP in BOTH routes only within this test;
    /// the built-in seek de-click ramp remains active. Compare actual PCM
    /// at its reported absolute sample coordinates, excluding that ramp
    /// from the content comparison, not from sample-count measurements.
    func testG0B03PCMSampleAccuracyObservation() throws {
        let inputs: [(tag: String, seconds: Double, samples: Int64)] = [
            ("025", 0.25, 11025), ("050", 0.50, 22050),
            ("200", 2.0, 88200), ("1000", 10.0, 441000)
        ]
        let fractions: [(name: String, value: Double)] = [
            ("start", 0), ("quarter", 0.25),
            ("middle", 0.50), ("near-end", 0.90)
        ]
        var attempted = 0
        var setupErrors = 0
        var rawRejected = 0
        var missingPCM = 0
        var delivered = 0
        for item in inputs {
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                let linear = AudioDecoder()
                linear.limiterEnabled = false
                try linear.adopt(OpenedSource.open(url: url))
                let reference: PCMSequenceR8
                do {
                    defer { linear.close() }
                    reference = try collectPCMSequenceR8(decoder: linear)
                }
                guard reference.firstTick == 0,
                      reference.nextTick == item.samples,
                      Int64(reference.frameCount) == item.samples
                else { throw MatrixError.invalidFixture }
                print(
                    "G0_B03_R8_REFERENCE durationTag=\(item.tag) table=\(table) "
                        + "frames=\(reference.frameCount) channels=\(reference.channels) "
                        + "buffers=\(reference.buffers)"
                )

                for position in fractions {
                    attempted += 1
                    let seconds = item.seconds * position.value
                    let target = Int64(seconds / (1.0 / 44100.0))
                    let label = "durationTag=\(item.tag) table=\(table) "
                        + "position=\(position.name) targetTick=\(target) "
                        + "requestedNearest=\(Int64((seconds * 44100).rounded())) "
                        + "expectedFrames=\(item.samples - target)"
                    do {
                        let raw = try rawSeek(
                            url: url, seconds: seconds, useAvSeekFrame: false
                        )
                        let decoder = AudioDecoder()
                        decoder.limiterEnabled = false
                        try decoder.adopt(OpenedSource.open(url: url))
                        defer { decoder.close() }
                        guard try decoder.readNextBuffer() != nil else {
                            throw MatrixError.missingPCM
                        }
                        do {
                            try decoder.seek(to: seconds)
                        } catch {
                            if raw.code < 0 {
                                rawRejected += 1
                                print(
                                    "G0_B03_R8_CASE \(label) "
                                        + "rawCode=\(raw.code) seekError=\(error)"
                                )
                                continue
                            }
                            throw error
                        }
                        guard raw.code >= 0 else {
                            throw MatrixError.invalidFixture
                        }
                        let actual = try collectPCMSequenceR8(decoder: decoder)
                        guard let first = actual.firstTick,
                              let end = actual.nextTick
                        else {
                            missingPCM += 1
                            print(
                                "G0_B03_R8_CASE \(label) rawCode=\(raw.code) "
                                    + "actualFrames=0 missingAllPCM=true "
                                    + "missingFrames=\(item.samples - target)"
                            )
                            continue
                        }
                        guard actual.channels == reference.channels,
                              first >= 0, end <= item.samples,
                              Int64(actual.frameCount) == end - first
                        else { throw MatrixError.invalidFixture }
                        delivered += 1

                        let ramp = SeekTransientRamp.frameCount(sampleRate: 44100)
                        let skip = min(ramp, actual.frameCount) * actual.channels
                        let offset = Int(first) * actual.channels
                        var maxError: Float = 0
                        var differing = 0
                        for i in skip..<actual.samples.count {
                            let error = abs(actual.samples[i] - reference.samples[offset + i])
                            maxError = max(maxError, error)
                            if error > 0.000001 { differing += 1 }
                        }
                        print(
                            "G0_B03_R8_CASE \(label) rawCode=\(raw.code) "
                                + "firstTick=\(first) endTick=\(end) "
                                + "actualFrames=\(actual.frameCount) "
                                + "leadingGap=\(first - target) "
                                + "tailGap=\(item.samples - end) "
                                + "rampExcludedFrames=\(skip / actual.channels) "
                                + "comparedValues=\(actual.samples.count - skip) "
                                + "differentValues=\(differing) maxAbsError=\(maxError)"
                        )
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R8_CASE \(label) setupError=\(error)")
                    }
                }
            }
        }
        print(
            "G0_B03_R8_SUMMARY attempted=\(attempted) rawRejected=\(rawRejected) "
                + "missingPCM=\(missingPCM) delivered=\(delivered) "
                + "setupErrors=\(setupErrors)"
        )
        XCTAssertEqual(attempted, 32)
        XCTAssertEqual(setupErrors, 0, "R8 observation incomplete")
        XCTAssertEqual(rawRejected + missingPCM + delivered, attempted)
    }

    /// R9 uses native integer PCM from actual AVFrames, before SWR,
    /// CoreMedia, DSP and the intentional seek ramp. Preserve the native
    /// sample bytes in canonical interleaved channel order for comparison.
    private struct NativePCMSequenceR9 {
        var firstTick: Int64?
        var endTick: Int64?
        var frameStarts: [Int64] = []
        var sampleFormat: Int32?
        var channels = 0
        var bytesPerSample = 0
        var data = Data()

        var stride: Int { channels * bytesPerSample }

        mutating func append(
            _ frame: UnsafeMutablePointer<AVFrame>,
            expectedRate: Int32 = 44100, expectedChannels: Int = 2
        ) throws {
            let value = frame.pointee
            let start = value.pts
            let count = Int(value.nb_samples)
            let format = AVSampleFormat(rawValue: value.format)
            let width = Int(av_get_bytes_per_sample(format))
            let channelCount = Int(value.ch_layout.nb_channels)
            guard start >= 0, count > 0, value.sample_rate == expectedRate,
                  channelCount == expectedChannels, width > 0,
                  let planes = value.extended_data,
                  endTick == nil || endTick == start,
                  sampleFormat == nil || sampleFormat == value.format,
                  channels == 0 || channels == channelCount,
                  bytesPerSample == 0 || bytesPerSample == width
            else { throw MatrixError.invalidFixture }
            if firstTick == nil { firstTick = start }
            frameStarts.append(start)
            endTick = start + Int64(count)
            sampleFormat = value.format
            channels = channelCount
            bytesPerSample = width
            if av_sample_fmt_is_planar(format) == 0 {
                guard let plane = planes[0] else {
                    throw MatrixError.invalidFixture
                }
                data.append(Data(bytes: plane, count: count * stride))
            } else {
                // No conversion or resampling. Only reorder native bytes
                // from planar to interleaved for an unambiguous comparison.
                for channel in 0..<channelCount {
                    guard planes[channel] != nil else {
                        throw MatrixError.invalidFixture
                    }
                }
                for i in 0..<count {
                    for channel in 0..<channelCount {
                        guard let plane = planes[channel] else {
                            throw MatrixError.invalidFixture
                        }
                        data.append(plane.advanced(by: i * width), count: width)
                    }
                }
            }
        }
    }

    /// Open a fresh native context. For a seek, prime the decoder with
    /// one decoded frame, then use the same seek flags and post-seek
    /// avformat/avcodec flushes as AudioDecoder. Unlike production, this
    /// observer retains every decoded frame so it can measure what exists
    /// before the Swift whole-frame discard. No production flags changed.
    private func nativePCMSequenceR9(
        url: URL, targetTick: Int64?,
        sessionConfiguration: URLSessionConfiguration = .default,
        onOpened: (() -> Void)? = nil,
        expectedRate: Int32 = 44100, expectedChannels: Int = 2,
        retryAnchors: [Int64] = [],
        onPrimePacket: ((Int) -> Void)? = nil,
        onPacket: ((Int) -> Void)? = nil,
        onSeek: ((Int32, UInt64) -> Void)? = nil,
        onFrame: ((UnsafeMutablePointer<AVFrame>) throws -> Void)? = nil
    ) throws -> (code: Int32, pcm: NativePCMSequenceR9) {
        try Self.nativePCMSequenceR9Worker(
            url: url, targetTick: targetTick, sessionConfiguration: sessionConfiguration,
            onOpened: onOpened, expectedRate: expectedRate, expectedChannels: expectedChannels,
            retryAnchors: retryAnchors, onPrimePacket: onPrimePacket, onPacket: onPacket,
            onSeek: onSeek, onFrame: onFrame
        )
    }

    // Shared test-only implementation; no XCTest instance crosses worker queues.
    private static func nativePCMSequenceR9Worker(
        url: URL, targetTick: Int64?,
        sessionConfiguration: URLSessionConfiguration = .default,
        onOpened: (() -> Void)? = nil,
        expectedRate: Int32 = 44100, expectedChannels: Int = 2,
        retryAnchors: [Int64] = [],
        onPrimePacket: ((Int) -> Void)? = nil,
        onPacket: ((Int) -> Void)? = nil,
        onSeek: ((Int32, UInt64) -> Void)? = nil,
        onFrame: ((UnsafeMutablePointer<AVFrame>) throws -> Void)? = nil
    ) throws -> (code: Int32, pcm: NativePCMSequenceR9) {
        let source = try OpenedSource.open(url: url, sessionConfiguration: sessionConfiguration)
        // Keep the HTTP transport alive until after avformat_close_input.
        defer { source.close() }
        onOpened?()
        var ownedFormat = source.takeFormatContext()
        defer { avformat_close_input(&ownedFormat) }
        guard let context = ownedFormat,
              context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              stream.pointee.time_base.num == 1,
              stream.pointee.time_base.den == expectedRate,
              let parameters = stream.pointee.codecpar,
              parameters.pointee.sample_rate == expectedRate,
              Int(parameters.pointee.ch_layout.nb_channels) == expectedChannels,
              parameters.pointee.codec_id == AV_CODEC_ID_FLAC,
              let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let allocated = avcodec_alloc_context3(codec)
        else { throw MatrixError.missingStream }
        var ownedCodec: UnsafeMutablePointer<AVCodecContext>? = allocated
        defer { avcodec_free_context(&ownedCodec) }
        guard avcodec_parameters_to_context(allocated, parameters) >= 0,
              avcodec_open2(allocated, codec, nil) >= 0
        else { throw MatrixError.invalidFixture }

        var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var ownedFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&ownedPacket)
            av_frame_free(&ownedFrame)
        }
        guard let packet = ownedPacket, let frame = ownedFrame
        else { throw MatrixError.missingPacket }
        let eofCode: Int32 = -541_478_725
        let againCode = -Int32(EAGAIN)

        func drain(into output: inout NativePCMSequenceR9, streaming: Bool = false) throws -> Int32 {
            for _ in 0..<2048 {
                let rc = avcodec_receive_frame(allocated, frame)
                if rc == againCode || rc == eofCode { return rc }
                guard rc >= 0 else { throw MatrixError.invalidFixture }
                defer { av_frame_unref(frame) }
                if streaming, let onFrame {
                    try onFrame(frame)
                } else {
                    try output.append(
                        frame, expectedRate: expectedRate,
                        expectedChannels: expectedChannels
                    )
                }
            }
            throw MatrixError.invalidFixture
        }

        // Priming models the first PCM read in R8, without running DSP.
        if let targetTick {
            var primed = NativePCMSequenceR9()
            for _ in 0..<512 {
                guard av_read_frame(context, packet) >= 0
                else { throw MatrixError.missingPCM }
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == 0 else { continue }
                onPrimePacket?(Int(packet.pointee.size))
                guard avcodec_send_packet(allocated, packet) >= 0
                else { throw MatrixError.invalidFixture }
                _ = try drain(into: &primed)
                if primed.firstTick != nil { break }
            }
            guard primed.firstTick != nil else { throw MatrixError.missingPCM }
            var code: Int32 = -1
            for anchor in [targetTick] + retryAnchors {
                let seekStarted = DispatchTime.now().uptimeNanoseconds
                code = avformat_seek_file(
                    context, 0, Int64.min, anchor, Int64.max,
                    AVSEEK_FLAG_BACKWARD
                )
                onSeek?(code, DispatchTime.now().uptimeNanoseconds - seekStarted)
                // R12 retries only the observed generic -1 rejection.
                // No flush or decoder reads between failed attempts.
                if code != -1 { break }
            }
            if code < 0 { return (code, NativePCMSequenceR9()) }
            avformat_flush(context)
            avcodec_flush_buffers(allocated)
        }

        var output = NativePCMSequenceR9()
        for _ in 0..<2048 {
            let read = av_read_frame(context, packet)
            if read == eofCode {
                let sent = avcodec_send_packet(allocated, nil)
                guard sent >= 0 || sent == eofCode
                else { throw MatrixError.invalidFixture }
                guard try drain(into: &output, streaming: true) == eofCode
                else { throw MatrixError.invalidFixture }
                return (0, output)
            }
            guard read >= 0 else { throw MatrixError.invalidFixture }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == 0 else { continue }
            onPacket?(Int(packet.pointee.size))
            guard avcodec_send_packet(allocated, packet) >= 0
            else { throw MatrixError.invalidFixture }
            _ = try drain(into: &output, streaming: true)
        }
        throw MatrixError.invalidFixture
    }

    /// A lab-only candidate: discard samples before target, not the entire
    /// covering frame. Operate only on bytes actually decoded after seek;
    /// never manufacture missing samples from the reference. Compare the
    /// candidate with the linear native PCM suffix byte for byte.
    func testG0B03NativePCMTrimCandidateObservation() throws {
        let inputs: [(tag: String, seconds: Double, samples: Int64)] = [
            ("025", 0.25, 11025), ("050", 0.50, 22050),
            ("200", 2.0, 88200), ("1000", 10.0, 441000)
        ]
        let fractions: [(name: String, value: Double)] = [
            ("start", 0), ("quarter", 0.25),
            ("middle", 0.50), ("near-end", 0.90)
        ]
        var attempted = 0
        var rejected = 0
        var exact = 0
        var incomplete = 0
        var mismatched = 0
        var setupErrors = 0
        for item in inputs {
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                let linear = try nativePCMSequenceR9(url: url, targetTick: nil)
                let reference = linear.pcm
                guard linear.code == 0, reference.firstTick == 0,
                      reference.endTick == item.samples, reference.stride > 0,
                      reference.data.count == Int(item.samples) * reference.stride
                else { throw MatrixError.invalidFixture }
                print(
                    "G0_B03_R9_REFERENCE durationTag=\(item.tag) table=\(table) "
                        + "frames=\(item.samples) stride=\(reference.stride) "
                        + "format=\(reference.sampleFormat ?? -1)"
                )
                for position in fractions {
                    attempted += 1
                    let seconds = item.seconds * position.value
                    let target = Int64(seconds / (1.0 / 44100.0))
                    let label = "durationTag=\(item.tag) table=\(table) "
                        + "position=\(position.name) targetTick=\(target)"
                    do {
                        let result = try nativePCMSequenceR9(
                            url: url, targetTick: target
                        )
                        if result.code < 0 {
                            rejected += 1
                            print("G0_B03_R9_CASE \(label) seekCode=\(result.code)")
                            continue
                        }
                        let actual = result.pcm
                        guard let first = actual.firstTick,
                              let end = actual.endTick
                        else {
                            incomplete += 1
                            print("G0_B03_R9_CASE \(label) seekCode=0 rawPCM=none")
                            continue
                        }
                        guard actual.sampleFormat == reference.sampleFormat,
                              actual.stride == reference.stride,
                              first >= 0, end <= item.samples, end >= first,
                              actual.data.count == Int(end - first) * actual.stride
                        else { throw MatrixError.invalidFixture }

                        let candidateStart = min(end, max(first, target))
                        let trimBytes = Int(candidateStart - first) * actual.stride
                        let candidate = actual.data.dropFirst(trimBytes)
                        let referenceStart = Int(candidateStart) * actual.stride
                        let referenceEnd = Int(end) * actual.stride
                        let matches = candidate.elementsEqual(
                            reference.data[referenceStart..<referenceEnd]
                        )
                        let wholeFrameStart = actual.frameStarts.first { $0 >= target }
                        let wholeFrameEnd = wholeFrameStart ?? end
                        let recovered = max(0, wholeFrameEnd - candidateStart)
                        let complete = candidateStart == target && end == item.samples
                        if !matches {
                            mismatched += 1
                        } else if complete {
                            exact += 1
                        } else {
                            incomplete += 1
                        }
                        print(
                            "G0_B03_R9_CASE \(label) seekCode=0 "
                                + "rawFirst=\(first) rawEnd=\(end) "
                                + "wholeFrameFirst=\(wholeFrameStart.map(String.init) ?? "none") "
                                + "candidateFirst=\(candidateStart) "
                                + "candidateFrames=\(end - candidateStart) "
                                + "leadingGap=\(candidateStart - target) "
                                + "tailGap=\(item.samples - end) recoveredFrames=\(recovered) "
                                + "comparedBytes=\(candidate.count) bytesEqual=\(matches) "
                                + "complete=\(complete)"
                        )
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R9_CASE \(label) setupError=\(error)")
                    }
                }
            }
        }
        print(
            "G0_B03_R9_SUMMARY attempted=\(attempted) rejected=\(rejected) "
                + "exact=\(exact) incomplete=\(incomplete) "
                + "mismatched=\(mismatched) setupErrors=\(setupErrors)"
        )
        XCTAssertEqual(attempted, 32)
        XCTAssertEqual(setupErrors, 0, "R9 observation incomplete")
        XCTAssertEqual(rejected + exact + incomplete + mismatched, attempted)
    }

    /// R10: only the reference accumulates a whole track. Candidate PCM
    /// is converted and compared synchronously one AVFrame at a time.
    /// Fixed scope: the R9 S16 packed stereo, 44.1-kHz fixtures.
    private func makePCMBufferR10(
        values: [Float], frames: Int, tick: Int64,
        format: CMFormatDescription, rate: Int32 = 44100
    ) throws -> CMSampleBuffer {
        let bytes = values.count * MemoryLayout<Float>.stride
        var block: CMBlockBuffer?
        let allocation = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: 0, blockBufferOut: &block
        )
        guard allocation == 0, let block else {
            throw MatrixError.invalidFixture
        }
        let copy = values.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes
            )
        }
        guard copy == 0 else { throw MatrixError.invalidFixture }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMTime(value: tick, timescale: rate),
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )
        guard status == 0, let buffer else {
            throw MatrixError.invalidFixture
        }
        return buffer
    }

    /// Exercise real SWR and real CoreMedia buffer construction with
    /// a sample-granular cut before conversion. Reuse the production
    /// ramp helper; independently calculate the expected ramp on linear
    /// reference PCM. No candidate track-sized buffer and no reference
    /// samples copied into candidate output.
    func testG0B03IncrementalPCMTrimCoreMediaObservation() throws {
        let inputs: [(tag: String, seconds: Double, samples: Int64)] = [
            ("025", 0.25, 11025), ("050", 0.50, 22050),
            ("200", 2.0, 88200), ("1000", 10.0, 441000)
        ]
        let fractions: [(name: String, value: Double)] = [
            ("start", 0), ("quarter", 0.25),
            ("middle", 0.50), ("near-end", 0.90)
        ]
        let rampFrames = SeekTransientRamp.frameCount(sampleRate: 44100)
        var attempted = 0
        var rejected = 0
        var exact = 0
        var incomplete = 0
        var setupErrors = 0
        for item in inputs {
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                let linear = AudioDecoder()
                linear.limiterEnabled = false
                try linear.adopt(OpenedSource.open(url: url))
                defer { linear.close() }
                guard let firstBuffer = try linear.readNextBuffer(),
                      let format = CMSampleBufferGetFormatDescription(firstBuffer)
                else { throw MatrixError.missingPCM }
                var reference = PCMSequenceR8()
                try reference.append(firstBuffer)
                for _ in 0..<2048 {
                    guard let buffer = try linear.readNextBuffer() else { break }
                    try reference.append(buffer)
                }
                guard reference.firstTick == 0,
                      reference.nextTick == item.samples,
                      Int64(reference.frameCount) == item.samples,
                      reference.channels == 2
                else { throw MatrixError.invalidFixture }
                linear.close()
                for position in fractions {
                    attempted += 1
                    let seconds = item.seconds * position.value
                    let target = Int64(seconds / (1.0 / 44100.0))
                    let label = "durationTag=\(item.tag) table=\(table) "
                        + "position=\(position.name) targetTick=\(target)"
                    var swr: OpaquePointer?
                    defer { swr_free(&swr) }
                    var firstTick: Int64?
                    var endTick: Int64?
                    var rampConsumed = 0
                    var framesEmitted = 0
                    var outputBuffers = 0
                    var discardedFrames = 0
                    var discardedSamples = 0
                    var peakBufferFrames = 0
                    var differentValues = 0
                    var maxError: Float = 0
                    do {
                        let result = try nativePCMSequenceR9(
                            url: url, targetTick: target,
                            onFrame: { frame in
                            let value = frame.pointee
                            let start = value.pts
                            let count = Int(value.nb_samples)
                            guard start >= 0, count > 0,
                                  value.sample_rate == 44100,
                                  value.ch_layout.nb_channels == 2,
                                  value.format == AV_SAMPLE_FMT_S16.rawValue,
                                  let planes = value.extended_data,
                                  let plane = planes[0]
                            else { throw MatrixError.invalidFixture }
                            let end = start + Int64(count)
                            if end <= target {
                                discardedFrames += 1
                                discardedSamples += count
                                return
                            }
                            let keptStart = max(start, target)
                            let skip = Int(keptStart - start)
                            let kept = count - skip
                            discardedSamples += skip
                            guard kept > 0, end <= item.samples,
                                  endTick == nil || endTick == keptStart
                            else { throw MatrixError.invalidTimestamp }
                            if swr == nil {
                                var inLayout = AVChannelLayout()
                                var outLayout = AVChannelLayout()
                                av_channel_layout_default(&inLayout, 2)
                                av_channel_layout_default(&outLayout, 2)
                                defer {
                                    av_channel_layout_uninit(&inLayout)
                                    av_channel_layout_uninit(&outLayout)
                                }
                                let rc = swr_alloc_set_opts2(
                                    &swr, &outLayout, AV_SAMPLE_FMT_FLT, 44100,
                                    &inLayout, AV_SAMPLE_FMT_S16, 44100, 0, nil
                                )
                                guard rc >= 0, let swr, swr_init(swr) >= 0
                                else { throw MatrixError.invalidFixture }
                            }
                            guard let converter = swr else {
                                throw MatrixError.invalidFixture
                            }
                            let capacity = Int(swr_get_out_samples(converter, Int32(kept)))
                            guard capacity >= kept else {
                                throw MatrixError.invalidFixture
                            }
                            var floats = [Float](repeating: 0, count: capacity * 2)
                            var input: UnsafePointer<UInt8>? = UnsafePointer(
                                plane.advanced(by: skip * 2 * MemoryLayout<Int16>.stride)
                            )
                            let converted = floats.withUnsafeMutableBytes { bytes in
                                var output: UnsafeMutablePointer<UInt8>? =
                                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                return withUnsafeMutablePointer(to: &output) { out in
                                    withUnsafePointer(to: &input) { inp in
                                        swr_convert(converter, out, Int32(capacity), inp, Int32(kept))
                                    }
                                }
                            }
                            guard converted == Int32(kept),
                                  swr_get_delay(converter, 44100) == 0
                            else { throw MatrixError.invalidFixture }
                            floats.removeLast(floats.count - kept * 2)
                            floats.withUnsafeMutableBufferPointer { samples in
                                SeekTransientRamp.apply(
                                    interleaved: samples.baseAddress!, frames: kept,
                                    channels: 2, fadeFrames: rampFrames,
                                    consumedFrames: &rampConsumed
                                )
                            }
                            let buffer = try self.makePCMBufferR10(
                                values: floats, frames: kept, tick: keptStart,
                                format: format
                            )
                            var observed = PCMSequenceR8()
                            try observed.append(buffer)
                            guard observed.firstTick == keptStart,
                                  observed.nextTick == end, observed.channels == 2,
                                  observed.frameCount == kept,
                                  CMTimeCompare(
                                      CMSampleBufferGetDuration(buffer),
                                      CMTime(value: Int64(kept), timescale: 44100)
                                  ) == 0
                            else { throw MatrixError.invalidTimestamp }
                            for i in 0..<observed.samples.count {
                                let absolute = Int(keptStart) * 2 + i
                                let rampIndex = framesEmitted + i / 2
                                let gain: Float = rampIndex < rampFrames
                                    ? Float(rampIndex + 1) / Float(rampFrames) : 1
                                let wanted = reference.samples[absolute] * gain
                                let error = abs(observed.samples[i] - wanted)
                                maxError = max(maxError, error)
                                if error > 0.000001 { differentValues += 1 }
                            }
                            if firstTick == nil { firstTick = keptStart }
                            endTick = end
                            framesEmitted += kept
                            outputBuffers += 1
                            peakBufferFrames = max(peakBufferFrames, capacity)
                            }
                        )
                        if result.code < 0 {
                            rejected += 1
                            print("G0_B03_R10_CASE \(label) seekCode=\(result.code)")
                            continue
                        }
                        let expectedFrames = Int(item.samples - target)
                        let complete = firstTick == target && endTick == item.samples
                            && framesEmitted == expectedFrames
                            && differentValues == 0
                            && rampConsumed == min(rampFrames, expectedFrames)
                        if complete { exact += 1 } else { incomplete += 1 }
                        print(
                            "G0_B03_R10_CASE \(label) seekCode=0 "
                                + "firstTick=\(firstTick.map(String.init) ?? "none") "
                                + "endTick=\(endTick.map(String.init) ?? "none") "
                                + "expectedFrames=\(expectedFrames) frames=\(framesEmitted) "
                                + "buffers=\(outputBuffers) droppedWholeFrames=\(discardedFrames) "
                                + "discardedSamples=\(discardedSamples) "
                                + "peakBufferFrames=\(peakBufferFrames) "
                                + "rampConsumed=\(rampConsumed) "
                                + "differentValues=\(differentValues) maxAbsError=\(maxError) "
                                + "complete=\(complete)"
                        )
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R10_CASE \(label) setupError=\(error)")
                    }
                }
            }
        }
        print(
            "G0_B03_R10_SUMMARY attempted=\(attempted) rejected=\(rejected) "
                + "exact=\(exact) incomplete=\(incomplete) setupErrors=\(setupErrors)"
        )
        XCTAssertEqual(attempted, 32)
        XCTAssertEqual(setupErrors, 0, "R10 observation incomplete")
        XCTAssertEqual(rejected + exact + incomplete, attempted)
    }

    /// R11 compares independent, bounded earlier seek anchors with the
    /// direct request. No FAST_SEEK, oracle packet offsets or production
    /// fallback. All candidates decode only real packets and compare
    /// retained PCM to a linear native reference at the ORIGINAL target.
    /// Packet payload byte counts exclude probing, priming, internal AVIO
    /// reads and container overhead; timings are observations, not a
    /// controlled performance benchmark.
    func testG0B03BoundedSeekRecoveryObservation() throws {
        let inputs: [(tag: String, samples: Int64, targets: [Int64])] = [
            ("025", 11025, [2756]),
            ("050", 22050, [11025]),
            ("200", 88200, [79380, 78336, 80640, 44100]),
            ("1000", 441000, [428544, 430848, 396900])
        ]
        // Fixed sample-grid offsets, independent of packet geometry.
        let strategies: [(name: String, backoff: Int64)] = [
            ("direct", 0), ("back125ms", 5512), ("back500ms", 22050)
        ]
        var attempted = 0
        var rejected = 0
        var exact = 0
        var incomplete = 0
        var setupErrors = 0
        for item in inputs {
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                let linear = try nativePCMSequenceR9(url: url, targetTick: nil)
                let reference = linear.pcm
                guard linear.code == 0, reference.firstTick == 0,
                      reference.endTick == item.samples, reference.stride > 0,
                      reference.data.count == Int(item.samples) * reference.stride
                else { throw MatrixError.invalidFixture }
                for target in item.targets {
                    for strategy in strategies {
                        attempted += 1
                        let anchor = max(Int64(0), target - strategy.backoff)
                        let label = "durationTag=\(item.tag) table=\(table) "
                            + "targetTick=\(target) strategy=\(strategy.name) anchorTick=\(anchor)"
                        var firstRaw: Int64?
                        var rawEnd: Int64?
                        var firstKept: Int64?
                        var keptEnd: Int64?
                        var decodedFrames = 0
                        var decodedSamples = 0
                        var discardedSamples = 0
                        var payloadBytes = 0
                        var packets = 0
                        var firstKeptPackets: Int?
                        var firstKeptBytes: Int?
                        var firstKeptNS: UInt64?
                        var seekNS: UInt64?
                        var comparedBytes = 0
                        var mismatchedFrames = 0
                        let started = DispatchTime.now().uptimeNanoseconds
                        do {
                            let result = try nativePCMSequenceR9(
                                url: url, targetTick: anchor,
                                onPacket: { size in
                                    packets += 1
                                    payloadBytes += size
                                },
                                onSeek: { _, elapsed in seekNS = elapsed },
                                onFrame: { frame in
                                var one = NativePCMSequenceR9()
                                try one.append(frame)
                                guard let start = one.firstTick,
                                      let end = one.endTick,
                                      end <= item.samples,
                                      rawEnd == nil || rawEnd == start,
                                      one.stride == reference.stride,
                                      one.sampleFormat == reference.sampleFormat
                                else { throw MatrixError.invalidFixture }
                                if firstRaw == nil { firstRaw = start }
                                rawEnd = end
                                decodedFrames += 1
                                decodedSamples += Int(end - start)
                                if end <= target {
                                    discardedSamples += Int(end - start)
                                    return
                                }
                                let kept = max(start, target)
                                discardedSamples += Int(kept - start)
                                guard keptEnd == nil || keptEnd == kept
                                else { throw MatrixError.invalidTimestamp }
                                if firstKept == nil {
                                    firstKept = kept
                                    firstKeptPackets = packets
                                    firstKeptBytes = payloadBytes
                                    firstKeptNS = DispatchTime.now().uptimeNanoseconds - started
                                }
                                keptEnd = end
                                let bytes = one.data.dropFirst(Int(kept - start) * one.stride)
                                let a = Int(kept) * reference.stride
                                let b = Int(end) * reference.stride
                                comparedBytes += bytes.count
                                if !bytes.elementsEqual(reference.data[a..<b]) {
                                    mismatchedFrames += 1
                                }
                                }
                            )
                            let totalNS = DispatchTime.now().uptimeNanoseconds - started
                            if result.code < 0 {
                                rejected += 1
                                print("G0_B03_R11_CASE \(label) seekCode=\(result.code)")
                            } else {
                                let complete = firstKept == target && keptEnd == item.samples
                                    && mismatchedFrames == 0
                                    && comparedBytes == Int(item.samples - target) * reference.stride
                                if complete { exact += 1 } else { incomplete += 1 }
                                print(
                                    "G0_B03_R11_CASE \(label) seekCode=0 "
                                        + "rawFirst=\(firstRaw.map(String.init) ?? "none") "
                                        + "rawEnd=\(rawEnd.map(String.init) ?? "none") "
                                        + "firstKept=\(firstKept.map(String.init) ?? "none") "
                                        + "keptEnd=\(keptEnd.map(String.init) ?? "none") "
                                        + "decodedFrames=\(decodedFrames) decodedSamples=\(decodedSamples) "
                                        + "discardedSamples=\(discardedSamples) packets=\(packets) "
                                        + "payloadBytes=\(payloadBytes) "
                                        + "firstKeptPackets=\(firstKeptPackets.map(String.init) ?? "none") "
                                        + "firstKeptBytes=\(firstKeptBytes.map(String.init) ?? "none") "
                                        + "comparedBytes=\(comparedBytes) mismatchedFrames=\(mismatchedFrames) "
                                        + "complete=\(complete)"
                                )
                            }
                            // Separate volatile timings from deterministic
                            // observation records for baseline/A1 comparison.
                            print(
                                "G0_B03_R11_TIMING \(label) "
                                    + "seekNS=\(seekNS.map(String.init) ?? "none") "
                                    + "firstKeptNS=\(firstKeptNS.map(String.init) ?? "none") totalNS=\(totalNS)"
                            )
                        } catch {
                            setupErrors += 1
                            print("G0_B03_R11_CASE \(label) setupError=\(error)")
                        }
                    }
                }
            }
        }
        print(
            "G0_B03_R11_SUMMARY attempted=\(attempted) rejected=\(rejected) "
                + "exact=\(exact) incomplete=\(incomplete) setupErrors=\(setupErrors)"
        )
        // Nine targets x two fixture variants x three independent anchors.
        // Clamped anchors may coincide intentionally in the shortest file.
        XCTAssertEqual(attempted, 54)
        XCTAssertEqual(setupErrors, 0, "R11 observation incomplete")
        XCTAssertEqual(rejected + exact + incomplete, attempted)
    }

    /// R12 compares two finite, sequential recovery policies. Retry
    /// only -1, in descending anchors, without changing the user target.
    /// Reuse keeps the failed demuxer state; reopen discards it and primes
    /// a new context per attempt. No fallback after a successful seek
    /// with incomplete output: that is separately reported.
    func testG0B03SequentialSeekRecoveryObservation() throws {
        let inputs: [(tag: String, samples: Int64, extra: [Int64])] = [
            ("025", 11025, []), ("050", 22050, []),
            ("200", 88200, [78336, 80640]),
            ("1000", 441000, [428544, 430848])
        ]
        var attempted = 0
        var exact = 0
        var eofExact = 0
        var rejected = 0
        var incomplete = 0
        var setupErrors = 0
        for item in inputs {
            // Original R8/R10 ticks plus sample boundaries and EOF.
            // Include the frame boundary on both sides (S16 fixtures).
            let seconds = Double(item.samples) / 44100.0
            let original = [0.0, 0.25, 0.5, 0.9].map {
                Int64(seconds * $0 / (1.0 / 44100.0))
            }
            let targets = Set(original + item.extra + [
                0, 1, 4607, 4608, 4609,
                item.samples - 2, item.samples - 1, item.samples
            ]).sorted()
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                let linear = try nativePCMSequenceR9(url: url, targetTick: nil)
                let reference = linear.pcm
                guard linear.code == 0, reference.firstTick == 0,
                      reference.endTick == item.samples, reference.stride > 0,
                      reference.data.count == Int(item.samples) * reference.stride
                else { throw MatrixError.invalidFixture }
                for target in targets {
                    // Stable deduplication after clamping; at most 3 seeks.
                    var anchors: [Int64] = []
                    for offset: Int64 in [0, 5512, 22050] {
                        let a = max(Int64(0), target - offset)
                        if !anchors.contains(a) { anchors.append(a) }
                    }
                    for reuse in [true, false] {
                        attempted += 1
                        let label = "durationTag=\(item.tag) table=\(table) "
                            + "targetTick=\(target) policy=\(reuse ? "reuse" : "reopen") "
                            + "plannedAnchors=\(anchors.map(String.init).joined(separator: ","))"
                        var codes: [Int32] = []
                        var seekTimes: [UInt64] = []
                        var contexts = 0
                        var primePackets = 0
                        var primeBytes = 0
                        var packets = 0
                        var payloadBytes = 0
                        var rawFirst: Int64?
                        var rawEnd: Int64?
                        var keptFirst: Int64?
                        var keptEnd: Int64?
                        var firstKeptPackets: Int?
                        var firstKeptBytes: Int?
                        var firstKeptNS: UInt64?
                        var discarded = 0
                        var comparedBytes = 0
                        var mismatched = 0
                        let started = DispatchTime.now().uptimeNanoseconds

                        func observe(_ frame: UnsafeMutablePointer<AVFrame>) throws {
                            var one = NativePCMSequenceR9()
                            try one.append(frame)
                            guard let start = one.firstTick, let end = one.endTick,
                                  end <= item.samples, rawEnd == nil || rawEnd == start,
                                  one.stride == reference.stride,
                                  one.sampleFormat == reference.sampleFormat
                            else { throw MatrixError.invalidFixture }
                            if rawFirst == nil { rawFirst = start }
                            rawEnd = end
                            if end <= target {
                                discarded += Int(end - start)
                                return
                            }
                            let kept = max(start, target)
                            discarded += Int(kept - start)
                            guard keptEnd == nil || keptEnd == kept
                            else { throw MatrixError.invalidTimestamp }
                            if keptFirst == nil {
                                keptFirst = kept
                                firstKeptPackets = primePackets + packets
                                firstKeptBytes = primeBytes + payloadBytes
                                firstKeptNS = DispatchTime.now().uptimeNanoseconds - started
                            }
                            keptEnd = end
                            let bytes = one.data.dropFirst(Int(kept - start) * one.stride)
                            let a = Int(kept) * reference.stride
                            let b = Int(end) * reference.stride
                            comparedBytes += bytes.count
                            if !bytes.elementsEqual(reference.data[a..<b]) {
                                mismatched += 1
                            }
                        }

                        do {
                            var finalCode: Int32 = -1
                            let starts = reuse ? [anchors[0]] : anchors
                            for start in starts {
                                contexts += 1
                                let result = try nativePCMSequenceR9(
                                    url: url, targetTick: start,
                                    retryAnchors: reuse ? Array(anchors.dropFirst()) : [],
                                    onPrimePacket: { size in
                                        primePackets += 1
                                        primeBytes += size
                                    },
                                    onPacket: { size in
                                        packets += 1
                                        payloadBytes += size
                                    },
                                    onSeek: { code, elapsed in
                                        codes.append(code)
                                        seekTimes.append(elapsed)
                                    },
                                    onFrame: observe
                                )
                                finalCode = result.code
                                if finalCode != -1 { break }
                            }
                            guard !codes.isEmpty, codes.count <= anchors.count,
                                  codes.last == finalCode,
                                  codes.dropLast().allSatisfy({ $0 == -1 })
                            else { throw MatrixError.invalidFixture }
                            let attemptedAnchors = anchors.prefix(codes.count)
                                .map(String.init).joined(separator: ",")
                            let path = "attemptedAnchors=\(attemptedAnchors) "
                                + "codes=\(codes.map(String.init).joined(separator: ",")) "
                                + "contexts=\(contexts) primePackets=\(primePackets) primeBytes=\(primeBytes)"
                            if finalCode < 0 {
                                rejected += 1
                                print("G0_B03_R12_CASE \(label) \(path) finalCode=\(finalCode)")
                            } else {
                                // EOF is an empty interval, not a claim that
                                // a native seek to EOF succeeded without a retry.
                                // Require actual contiguous decode reaching EOF.
                                let emptyEOF = target == item.samples
                                    && rawFirst != nil && rawEnd == item.samples
                                    && keptFirst == nil && keptEnd == nil
                                    && comparedBytes == 0 && mismatched == 0
                                let full = target < item.samples
                                    && keptFirst == target && keptEnd == item.samples
                                    && comparedBytes == Int(item.samples - target) * reference.stride
                                    && mismatched == 0
                                if emptyEOF { eofExact += 1 }
                                else if full { exact += 1 }
                                else { incomplete += 1 }
                                print(
                                    "G0_B03_R12_CASE \(label) \(path) finalCode=0 "
                                        + "rawFirst=\(rawFirst.map(String.init) ?? "none") "
                                        + "rawEnd=\(rawEnd.map(String.init) ?? "none") "
                                        + "firstKept=\(keptFirst.map(String.init) ?? "none") "
                                        + "keptEnd=\(keptEnd.map(String.init) ?? "none") "
                                        + "discardedSamples=\(discarded) packets=\(packets) "
                                        + "payloadBytes=\(payloadBytes) "
                                        + "firstKeptPackets=\(firstKeptPackets.map(String.init) ?? "none") "
                                        + "firstKeptBytes=\(firstKeptBytes.map(String.init) ?? "none") "
                                        + "comparedBytes=\(comparedBytes) mismatchedFrames=\(mismatched) "
                                        + "complete=\(full) eofExact=\(emptyEOF)"
                                )
                            }
                            let totalNS = DispatchTime.now().uptimeNanoseconds - started
                            print(
                                "G0_B03_R12_TIMING \(label) "
                                    + "seekNS=\(seekTimes.map(String.init).joined(separator: ",")) "
                                    + "firstKeptNS=\(firstKeptNS.map(String.init) ?? "none") totalNS=\(totalNS)"
                            )
                        } catch {
                            setupErrors += 1
                            print("G0_B03_R12_CASE \(label) setupError=\(error)")
                        }
                    }
                }
            }
        }
        print(
            "G0_B03_R12_SUMMARY attempted=\(attempted) exact=\(exact) "
                + "eofExact=\(eofExact) rejected=\(rejected) "
                + "incomplete=\(incomplete) setupErrors=\(setupErrors)"
        )
        // (4 fixtures x 11 unique targets + 4 extra) x
        // 2 table variants x 2 policies. Zero is shared by both sets.
        XCTAssertEqual(attempted, 192)
        XCTAssertEqual(setupErrors, 0, "R12 observation incomplete")
        XCTAssertEqual(exact + eofExact + rejected + incomplete, attempted)
    }

    /// R13 extends native FLAC coverage; all previous tests keep their
    /// original 44.1 kHz stereo defaults. No production changes.
    func testG0B03ExpandedFLACRecoveryObservation() throws {
        let inputs: [(tag: String, rate: Int32, channels: Int,
                      bits: Int, block: Int64, samples: Int64)] = [
            ("mono48_s16_b1024", 48000, 1, 16, 1024, 24000),
            ("surround48_s24_b4096", 48000, 6, 24, 4096, 72000),
            ("stereo96_s24_b4096", 96000, 2, 24, 4096, 192000),
            ("stereo192_s24_b8192", 192000, 2, 24, 8192, 384000),
            ("stereo44_s16_b4608_long", 44100, 2, 16, 4608, 1323000),
            ("stereo96_s24_b8192_short", 96000, 2, 24, 8192, 24000)
        ]
        var attempted = 0
        var exact = 0
        var eofExact = 0
        var rejected = 0
        var incomplete = 0
        var setupErrors = 0
        for item in inputs {
            let targets: [Int64] = [
                0, 1, item.block - 1, item.block, item.block + 1,
                item.samples / 2, item.samples * 9 / 10,
                item.samples - 2, item.samples - 1, item.samples
            ]
            for table in [false, true] {
                let url = try fixture("r13_\(item.tag)", withSeektable: table)
                let linear = try nativePCMSequenceR9(
                    url: url, targetTick: nil,
                    expectedRate: item.rate, expectedChannels: item.channels
                )
                let reference = linear.pcm
                let expectedWidth = item.bits == 16 ? 2 : 4
                guard linear.code == 0, reference.firstTick == 0,
                      reference.endTick == item.samples,
                      reference.channels == item.channels,
                      reference.bytesPerSample == expectedWidth,
                      reference.data.count == Int(item.samples) * reference.stride
                else { throw MatrixError.invalidFixture }
                let expectedFormat = item.bits == 16
                    ? AV_SAMPLE_FMT_S16.rawValue : AV_SAMPLE_FMT_S32.rawValue
                let expectedPlanar = item.bits == 16
                    ? AV_SAMPLE_FMT_S16P.rawValue : AV_SAMPLE_FMT_S32P.rawValue
                guard reference.sampleFormat == expectedFormat
                        || reference.sampleFormat == expectedPlanar
                else { throw MatrixError.invalidFixture }
                let expectedStarts = stride(
                    from: Int64(0), to: item.samples, by: Int(item.block)
                ).map { $0 }
                guard reference.frameStarts == expectedStarts
                else { throw MatrixError.invalidFixture }
                print(
                    "G0_B03_R13_REFERENCE tag=\(item.tag) table=\(table) "
                        + "rate=\(item.rate) channels=\(item.channels) bits=\(item.bits) "
                        + "block=\(item.block) samples=\(item.samples) "
                        + "decodedFrames=\(reference.frameStarts.count) "
                        + "format=\(reference.sampleFormat ?? -1) stride=\(reference.stride)"
                )
                for target in targets {
                    attempted += 1
                    let label = "tag=\(item.tag) table=\(table) targetTick=\(target)"
                    var anchors: [Int64] = []
                    for offset: Int64 in [0, Int64(item.rate) / 8, Int64(item.rate) / 2] {
                        let a = max(0, target - offset)
                        if !anchors.contains(a) { anchors.append(a) }
                    }
                    var codes: [Int32] = []
                    var rawFirst: Int64?
                    var rawEnd: Int64?
                    var keptFirst: Int64?
                    var keptEnd: Int64?
                    var comparedBytes = 0
                    var mismatches = 0
                    var discarded = 0
                    var packets = 0
                    var payloadBytes = 0
                    var firstKeptPackets: Int?
                    var firstKeptBytes: Int?
                    do {
                        let result = try nativePCMSequenceR9(
                            url: url, targetTick: target,
                            expectedRate: item.rate, expectedChannels: item.channels,
                            retryAnchors: Array(anchors.dropFirst()),
                            onPacket: { size in
                                packets += 1
                                payloadBytes += size
                            },
                            onSeek: { code, _ in codes.append(code) },
                            onFrame: { frame in
                                var one = NativePCMSequenceR9()
                                try one.append(
                                    frame, expectedRate: item.rate,
                                    expectedChannels: item.channels
                                )
                                guard let start = one.firstTick, let end = one.endTick,
                                      end <= item.samples, rawEnd == nil || rawEnd == start,
                                      one.stride == reference.stride,
                                      one.sampleFormat == reference.sampleFormat
                                else { throw MatrixError.invalidFixture }
                                if rawFirst == nil { rawFirst = start }
                                rawEnd = end
                                if end <= target {
                                    discarded += Int(end - start)
                                    return
                                }
                                let kept = max(start, target)
                                discarded += Int(kept - start)
                                guard keptEnd == nil || keptEnd == kept
                                else { throw MatrixError.invalidTimestamp }
                                if keptFirst == nil {
                                    keptFirst = kept
                                    firstKeptPackets = packets
                                    firstKeptBytes = payloadBytes
                                }
                                keptEnd = end
                                let bytes = one.data.dropFirst(Int(kept - start) * one.stride)
                                let a = Int(kept) * reference.stride
                                let b = Int(end) * reference.stride
                                comparedBytes += bytes.count
                                if !bytes.elementsEqual(reference.data[a..<b]) {
                                    mismatches += 1
                                }
                            }
                        )
                        guard !codes.isEmpty, codes.count <= anchors.count,
                              codes.last == result.code,
                              codes.dropLast().allSatisfy({ $0 == -1 })
                        else { throw MatrixError.invalidFixture }
                        let path = "anchors=\(anchors.prefix(codes.count).map(String.init).joined(separator: ",")) "
                            + "codes=\(codes.map(String.init).joined(separator: ","))"
                        if result.code < 0 {
                            rejected += 1
                            print("G0_B03_R13_CASE \(label) \(path) finalCode=\(result.code)")
                            continue
                        }
                        let full = target < item.samples
                            && keptFirst == target && keptEnd == item.samples
                            && comparedBytes == Int(item.samples - target) * reference.stride
                            && mismatches == 0
                        let emptyEOF = target == item.samples
                            && rawFirst != nil && rawEnd == item.samples
                            && keptFirst == nil && keptEnd == nil
                            && comparedBytes == 0 && mismatches == 0
                        if full { exact += 1 }
                        else if emptyEOF { eofExact += 1 }
                        else { incomplete += 1 }
                        print(
                            "G0_B03_R13_CASE \(label) \(path) finalCode=0 "
                                + "rawFirst=\(rawFirst.map(String.init) ?? "none") "
                                + "rawEnd=\(rawEnd.map(String.init) ?? "none") "
                                + "firstKept=\(keptFirst.map(String.init) ?? "none") "
                                + "keptEnd=\(keptEnd.map(String.init) ?? "none") "
                                + "discardedSamples=\(discarded) packets=\(packets) "
                                + "payloadBytes=\(payloadBytes) "
                                + "firstKeptPackets=\(firstKeptPackets.map(String.init) ?? "none") "
                                + "firstKeptBytes=\(firstKeptBytes.map(String.init) ?? "none") "
                                + "comparedBytes=\(comparedBytes) mismatchedFrames=\(mismatches) "
                                + "complete=\(full) eofExact=\(emptyEOF)"
                        )
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R13_CASE \(label) setupError=\(error)")
                    }
                }
            }
        }
        print(
            "G0_B03_R13_SUMMARY attempted=\(attempted) exact=\(exact) "
                + "eofExact=\(eofExact) rejected=\(rejected) "
                + "incomplete=\(incomplete) setupErrors=\(setupErrors)"
        )
        XCTAssertEqual(attempted, 120)
        XCTAssertEqual(setupErrors, 0, "R13 observation incomplete")
        XCTAssertEqual(exact + eofExact + rejected + incomplete, attempted)
    }

    /// R14 joins R12/R13 sequential recovery to R10's sample-granular
    /// native cut, real SWR and CoreMedia. Same-rate packed S16/S32 FLAC
    /// only. The linear AudioDecoder reference is independent of seek.
    /// Compare every channel, including the actual seek ramp.
    func testG0B03ExpandedCoreMediaRecoveryObservation() throws {
        let inputs: [(tag: String, rate: Int32, channels: Int,
                      bits: Int, block: Int64, samples: Int64, control: Int64?)] = [
            ("025", 44100, 2, 16, 4608, 11025, 2756),
            ("050", 44100, 2, 16, 4608, 22050, 11025),
            ("200", 44100, 2, 16, 4608, 88200, 79380),
            ("r13_mono48_s16_b1024", 48000, 1, 16, 1024, 24000, nil),
            ("r13_surround48_s24_b4096", 48000, 6, 24, 4096, 72000, nil),
            ("r13_stereo96_s24_b4096", 96000, 2, 24, 4096, 192000, nil),
            ("r13_stereo192_s24_b8192", 192000, 2, 24, 8192, 384000, nil),
            ("r13_stereo44_s16_b4608_long", 44100, 2, 16, 4608, 1323000, nil),
            ("r13_stereo96_s24_b8192_short", 96000, 2, 24, 8192, 24000, nil)
        ]
        var attempted = 0
        var exact = 0
        var eofExact = 0
        var rejected = 0
        var incomplete = 0
        var setupErrors = 0
        for item in inputs {
            let targets: [Int64]
            if let control = item.control {
                // All six original direct-seek failures.
                targets = [control]
            } else {
                targets = [0, 1, item.block - 1, item.block, item.block + 1,
                           item.samples / 2, item.samples * 9 / 10,
                           item.samples - 2, item.samples - 1, item.samples]
            }
            let fadeFrames = SeekTransientRamp.frameCount(sampleRate: item.rate)
            let inputFormat = item.bits == 16 ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S32
            let width = item.bits == 16 ? 2 : 4
            let expectedTag: AudioChannelLayoutTag
            switch item.channels {
            case 1: expectedTag = kAudioChannelLayoutTag_Mono
            case 2: expectedTag = kAudioChannelLayoutTag_Stereo
            case 6: expectedTag = kAudioChannelLayoutTag_MPEG_5_1_A
            default: throw MatrixError.invalidFixture
            }
            for table in [false, true] {
                let url = try fixture(item.tag, withSeektable: table)
                let linear = AudioDecoder()
                linear.limiterEnabled = false
                try linear.adopt(OpenedSource.open(url: url))
                defer { linear.close() }
                guard let firstBuffer = try linear.readNextBuffer(),
                      let format = CMSampleBufferGetFormatDescription(firstBuffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
                else { throw MatrixError.missingPCM }
                var layoutSize = 0
                guard let channelLayout = CMAudioFormatDescriptionGetChannelLayout(
                    format, sizeOut: &layoutSize
                ), layoutSize >= MemoryLayout<AudioChannelLayout>.size,
                      channelLayout.pointee.mChannelLayoutTag == expectedTag,
                      asbd.pointee.mSampleRate == Double(item.rate),
                      asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                      asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      asbd.pointee.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                      asbd.pointee.mChannelsPerFrame == UInt32(item.channels),
                      asbd.pointee.mBytesPerFrame == UInt32(item.channels * 4),
                      asbd.pointee.mBitsPerChannel == 32
                else { throw MatrixError.invalidFixture }
                var reference = PCMSequenceR8()
                try reference.append(firstBuffer, rate: item.rate)
                for _ in 0..<2048 {
                    guard let buffer = try linear.readNextBuffer() else { break }
                    try reference.append(buffer, rate: item.rate)
                }
                guard reference.firstTick == 0, reference.nextTick == item.samples,
                      Int64(reference.frameCount) == item.samples,
                      reference.channels == item.channels
                else { throw MatrixError.invalidFixture }
                linear.close()
                print(
                    "G0_B03_R14_REFERENCE tag=\(item.tag) table=\(table) "
                        + "rate=\(item.rate) channels=\(item.channels) bits=\(item.bits) "
                        + "frames=\(item.samples) layoutTag=\(expectedTag) rampFrames=\(fadeFrames)"
                )
                for target in targets {
                    attempted += 1
                    let label = "tag=\(item.tag) table=\(table) targetTick=\(target)"
                    var anchors: [Int64] = []
                    for offset: Int64 in [0, Int64(item.rate) / 8, Int64(item.rate) / 2] {
                        let a = max(0, target - offset)
                        if !anchors.contains(a) { anchors.append(a) }
                    }
                    var swr: OpaquePointer?
                    defer { swr_free(&swr) }
                    var codes: [Int32] = []
                    var rawFirst: Int64?
                    var rawEnd: Int64?
                    var firstTick: Int64?
                    var endTick: Int64?
                    var rampConsumed = 0
                    var framesEmitted = 0
                    var outputBuffers = 0
                    var discardedSamples = 0
                    var peakBufferFrames = 0
                    var differentValues = 0
                    var maxError: Float = 0
                    var channelErrors = [Float](repeating: 0, count: item.channels)
                    do {
                        let result = try nativePCMSequenceR9(
                            url: url, targetTick: target,
                            expectedRate: item.rate, expectedChannels: item.channels,
                            retryAnchors: Array(anchors.dropFirst()),
                            onSeek: { code, _ in codes.append(code) },
                            onFrame: { frame in
                                let value = frame.pointee
                                let start = value.pts
                                let count = Int(value.nb_samples)
                                guard start >= 0, count > 0,
                                      value.sample_rate == item.rate,
                                      Int(value.ch_layout.nb_channels) == item.channels,
                                      value.format == inputFormat.rawValue,
                                      let planes = value.extended_data,
                                      let plane = planes[0]
                                else { throw MatrixError.invalidFixture }
                                let end = start + Int64(count)
                                guard end <= item.samples,
                                      rawEnd == nil || rawEnd == start
                                else { throw MatrixError.invalidTimestamp }
                                if rawFirst == nil { rawFirst = start }
                                rawEnd = end
                                if end <= target {
                                    discardedSamples += count
                                    return
                                }
                                let keptStart = max(start, target)
                                let skip = Int(keptStart - start)
                                let kept = count - skip
                                discardedSamples += skip
                                guard kept > 0, endTick == nil || endTick == keptStart
                                else { throw MatrixError.invalidTimestamp }
                                if swr == nil {
                                    var inLayout = AVChannelLayout()
                                    var outLayout = AVChannelLayout()
                                    defer {
                                        av_channel_layout_uninit(&inLayout)
                                        av_channel_layout_uninit(&outLayout)
                                    }
                                    guard av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout) >= 0
                                    else { throw MatrixError.invalidFixture }
                                    AudioDecoder.makeResamplerOutputLayout(
                                        channels: Int32(item.channels), into: &outLayout
                                    )
                                    let rc = swr_alloc_set_opts2(
                                        &swr, &outLayout, AV_SAMPLE_FMT_FLT, item.rate,
                                        &inLayout, inputFormat, item.rate, 0, nil
                                    )
                                    guard rc >= 0, let swr, swr_init(swr) >= 0
                                    else { throw MatrixError.invalidFixture }
                                }
                                guard let converter = swr else {
                                    throw MatrixError.invalidFixture
                                }
                                let capacity = Int(swr_get_out_samples(converter, Int32(kept)))
                                guard capacity >= kept else { throw MatrixError.invalidFixture }
                                var floats = [Float](repeating: 0, count: capacity * item.channels)
                                var input: UnsafePointer<UInt8>? = UnsafePointer(
                                    plane.advanced(by: skip * item.channels * width)
                                )
                                let converted = floats.withUnsafeMutableBytes { bytes in
                                    var output: UnsafeMutablePointer<UInt8>? =
                                        bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                    return withUnsafeMutablePointer(to: &output) { out in
                                        withUnsafePointer(to: &input) { inp in
                                            swr_convert(converter, out, Int32(capacity), inp, Int32(kept))
                                        }
                                    }
                                }
                                guard converted == Int32(kept),
                                      swr_get_delay(converter, Int64(item.rate)) == 0
                                else { throw MatrixError.invalidFixture }
                                floats.removeLast(floats.count - kept * item.channels)
                                floats.withUnsafeMutableBufferPointer { samples in
                                    SeekTransientRamp.apply(
                                        interleaved: samples.baseAddress!, frames: kept,
                                        channels: item.channels, fadeFrames: fadeFrames,
                                        consumedFrames: &rampConsumed
                                    )
                                }
                                let buffer = try self.makePCMBufferR10(
                                    values: floats, frames: kept, tick: keptStart,
                                    format: format, rate: item.rate
                                )
                                var observed = PCMSequenceR8()
                                try observed.append(buffer, rate: item.rate)
                                guard observed.firstTick == keptStart,
                                      observed.nextTick == end,
                                      observed.channels == item.channels,
                                      observed.frameCount == kept,
                                      CMTimeCompare(
                                          CMSampleBufferGetPresentationTimeStamp(buffer),
                                          CMTime(value: keptStart, timescale: item.rate)
                                      ) == 0,
                                      CMTimeCompare(
                                          CMSampleBufferGetDuration(buffer),
                                          CMTime(value: Int64(kept), timescale: item.rate)
                                      ) == 0
                                else { throw MatrixError.invalidTimestamp }
                                for i in 0..<observed.samples.count {
                                    let absolute = Int(keptStart) * item.channels + i
                                    let rampIndex = framesEmitted + i / item.channels
                                    let gain: Float = rampIndex < fadeFrames
                                        ? Float(rampIndex + 1) / Float(fadeFrames) : 1
                                    let wanted = reference.samples[absolute] * gain
                                    let error = abs(observed.samples[i] - wanted)
                                    maxError = max(maxError, error)
                                    let channel = i % item.channels
                                    channelErrors[channel] = max(channelErrors[channel], error)
                                    if error > 0.000001 { differentValues += 1 }
                                }
                                if firstTick == nil { firstTick = keptStart }
                                endTick = end
                                framesEmitted += kept
                                outputBuffers += 1
                                peakBufferFrames = max(peakBufferFrames, capacity)
                            }
                        )
                        guard !codes.isEmpty, codes.count <= anchors.count,
                              codes.last == result.code,
                              codes.dropLast().allSatisfy({ $0 == -1 })
                        else { throw MatrixError.invalidFixture }
                        let path = "anchors=\(anchors.prefix(codes.count).map(String.init).joined(separator: ",")) "
                            + "codes=\(codes.map(String.init).joined(separator: ","))"
                        if result.code < 0 {
                            rejected += 1
                            print("G0_B03_R14_CASE \(label) \(path) finalCode=\(result.code)")
                            continue
                        }
                        let expectedFrames = Int(item.samples - target)
                        let full = target < item.samples
                            && firstTick == target && endTick == item.samples
                            && framesEmitted == expectedFrames && differentValues == 0
                            && rampConsumed == min(fadeFrames, expectedFrames)
                        let emptyEOF = target == item.samples
                            && rawFirst != nil && rawEnd == item.samples
                            && firstTick == nil && endTick == nil
                            && framesEmitted == 0 && outputBuffers == 0
                            && rampConsumed == 0 && differentValues == 0
                        if full { exact += 1 }
                        else if emptyEOF { eofExact += 1 }
                        else { incomplete += 1 }
                        let perChannel = channelErrors.map { String($0) }.joined(separator: ",")
                        print(
                            "G0_B03_R14_CASE \(label) \(path) finalCode=0 "
                                + "rawFirst=\(rawFirst.map(String.init) ?? "none") "
                                + "rawEnd=\(rawEnd.map(String.init) ?? "none") "
                                + "firstTick=\(firstTick.map(String.init) ?? "none") "
                                + "endTick=\(endTick.map(String.init) ?? "none") "
                                + "frames=\(framesEmitted) expectedFrames=\(expectedFrames) "
                                + "buffers=\(outputBuffers) discardedSamples=\(discardedSamples) "
                                + "peakBufferFrames=\(peakBufferFrames) rampConsumed=\(rampConsumed) "
                                + "differentValues=\(differentValues) maxAbsError=\(maxError) "
                                + "channelMaxErrors=\(perChannel) complete=\(full) eofExact=\(emptyEOF)"
                        )
                    } catch {
                        setupErrors += 1
                        print("G0_B03_R14_CASE \(label) setupError=\(error)")
                    }
                }
            }
        }
        print(
            "G0_B03_R14_SUMMARY attempted=\(attempted) exact=\(exact) "
                + "eofExact=\(eofExact) rejected=\(rejected) "
                + "incomplete=\(incomplete) setupErrors=\(setupErrors)"
        )
        XCTAssertEqual(attempted, 126)
        XCTAssertEqual(setupErrors, 0, "R14 observation incomplete")
        XCTAssertEqual(exact + eofExact + rejected + incomplete, attempted)
    }

    /// R15A: actual production HTTPStream/HTTPTransport/AVIO and linked
    /// demuxer, with a deterministic URLProtocol endpoint. No sockets,
    /// physical network bytes, external CDN or timing benchmark.
    func testG0B03HTTPTransportRecoveryObservation() throws {
        let inputs: [(tag: String, rate: Int32, channels: Int,
                      samples: Int64, targets: [Int64])] = [
            ("025", 44100, 2, 11025, [2756, 9922, 11024]),
            ("r13_stereo96_s24_b8192_short", 96000, 2, 24000, [1, 8191, 23999]),
            ("r13_stereo192_s24_b8192", 192000, 2, 384000, [192000, 345600, 383999]),
            ("r13_stereo44_s16_b4608_long", 44100, 2, 1323000, [661500, 1190700, 1322999])
        ]
        var attempted = 0
        var exact = 0
        var rejected = 0
        var incomplete = 0
        var errors = 0
        var multiWindowCases = 0
        for item in inputs {
            for table in [false, true] {
                let local = try fixture(item.tag, withSeektable: table)
                let bytes = try Data(contentsOf: local)
                // Bound the HTTP200 experiment; production itself has no cap.
                guard bytes.count > 0, bytes.count <= 8 * 1024 * 1024
                else { throw MatrixError.invalidFixture }
                if item.samples == 1323000 || item.rate == 192000 {
                    XCTAssertGreaterThan(bytes.count, 1 << 20)
                }
                let linear = try nativePCMSequenceR9(
                    url: local, targetTick: nil,
                    expectedRate: item.rate, expectedChannels: item.channels
                )
                let reference = linear.pcm
                guard linear.code == 0, reference.firstTick == 0,
                      reference.endTick == item.samples, reference.stride > 0,
                      reference.data.count == Int(item.samples) * reference.stride
                else { throw MatrixError.invalidFixture }
                for target in item.targets {
                    for range in [true, false] {
                        attempted += 1
                        G0R15URLProtocol.state.configure(payload: bytes, range: range)
                        defer { G0R15URLProtocol.state.configure(payload: Data(), range: true) }
                        let config = URLSessionConfiguration.ephemeral
                        config.protocolClasses = [G0R15URLProtocol.self]
                        let url = URL(string: "https://g0-r15.invalid/fixture.flac")!
                        let label = "tag=\(item.tag) table=\(table) targetTick=\(target) "
                            + "mode=\(range ? "range206" : "full200") fileBytes=\(bytes.count)"
                        var anchors: [Int64] = []
                        for offset: Int64 in [0, Int64(item.rate) / 8, Int64(item.rate) / 2] {
                            let a = max(0, target - offset)
                            if !anchors.contains(a) { anchors.append(a) }
                        }
                        var codes: [Int32] = []
                        var openRequests = -1
                        var openBytes = -1
                        var seekRequests: [Int] = []
                        var seekBytes: [Int] = []
                        var rawEnd: Int64?
                        var firstKept: Int64?
                        var keptEnd: Int64?
                        var firstRequests = -1
                        var firstBytes = -1
                        var comparedBytes = 0
                        var mismatches = 0
                        var discarded = 0
                        var packets = 0
                        var payloadBytes = 0
                        let started = DispatchTime.now().uptimeNanoseconds
                        var firstNS: UInt64?
                        do {
                            let result = try nativePCMSequenceR9(
                                url: url, targetTick: target,
                                sessionConfiguration: config,
                                onOpened: {
                                    let snapshot = G0R15URLProtocol.state.snapshot()
                                    openRequests = snapshot.count
                                    openBytes = snapshot.reduce(0) { $0 + $1.bytes }
                                },
                                expectedRate: item.rate, expectedChannels: item.channels,
                                retryAnchors: Array(anchors.dropFirst()),
                                onPacket: { size in
                                    packets += 1
                                    payloadBytes += size
                                },
                                onSeek: { code, _ in
                                    codes.append(code)
                                    let snapshot = G0R15URLProtocol.state.snapshot()
                                    seekRequests.append(snapshot.count)
                                    seekBytes.append(snapshot.reduce(0) { $0 + $1.bytes })
                                },
                                onFrame: { frame in
                                    var one = NativePCMSequenceR9()
                                    try one.append(
                                        frame, expectedRate: item.rate,
                                        expectedChannels: item.channels
                                    )
                                    guard let start = one.firstTick, let end = one.endTick,
                                          end <= item.samples, rawEnd == nil || rawEnd == start,
                                          one.stride == reference.stride,
                                          one.sampleFormat == reference.sampleFormat
                                    else { throw MatrixError.invalidFixture }
                                    rawEnd = end
                                    if end <= target {
                                        discarded += Int(end - start)
                                        return
                                    }
                                    let kept = max(start, target)
                                    discarded += Int(kept - start)
                                    guard keptEnd == nil || keptEnd == kept
                                    else { throw MatrixError.invalidTimestamp }
                                    if firstKept == nil {
                                        firstKept = kept
                                        let snapshot = G0R15URLProtocol.state.snapshot()
                                        firstRequests = snapshot.count
                                        firstBytes = snapshot.reduce(0) { $0 + $1.bytes }
                                        firstNS = DispatchTime.now().uptimeNanoseconds - started
                                    }
                                    keptEnd = end
                                    let actual = one.data.dropFirst(Int(kept - start) * one.stride)
                                    let a = Int(kept) * reference.stride
                                    let b = Int(end) * reference.stride
                                    comparedBytes += actual.count
                                    if !actual.elementsEqual(reference.data[a..<b]) { mismatches += 1 }
                                }
                            )
                            guard !codes.isEmpty, codes.count <= anchors.count,
                                  codes.last == result.code,
                                  codes.dropLast().allSatisfy({ $0 == -1 })
                            else { throw MatrixError.invalidFixture }
                            let events = G0R15URLProtocol.state.snapshot()
                            let bodyBytes = events.reduce(0) { $0 + $1.bytes }
                            let starts = Set(events.map { $0.start })
                            let intervals = events.filter { $0.bytes > 0 }
                                .sorted { $0.start < $1.start }
                            var uniqueBytes = 0
                            var coveredEnd = 0
                            for e in intervals {
                                let end = e.start + e.bytes
                                uniqueBytes += max(0, end - max(coveredEnd, e.start))
                                coveredEnd = max(coveredEnd, end)
                            }
                            if range && starts.count > 1 && bytes.count > (1 << 20) {
                                multiWindowCases += 1
                            }
                            let transportValid = !events.isEmpty
                                && events.allSatisfy { e in
                                    e.status == (range ? 206 : 200)
                                        && e.start >= 0 && e.start + e.bytes <= bytes.count
                                        && e.bytes > 0
                                        && (!range || e.bytes <= 1 << 20)
                                }
                                && (range || (events.count == 1 && bodyBytes == bytes.count))
                            let full = result.code == 0 && firstKept == target
                                && keptEnd == item.samples
                                && comparedBytes == Int(item.samples - target) * reference.stride
                                && mismatches == 0 && transportValid
                            if result.code < 0 { rejected += 1 }
                            else if full { exact += 1 }
                            else { incomplete += 1 }
                            let path = events.map { "\($0.requestStart):\($0.start):\($0.status):\($0.bytes)" }
                                .joined(separator: ",")
                            print(
                                "G0_B03_R15_CASE \(label) "
                                    + "codes=\(codes.map(String.init).joined(separator: ",")) "
                                    + "finalCode=\(result.code) requests=\(events.count) "
                                    + "bodyBytes=\(bodyBytes) uniqueBytes=\(uniqueBytes) "
                                    + "overlapBytes=\(bodyBytes - uniqueBytes) distinctStarts=\(starts.count) "
                                    + "openRequests=\(openRequests) openBytes=\(openBytes) "
                                    + "seekRequests=\(seekRequests.map(String.init).joined(separator: ",")) "
                                    + "seekBytes=\(seekBytes.map(String.init).joined(separator: ",")) "
                                    + "firstRequests=\(firstRequests) firstBytes=\(firstBytes) "
                                    + "firstKept=\(firstKept.map(String.init) ?? "none") "
                                    + "keptEnd=\(keptEnd.map(String.init) ?? "none") "
                                    + "discardedSamples=\(discarded) packets=\(packets) "
                                    + "payloadBytes=\(payloadBytes) comparedBytes=\(comparedBytes) "
                                    + "mismatches=\(mismatches) transportValid=\(transportValid) complete=\(full)"
                            )
                            print("G0_B03_R15_REQUESTS \(label) path=\(path)")
                            let totalNS = DispatchTime.now().uptimeNanoseconds - started
                            print(
                                "G0_B03_R15_TIMING \(label) "
                                    + "firstKeptNS=\(firstNS.map(String.init) ?? "none") totalNS=\(totalNS)"
                            )
                        } catch {
                            errors += 1
                            let events = G0R15URLProtocol.state.snapshot()
                            print("G0_B03_R15_CASE \(label) setupOrDecodeError=\(error) requests=\(events.count)")
                        }
                    }
                }
            }
        }
        print(
            "G0_B03_R15_SUMMARY attempted=\(attempted) exact=\(exact) "
                + "rejected=\(rejected) incomplete=\(incomplete) errors=\(errors) "
                + "multiWindowCases=\(multiWindowCases)"
        )
        XCTAssertEqual(attempted, 48)
        XCTAssertEqual(exact + rejected + incomplete + errors, attempted)
        // Transport/decode failures are observations; do not hide them.
    }

    /// Exercise the actual HTTPTransport AVIO callback error/EOF boundary
    /// without involving a demuxer. A mock endpoint, not a network test.
    func testG0B03HTTPAVIOFaultObservation() throws {
        let data = Data([11, 22, 33, 44, 55, 66, 77, 88])
        let cases: [(name: String, failures: Int, status: Int, malformed: Bool)] = [
            ("clean", 0, 0, false),
            ("retry503", 1, 503, false),
            ("persistent503", 3, 503, false),
            ("forbidden403", 1, 403, false),
            ("badContentRange", 0, 0, true)
        ]
        var observed = 0
        for item in cases {
            G0R15URLProtocol.state.configure(
                payload: data, range: true, failures: item.failures,
                failureStatus: item.status, malformed: item.malformed
            )
            defer { G0R15URLProtocol.state.configure(payload: Data(), range: true) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [G0R15URLProtocol.self]
            let stream = HTTPStream(
                url: URL(string: "https://g0-r15.invalid/fault")!,
                headers: [:], configuration: config
            )
            guard let transport = HTTPTransport(stream: stream),
                  let context = transport.context
            else { throw MatrixError.invalidFixture }
            defer { transport.close() }
            var buffer = [UInt8](repeating: 0, count: data.count)
            let first = buffer.withUnsafeMutableBufferPointer {
                avio_read(context, $0.baseAddress!, Int32(data.count))
            }
            var tail: UInt8 = 0
            let next = avio_read(context, &tail, 1)
            let events = G0R15URLProtocol.state.snapshot()
            let success = item.name == "clean" || item.name == "retry503"
            let wantedRequests = item.name == "retry503" ? 2 : item.name == "persistent503" ? 3 : 1
            let correct = events.count == wantedRequests && (success
                ? first == Int32(data.count) && Data(buffer) == data
                    && next == -541_478_725 && !stream.hasError
                : first == -5 && next == -5 && stream.hasError)
            if correct { observed += 1 }
            print(
                "G0_B03_R15_FAULT name=\(item.name) first=\(first) next=\(next) "
                    + "hasError=\(stream.hasError) requests=\(events.count) "
                    + "statuses=\(events.map { String($0.status) }.joined(separator: ",")) "
                    + "correct=\(correct)"
            )
        }
        print("G0_B03_R15_FAULT_SUMMARY attempted=5 correct=\(observed)")
        XCTAssertEqual(observed, 5)
    }

    /// R15B1: isolate the production byte-cache from demuxer seeks.
    /// Repeat the same reads directly and via the real buffered AVIO.
    /// Compare deterministic URLProtocol and an actual HTTP loopback socket.
    func testG0B03HTTPWindowIsolationObservation() throws {
        let window = 1 << 20
        let cases: [(name: String, size: Int, ops: [(Int, Int)])] = [
            ("tail", 129894, [(0, 1), (128870, 32768), (128870, 32768),
                              (128870, 1024), (129894, 1)]),
            ("crossWindow", 2 * window + 12345,
                [(0, 1), (window - 1024, 32768), (window - 1024, 32768),
                 (window, 32768), (2 * window + 12345, 1)]),
            ("alternate", 2 * window + 12345,
                [(0, 1), (window + 64, 4096), (64, 4096),
                 (window + 64, 4096), (window + 64, 4096)])
        ]
        var attempted = 0
        var exact = 0
        var errors = 0
        for item in cases {
            let payload = Data((0..<item.size).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8)) })
            for socket in [false, true] {
                for avio in [false, true] {
                    attempted += 1
                    let endpoint = G0R15URLProtocol.state
                    endpoint.configure(payload: payload, range: true)
                    let label = "scenario=\(item.name) endpoint=\(socket ? "loopback" : "mock") "
                        + "layer=\(avio ? "avio" : "stream") fileBytes=\(item.size)"
                    do {
                        let server = socket ? try G0R15LoopbackServer(endpoint: endpoint) : nil
                        defer { server?.stop() }
                        let config = URLSessionConfiguration.ephemeral
                        if !socket { config.protocolClasses = [G0R15URLProtocol.self] }
                        let url = server?.url ?? URL(string: "https://g0-r15.invalid/window")!
                        let stream = HTTPStream(url: url, headers: [:], configuration: config)
                        let transport = avio ? HTTPTransport(stream: stream) : nil
                        defer { transport?.close() }
                        if avio && transport?.context == nil { throw MatrixError.invalidFixture }
                        var correct = true
                        for (index, op) in item.ops.enumerated() {
                            let (offset, count) = op
                            let before = endpoint.snapshot()
                            let started = DispatchTime.now().uptimeNanoseconds
                            let seek: Int64
                            if let context = transport?.context {
                                seek = avio_seek(context, Int64(offset), 0)
                            } else {
                                seek = stream.seek(offset: Int64(offset), whence: 0)
                            }
                            let afterSeek = endpoint.snapshot()
                            var output = [UInt8](repeating: 0, count: count)
                            let read: Int
                            if seek != Int64(offset) {
                                read = -1
                            } else if let context = transport?.context {
                                read = output.withUnsafeMutableBufferPointer {
                                    Int(avio_read(context, $0.baseAddress!, Int32(count)))
                                }
                            } else {
                                read = output.withUnsafeMutableBufferPointer {
                                    stream.read(into: $0.baseAddress!, count: count)
                                }
                            }
                            let after = endpoint.snapshot()
                            let expected = min(count, item.size - offset)
                            let eof = expected == 0 && (avio ? read == -541_478_725 : read == 0)
                            let bytesExact = expected > 0 && read == expected
                                && output.prefix(expected).elementsEqual(payload[offset..<(offset + expected)])
                            let valid = seek == Int64(offset) && (eof || bytesExact) && !stream.hasError
                            correct = correct && valid
                            let newEvents = Array(after.dropFirst(before.count))
                            let body = newEvents.reduce(0) { $0 + $1.bytes }
                            let requestPath = newEvents.map { "\($0.requestStart):\($0.status):\($0.bytes)" }
                                .joined(separator: ",")
                            print(
                                "G0_B03_R15B_WINDOW_OP \(label) op=\(index) offset=\(offset) "
                                    + "requested=\(count) seek=\(seek) read=\(read) expected=\(expected) "
                                    + "seekRequests=\(afterSeek.count - before.count) "
                                    + "readRequests=\(after.count - afterSeek.count) "
                                    + "bodyBytes=\(body) path=\(requestPath.isEmpty ? "none" : requestPath) "
                                    + "hasError=\(stream.hasError) correct=\(valid)"
                            )
                            print("G0_B03_R15B_WINDOW_TIMING \(label) op=\(index) elapsedNS=\(DispatchTime.now().uptimeNanoseconds - started)")
                        }
                        let events = endpoint.snapshot()
                        let total = events.reduce(0) { $0 + $1.bytes }
                        if correct { exact += 1 }
                        print("G0_B03_R15B_WINDOW_CASE \(label) requests=\(events.count) bodyBytes=\(total) correct=\(correct)")
                    } catch {
                        errors += 1
                        print("G0_B03_R15B_WINDOW_CASE \(label) setupError=\(error)")
                    }
                    endpoint.configure(payload: Data(), range: true)
                }
            }
        }
        print("G0_B03_R15B_WINDOW_SUMMARY attempted=\(attempted) exact=\(exact) errors=\(errors)")
        XCTAssertEqual(attempted, 12)
        // Byte correctness and transport failures remain visible observations.
    }

    /// R15B2: use real loopback TCP/HTTP, no URLProtocol interception.
    /// Bounded delay and one transient 503, with native PCM comparison.
    /// No physical network, TLS, renderer, or concurrent close experiment.
    func testG0B03LoopbackRecoveryObservation() throws {
        let inputs: [(tag: String, rate: Int32, samples: Int64, target: Int64)] = [
            ("r13_stereo96_s24_b8192_short", 96000, 24000, 1),
            ("r13_stereo44_s16_b4608_long", 44100, 1323000, 661500)
        ]
        var attempted = 0
        var exact = 0
        var rejected = 0
        var incomplete = 0
        var errors = 0
        for item in inputs {
            let local = try fixture(item.tag, withSeektable: false)
            let data = try Data(contentsOf: local)
            guard data.count <= 8 * 1024 * 1024 else { throw MatrixError.invalidFixture }
            let linear = try nativePCMSequenceR9(
                url: local, targetTick: nil, expectedRate: item.rate, expectedChannels: 2
            )
            let reference = linear.pcm
            guard linear.code == 0, reference.firstTick == 0, reference.endTick == item.samples,
                  reference.stride > 0, reference.data.count == Int(item.samples) * reference.stride
            else { throw MatrixError.invalidFixture }
            for profile in ["range", "full", "rangeDelay503"] {
                attempted += 1
                let range = profile != "full"
                let delayed = profile == "rangeDelay503"
                let label = "tag=\(item.tag) profile=\(profile) targetTick=\(item.target) fileBytes=\(data.count)"
                let endpoint = G0R15URLProtocol.state
                endpoint.configure(payload: data, range: range, failures: delayed ? 1 : 0, failureStatus: 503)
                var anchors: [Int64] = []
                for offset: Int64 in [0, Int64(item.rate) / 8, Int64(item.rate) / 2] {
                    let a = max(0, item.target - offset)
                    if !anchors.contains(a) { anchors.append(a) }
                }
                var codes: [Int32] = []
                var rawEnd: Int64?
                var keptFirst: Int64?
                var keptEnd: Int64?
                var compared = 0
                var mismatches = 0
                var openRequests = -1
                var firstRequests = -1
                var firstNS: UInt64?
                let started = DispatchTime.now().uptimeNanoseconds
                do {
                    let server = try G0R15LoopbackServer(endpoint: endpoint, delayMS: delayed ? 20 : 0)
                    defer { server.stop() }
                    let result = try nativePCMSequenceR9(
                        url: server.url, targetTick: item.target,
                        sessionConfiguration: .ephemeral,
                        onOpened: { openRequests = endpoint.snapshot().count },
                        expectedRate: item.rate, expectedChannels: 2,
                        retryAnchors: Array(anchors.dropFirst()),
                        onSeek: { code, _ in codes.append(code) },
                        onFrame: { frame in
                            var one = NativePCMSequenceR9()
                            try one.append(frame, expectedRate: item.rate, expectedChannels: 2)
                            guard let start = one.firstTick, let end = one.endTick,
                                  end <= item.samples, rawEnd == nil || rawEnd == start,
                                  one.stride == reference.stride, one.sampleFormat == reference.sampleFormat
                            else { throw MatrixError.invalidFixture }
                            rawEnd = end
                            if end <= item.target { return }
                            let kept = max(start, item.target)
                            guard keptEnd == nil || keptEnd == kept
                            else { throw MatrixError.invalidTimestamp }
                            if keptFirst == nil {
                                keptFirst = kept
                                firstRequests = endpoint.snapshot().count
                                firstNS = DispatchTime.now().uptimeNanoseconds - started
                            }
                            keptEnd = end
                            let actual = one.data.dropFirst(Int(kept - start) * one.stride)
                            let a = Int(kept) * reference.stride
                            let b = Int(end) * reference.stride
                            compared += actual.count
                            if !actual.elementsEqual(reference.data[a..<b]) { mismatches += 1 }
                        }
                    )
                    let events = endpoint.snapshot()
                    let success = events.filter { $0.status == (range ? 206 : 200) }
                    let statusesValid = !success.isEmpty
                        && events.count == success.count + (delayed ? 1 : 0)
                        && (!delayed || (events.first?.status == 503 && events.count >= 2
                            && events[0].requestStart == events[1].requestStart))
                        && (range || (events.count == 1 && success.first?.bytes == data.count))
                    let body = events.reduce(0) { $0 + $1.bytes }
                    let complete = result.code == 0 && keptFirst == item.target && keptEnd == item.samples
                        && compared == Int(item.samples - item.target) * reference.stride
                        && mismatches == 0 && statusesValid
                        && !codes.isEmpty && codes.last == result.code
                        && codes.count <= anchors.count && codes.dropLast().allSatisfy { $0 == -1 }
                    if result.code < 0 { rejected += 1 }
                    else if complete { exact += 1 }
                    else { incomplete += 1 }
                    print(
                        "G0_B03_R15B_LOOP_CASE \(label) codes=\(codes.map(String.init).joined(separator: ",")) "
                            + "finalCode=\(result.code) requests=\(events.count) bodyBytes=\(body) "
                            + "openRequests=\(openRequests) firstRequests=\(firstRequests) "
                            + "firstKept=\(keptFirst.map(String.init) ?? "none") "
                            + "keptEnd=\(keptEnd.map(String.init) ?? "none") comparedBytes=\(compared) "
                            + "mismatches=\(mismatches) statusesValid=\(statusesValid) complete=\(complete)"
                    )
                    let path = events.map { "\($0.requestStart):\($0.start):\($0.status):\($0.bytes)" }.joined(separator: ",")
                    print("G0_B03_R15B_LOOP_REQUESTS \(label) path=\(path)")
                    print("G0_B03_R15B_LOOP_TIMING \(label) firstKeptNS=\(firstNS.map(String.init) ?? "none") totalNS=\(DispatchTime.now().uptimeNanoseconds - started)")
                } catch {
                    errors += 1
                    print("G0_B03_R15B_LOOP_CASE \(label) setupOrDecodeError=\(error) requests=\(endpoint.snapshot().count)")
                }
                endpoint.configure(payload: Data(), range: true)
            }
        }
        print("G0_B03_R15B_LOOP_SUMMARY attempted=\(attempted) exact=\(exact) rejected=\(rejected) incomplete=\(incomplete) errors=\(errors)")
        XCTAssertEqual(attempted, 6)
        XCTAssertEqual(exact + rejected + incomplete + errors, attempted)
    }

    /// R15C: observe cancellation and terminal states over actual loopback
    /// HTTP. Every AVIO context is created, read and freed on its own serial
    /// worker. The control thread may cancel the live token, never AVIO.
    /// A queued marker models the finite worker's control-queue dependency;
    /// it is NOT a measurement of the actual host Stop/Next UI.
    func testG0B03TransportCancellationObservation() throws {
        let payload = Data([11, 22, 33, 44, 55, 66, 77, 88])
        let scenarios = ["finiteDelayed", "finiteEOF", "finite403",
                         "liveCancel", "livePreCancel", "liveEnd"]
        var attempted = 0
        var correct = 0
        var errors = 0
        for name in scenarios {
            attempted += 1
            let live = name.hasPrefix("live")
            let delayed = name == "finiteDelayed" || name == "liveCancel"
            let preCancelled = name == "livePreCancel"
            let endpoint = G0R15EndpointState()
            endpoint.configure(payload: payload, range: !live,
                               failures: name == "finite403" ? 1 : 0, failureStatus: 403)
            do {
                let server = try G0R15LoopbackServer(endpoint: endpoint, delayMS: delayed ? 1500 : 0)
                defer { server.stop() }
                let token = LiveStreamCancellation()
                if preCancelled { token.cancel() }
                let worker = DispatchQueue(label: "apolo.g0.r15c.worker")
                let result = G0R15CResult()
                let done = DispatchSemaphore(value: 0)
                let marker = DispatchSemaphore(value: 0)
                let url = server.url
                worker.async {
                    defer { done.signal() }
                    // Keep server alive even if a diagnostic wait times out.
                    defer { withExtendedLifetime(server) {} }
                    let config = URLSessionConfiguration.ephemeral
                    let transport: any AudioTransport
                    let failed: () -> Bool
                    if live {
                        let stream = LiveHTTPStream(url: url, headers: [:], configuration: config)
                        token.register(stream)
                        guard let opened = LiveHTTPTransport(stream: stream) else { return }
                        transport = opened
                        failed = { stream.hasError }
                    } else {
                        let stream = HTTPStream(url: url, headers: [:], configuration: config)
                        guard let opened = HTTPTransport(stream: stream) else { return }
                        transport = opened
                        failed = { stream.hasError }
                    }
                    // Only this worker owns the FFmpeg pointer.
                    defer { transport.close() }
                    guard let context = transport.context else { return }
                    var buffer = [UInt8](repeating: 0, count: payload.count)
                    let first = buffer.withUnsafeMutableBufferPointer {
                        avio_read(context, $0.baseAddress!, Int32(payload.count))
                    }
                    var byte: UInt8 = 0
                    let next = avio_read(context, &byte, 1)
                    result.store(.init(first: first, next: next, hasError: failed(),
                                       bytesExact: Data(buffer) == payload,
                                       finishedNS: DispatchTime.now().uptimeNanoseconds))
                }

                var requestSeen = false
                var pendingAt200ms: Bool?
                var markerNS: UInt64?
                var commandNS: UInt64?
                if delayed {
                    // Server records the request BEFORE scheduling its delayed
                    // response. No arbitrary sleep to guess read entry.
                    let deadline = DispatchTime.now() + .seconds(4)
                    while endpoint.snapshot().isEmpty && DispatchTime.now() < deadline {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    requestSeen = !endpoint.snapshot().isEmpty
                    let issued = DispatchTime.now().uptimeNanoseconds
                    commandNS = issued
                    if live {
                        token.cancel()
                    } else {
                        worker.async { marker.signal() }
                        let early = marker.wait(timeout: .now() + .milliseconds(200)) == .success
                        pendingAt200ms = !early
                        if early || marker.wait(timeout: .now() + .seconds(8)) == .success {
                            markerNS = DispatchTime.now().uptimeNanoseconds - issued
                        }
                    }
                }
                let completed = done.wait(timeout: .now() + .seconds(8)) == .success
                guard completed, let value = result.snapshot() else {
                    // No cross-thread free; worker retains its own resources.
                    token.cancel()
                    errors += 1
                    print("G0_B03_R15C_CASE scenario=\(name) setupOrWaitError=true requests=\(endpoint.snapshot().count)")
                    continue
                }
                let events = endpoint.snapshot()
                let expectedEOF: Int32 = -541_478_725
                let valid: Bool
                switch name {
                case "finiteDelayed":
                    valid = requestSeen && pendingAt200ms == true && markerNS != nil
                        && events.count == 1 && events.first?.status == 206
                        && value.first == 8 && value.next == expectedEOF
                        && value.bytesExact && !value.hasError
                case "finiteEOF":
                    valid = events.count == 1 && events.first?.status == 206
                        && value.first == 8 && value.next == expectedEOF
                        && value.bytesExact && !value.hasError
                case "finite403":
                    valid = events.count == 1 && events.first?.status == 403
                        && value.first == -5 && value.next == -5 && value.hasError
                case "liveCancel":
                    valid = requestSeen && events.count == 1 && events.first?.status == 200
                        && value.first == -5 && value.next == -5 && !value.hasError
                case "livePreCancel":
                    valid = events.isEmpty && value.first == -5 && value.next == -5 && !value.hasError
                case "liveEnd":
                    valid = events.count == 1 && events.first?.status == 200
                        && value.first == 8 && value.next == -5
                        && value.bytesExact && value.hasError
                default:
                    valid = false
                }
                if valid { correct += 1 }
                let pending = pendingAt200ms.map { String($0) } ?? "none"
                let statuses = events.map { String($0.status) }.joined(separator: ",")
                print(
                    "G0_B03_R15C_CASE scenario=\(name) requests=\(events.count) "
                        + "statuses=\(statuses.isEmpty ? "none" : statuses) "
                        + "first=\(value.first) next=\(value.next) bytesExact=\(value.bytesExact) "
                        + "hasError=\(value.hasError) requestSeen=\(requestSeen) "
                        + "markerPending200ms=\(pending) correct=\(valid)"
                )
                if let commandNS {
                    let elapsed = value.finishedNS >= commandNS ? value.finishedNS - commandNS : 0
                    print("G0_B03_R15C_TIMING scenario=\(name) readFinishedAfterCommandNS=\(elapsed) markerAfterCommandNS=\(markerNS.map(String.init) ?? "none")")
                }
            } catch {
                errors += 1
                print("G0_B03_R15C_CASE scenario=\(name) setupError=\(error)")
            }
        }
        // This checks only the real epoch predicate, not host/renderer/UI.
        let staleRejected = !ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: 7, engineEpoch: 8, route: .libavcodec)
        let currentAccepted = ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: 8, engineEpoch: 8, route: .libavcodec)
        let nativeRejected = !ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: 8, engineEpoch: 8, route: .avPlayer)
        print("G0_B03_R15C_EPOCH staleRejected=\(staleRejected) currentAccepted=\(currentAccepted) nativeRejected=\(nativeRejected)")
        print("G0_B03_R15C_SUMMARY attempted=\(attempted) correct=\(correct) errors=\(errors)")
        XCTAssertEqual(attempted, 6)
        XCTAssertEqual(errors, 0)
        XCTAssertTrue(staleRejected && currentAccepted && nativeRejected)
        // Classify unexpected terminal behavior as evidence, not a fix.
    }

    // R16A: fixed, alternating local/loopback lifecycle workload. This
    // is process-level simulator telemetry, not isolated codec or device
    // energy measurement. Every cycle owns and closes its own contexts.
    private struct ResourceSnapshotR16 {
        let cpuUS: Int64?
        let residentBytes: UInt64?
        let maxRSS: Int64?
    }

    private func resourceSnapshotR16() -> ResourceSnapshotR16 {
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = Int64(usage.ru_utime.tv_sec) * 1_000_000
            + Int64(usage.ru_utime.tv_usec)
            + Int64(usage.ru_stime.tv_sec) * 1_000_000
            + Int64(usage.ru_stime.tv_usec)
        var basic = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ResourceSnapshotR16(
            cpuUS: usageOK ? cpu : nil,
            residentBytes: status == KERN_SUCCESS ? UInt64(basic.resident_size) : nil,
            maxRSS: usageOK ? Int64(usage.ru_maxrss) : nil
        )
    }

    func testG0B03RepeatedLifecycleResourceObservation() throws {
        let local = try fixture("025", withSeektable: false)
        let payload = try Data(contentsOf: local)
        let rate: Int32 = 44100
        let total: Int64 = 11025
        let linear = try nativePCMSequenceR9(url: local, targetTick: nil)
        let reference = linear.pcm
        guard linear.code == 0, reference.firstTick == 0,
              reference.endTick == total, reference.stride == 4,
              reference.data.count == Int(total) * reference.stride,
              payload.count <= 8 * 1024 * 1024
        else { throw MatrixError.invalidFixture }

        let endpoint = G0R15EndpointState()
        endpoint.configure(payload: payload, range: true)
        let server = try G0R15LoopbackServer(endpoint: endpoint)
        defer { server.stop() }
        let targets: [Int64] = [0, 2756, 5512, 9922]
        let profiles = ["local", "loopback206"]
        var totals: [String: [UInt64]] = [:]
        var opens: [String: [UInt64]] = [:]
        var firsts: [String: [UInt64]] = [:]
        var cpuDeltas: [String: [UInt64]] = [:]
        var exact = 0
        var errors = 0
        var warmExact = 0
        var measured = 0
        var resourceMissing = 0

        func percentile(_ values: [UInt64], _ p: Double) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "none" }
            let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))
            return String(sorted[index])
        }
        func emitResources(_ phase: String, _ snapshot: ResourceSnapshotR16) {
            print("G0_B03_R16A_RESOURCE phase=\(phase) cpuUS=\(snapshot.cpuUS.map(String.init) ?? "none") residentBytes=\(snapshot.residentBytes.map(String.init) ?? "none") maxRSSDarwin=\(snapshot.maxRSS.map(String.init) ?? "none")")
        }

        emitResources("beforeWarmup", resourceSnapshotR16())
        // Two warmups per transport; alternate AB/BA order in each pair.
        // Five measured repetitions of each of four fixed targets.
        for pair in 0..<22 {
            let warmup = pair < 2
            if pair == 2 { emitResources("afterWarmup", resourceSnapshotR16()) }
            let target = targets[(warmup ? pair : pair - 2) % targets.count]
            let order = pair.isMultiple(of: 2) ? profiles : Array(profiles.reversed())
            for profile in order {
                let remote = profile == "loopback206"
                endpoint.configure(payload: payload, range: true)
                let url = remote ? server.url : local
                let phase = warmup ? "warmup" : "measured"
                let label = "phase=\(phase) pair=\(pair) profile=\(profile) target=\(target)"
                var anchors: [Int64] = []
                for offset: Int64 in [0, Int64(rate) / 8, Int64(rate) / 2] {
                    let anchor = max(0, target - offset)
                    if !anchors.contains(anchor) { anchors.append(anchor) }
                }
                var codes: [Int32] = []
                var rawEnd: Int64?
                var first: Int64?
                var endKept: Int64?
                var compared = 0
                var mismatch = 0
                var openNS: UInt64?
                var firstNS: UInt64?
                var seekNS: UInt64 = 0
                let before = resourceSnapshotR16()
                let started = DispatchTime.now().uptimeNanoseconds
                if !warmup { measured += 1 }
                do {
                    let code: Int32 = try autoreleasepool {
                        try self.nativePCMSequenceR9(
                            url: url, targetTick: target,
                            sessionConfiguration: .ephemeral,
                            onOpened: { openNS = DispatchTime.now().uptimeNanoseconds - started },
                            retryAnchors: Array(anchors.dropFirst()),
                            onSeek: { code, elapsed in codes.append(code); seekNS += elapsed },
                            onFrame: { frame in
                                var one = NativePCMSequenceR9()
                                try one.append(frame)
                                guard let start = one.firstTick, let end = one.endTick,
                                      end <= total, rawEnd == nil || rawEnd == start,
                                      one.stride == reference.stride,
                                      one.sampleFormat == reference.sampleFormat
                                else { throw MatrixError.invalidFixture }
                                rawEnd = end
                                if end <= target { return }
                                let kept = max(start, target)
                                guard endKept == nil || endKept == kept
                                else { throw MatrixError.invalidTimestamp }
                                if first == nil {
                                    first = kept
                                    firstNS = DispatchTime.now().uptimeNanoseconds - started
                                }
                                endKept = end
                                let bytes = one.data.dropFirst(Int(kept - start) * one.stride)
                                let a = Int(kept) * reference.stride
                                let b = Int(end) * reference.stride
                                compared += bytes.count
                                if !bytes.elementsEqual(reference.data[a..<b]) { mismatch += 1 }
                            }
                        ).code
                    }
                    // Includes helper's deferred format/codec/AVIO close,
                    // autoreleasepool drain and PCM comparison, not rendering.
                    let totalNS = DispatchTime.now().uptimeNanoseconds - started
                    let after = resourceSnapshotR16()
                    let events = endpoint.snapshot()
                    let body = events.reduce(0) { $0 + $1.bytes }
                    let transportOK = remote
                        ? !events.isEmpty && events.allSatisfy { $0.status == 206 }
                        : events.isEmpty
                    let complete = code == 0 && first == target && endKept == total
                        && compared == Int(total - target) * reference.stride
                        && mismatch == 0 && transportOK && !codes.isEmpty
                        && codes.last == 0 && codes.count <= anchors.count
                        && codes.dropLast().allSatisfy { $0 == -1 }
                    var deltaCPU: UInt64?
                    if let a = before.cpuUS, let b = after.cpuUS, b >= a {
                        deltaCPU = UInt64(b - a)
                    }
                    if !warmup {
                        if complete {
                            exact += 1
                            totals[profile, default: []].append(totalNS)
                            if let openNS { opens[profile, default: []].append(openNS) }
                            if let firstNS { firsts[profile, default: []].append(firstNS) }
                            if let deltaCPU { cpuDeltas[profile, default: []].append(deltaCPU) }
                        }
                        if deltaCPU == nil || before.residentBytes == nil || after.residentBytes == nil {
                            resourceMissing += 1
                        }
                    } else if complete {
                        warmExact += 1
                    }
                    print("G0_B03_R16A_CASE \(label) codes=\(codes.map(String.init).joined(separator: ",")) finalCode=\(code) first=\(first.map(String.init) ?? "none") end=\(endKept.map(String.init) ?? "none") comparedBytes=\(compared) mismatch=\(mismatch) requests=\(events.count) bodyBytes=\(body) complete=\(complete)")
                    print("G0_B03_R16A_TIMING \(label) openNS=\(openNS.map(String.init) ?? "none") seekNS=\(seekNS) firstPCMNS=\(firstNS.map(String.init) ?? "none") totalWithCloseNS=\(totalNS) cpuDeltaUS=\(deltaCPU.map(String.init) ?? "none") residentBefore=\(before.residentBytes.map(String.init) ?? "none") residentAfter=\(after.residentBytes.map(String.init) ?? "none") maxRSSDarwin=\(after.maxRSS.map(String.init) ?? "none")")
                } catch {
                    errors += 1
                    print("G0_B03_R16A_CASE \(label) setupOrDecodeError=\(error)")
                }
            }
        }
        emitResources("afterMeasured", resourceSnapshotR16())
        for profile in profiles {
            let t = totals[profile, default: []]
            let o = opens[profile, default: []]
            let f = firsts[profile, default: []]
            let c = cpuDeltas[profile, default: []]
            print("G0_B03_R16A_METRICS profile=\(profile) totalN=\(t.count) totalP50NS=\(percentile(t, 0.50)) totalP95NS=\(percentile(t, 0.95)) openN=\(o.count) openP50NS=\(percentile(o, 0.50)) openP95NS=\(percentile(o, 0.95)) firstN=\(f.count) firstP50NS=\(percentile(f, 0.50)) firstP95NS=\(percentile(f, 0.95)) cpuN=\(c.count) cpuP50US=\(percentile(c, 0.50)) cpuP95US=\(percentile(c, 0.95))")
        }
        print("G0_B03_R16A_SUMMARY measured=\(measured) exact=\(exact) warmExact=\(warmExact) errors=\(errors) resourceMissing=\(resourceMissing)")
        XCTAssertEqual(measured, 40)
        XCTAssertEqual(warmExact, 4)
        XCTAssertEqual(exact, 40)
        XCTAssertEqual(errors, 0)
        // Resource readings can be unavailable; keep that explicit.
        // No RSS or timing threshold implies a leak or speedup.
    }

    // R16B deliberately keeps one format/codec/AVIO/packet/frame owner
    // alive across alternating seeks after partial decode and drained EOF.
    // No context reopen and no production changes. Verify every requested
    // interval against actual independent linear native PCM.
    func testG0B03RepeatedSeekSameContextObservation() throws {
        let fixtures: [(tag: String, total: Int64)] = [("025", 11025), ("200", 88200)]
        var measured = 0
        var warm = 0
        var exact = 0
        var warmExact = 0
        var errors = 0
        var rejected = 0
        var incomplete = 0
        var contexts = 0
        var resourceMissing = 0

        func percentile(_ values: [UInt64], _ p: Double) -> String {
            let ordered = values.sorted()
            guard !ordered.isEmpty else { return "none" }
            return String(ordered[max(0, min(ordered.count - 1,
                Int(ceil(Double(ordered.count) * p)) - 1))])
        }

        for item in fixtures {
            let local = try fixture(item.tag, withSeektable: false)
            let payload = try Data(contentsOf: local)
            let linear = try nativePCMSequenceR9(url: local, targetTick: nil)
            let reference = linear.pcm
            guard linear.code == 0, reference.firstTick == 0,
                  reference.endTick == item.total, reference.stride == 4,
                  reference.data.count == Int(item.total) * reference.stride,
                  payload.count <= 8 * 1024 * 1024
            else { throw MatrixError.invalidFixture }

            // Explicitly alternate direction and repeated targets, frame
            // boundaries, EOF, last sample and recovery after partial reads.
            let operations: [(Int64, Bool)] = [
                (0, false), (item.total * 9 / 10, true),
                (1, false), (item.total, true),
                (item.total - 1, true), (4608, false),
                (4607, false), (4607, true)
            ]
            for profile in ["local", "loopback206"] {
                let remote = profile == "loopback206"
                let endpoint = G0R15EndpointState()
                endpoint.configure(payload: payload, range: true)
                let server = try G0R15LoopbackServer(endpoint: endpoint)
                defer { server.stop() }
                let url = remote ? server.url : local
                let label = "tag=\(item.tag) profile=\(profile)"
                let beforeOpen = resourceSnapshotR16()
                let openStarted = DispatchTime.now().uptimeNanoseconds
                var times: [UInt64] = []
                var firstTimes: [UInt64] = []
                var seekTimes: [UInt64] = []
                var cpuTimes: [UInt64] = []
                var profileExact = 0
                var profileWarm = 0

                // The helper's scope guarantees reverse-order release;
                // the transport remains alive until after format close.
                func runContext() throws {
                    let source = try OpenedSource.open(url: url, sessionConfiguration: .ephemeral)
                    defer { source.close() }
                    var ownedFormat = source.takeFormatContext()
                    defer { avformat_close_input(&ownedFormat) }
                    guard let context = ownedFormat,
                          context.pointee.nb_streams == 1,
                          let stream = context.pointee.streams[0],
                          stream.pointee.time_base.num == 1,
                          stream.pointee.time_base.den == 44100,
                          let parameters = stream.pointee.codecpar,
                          parameters.pointee.codec_id == AV_CODEC_ID_FLAC,
                          parameters.pointee.sample_rate == 44100,
                          parameters.pointee.ch_layout.nb_channels == 2,
                          let codec = avcodec_find_decoder(parameters.pointee.codec_id),
                          let decoder = avcodec_alloc_context3(codec)
                    else { throw MatrixError.missingStream }
                    var ownedDecoder: UnsafeMutablePointer<AVCodecContext>? = decoder
                    defer { avcodec_free_context(&ownedDecoder) }
                    guard avcodec_parameters_to_context(decoder, parameters) >= 0,
                          avcodec_open2(decoder, codec, nil) >= 0
                    else { throw MatrixError.invalidFixture }
                    var ownedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
                    var ownedFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
                    defer {
                        av_frame_free(&ownedFrame)
                        av_packet_free(&ownedPacket)
                    }
                    guard let packet = ownedPacket, let frame = ownedFrame
                    else { throw MatrixError.missingPacket }
                    contexts += 1
                    let eof: Int32 = -541_478_725
                    let again = -Int32(EAGAIN)

                    // Drain after every packet. Partial operation stops
                    // reading packets only after draining available frames.
                    func drain(_ observe: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws -> Int32 {
                        for _ in 0..<2048 {
                            let rc = avcodec_receive_frame(decoder, frame)
                            if rc == again || rc == eof { return rc }
                            guard rc >= 0 else { throw MatrixError.invalidFixture }
                            defer { av_frame_unref(frame) }
                            try observe(frame)
                        }
                        throw MatrixError.invalidFixture
                    }
                    var primed = false
                    for _ in 0..<512 {
                        guard av_read_frame(context, packet) >= 0
                        else { throw MatrixError.missingPCM }
                        defer { av_packet_unref(packet) }
                        guard packet.pointee.stream_index == 0 else { continue }
                        guard avcodec_send_packet(decoder, packet) >= 0
                        else { throw MatrixError.invalidFixture }
                        _ = try drain { _ in primed = true }
                        if primed { break }
                    }
                    guard primed else { throw MatrixError.missingPCM }
                    print("G0_B03_R16B_OPEN \(label) openPrimeNS=\(DispatchTime.now().uptimeNanoseconds - openStarted) requests=\(endpoint.snapshot().count)")

                    var prior = "primed"
                    for index in 0..<24 {
                        let warmup = index < 4
                        let op = operations[index % operations.count]
                        let target = op.0
                        let full = op.1
                        let expectedEnd = full ? item.total : min(item.total, target + 256)
                        let caseLabel = "\(label) index=\(index) phase=\(warmup ? "warmup" : "measured") prior=\(prior) target=\(target) mode=\(full ? "eof" : "partial")"
                        if warmup { warm += 1 } else { measured += 1 }
                        let before = resourceSnapshotR16()
                        let requestBefore = endpoint.snapshot().count
                        let started = DispatchTime.now().uptimeNanoseconds
                        var anchors: [Int64] = []
                        for offset: Int64 in [0, 5512, 22050] {
                            let a = max(0, target - offset)
                            if !anchors.contains(a) { anchors.append(a) }
                        }
                        var codes: [Int32] = []
                        var seekNS: UInt64 = 0
                        var code: Int32 = -1
                        var rawFirst: Int64?
                        var rawEnd: Int64?
                        var first: Int64?
                        var keptEnd: Int64?
                        var firstNS: UInt64?
                        var compared = 0
                        var mismatches = 0
                        var packets = 0
                        var payloadBytes = 0
                        var terminal = false
                        do {
                            try autoreleasepool {
                                for anchor in anchors {
                                    let seekStart = DispatchTime.now().uptimeNanoseconds
                                    code = avformat_seek_file(context, 0, Int64.min, anchor,
                                        Int64.max, AVSEEK_FLAG_BACKWARD)
                                    seekNS += DispatchTime.now().uptimeNanoseconds - seekStart
                                    codes.append(code)
                                    if code != -1 { break }
                                }
                                guard code >= 0 else { return }
                                avformat_flush(context)
                                avcodec_flush_buffers(decoder)

                                func observe(_ frame: UnsafeMutablePointer<AVFrame>) throws {
                                    var one = NativePCMSequenceR9()
                                    try one.append(frame)
                                    guard let start = one.firstTick, let end = one.endTick,
                                          end <= item.total, rawEnd == nil || rawEnd == start,
                                          one.stride == reference.stride,
                                          one.sampleFormat == reference.sampleFormat
                                    else { throw MatrixError.invalidFixture }
                                    if rawFirst == nil { rawFirst = start }
                                    rawEnd = end
                                    let a = max(start, target)
                                    let b = min(end, expectedEnd)
                                    if b <= a { return }
                                    guard keptEnd == nil || keptEnd == a
                                    else { throw MatrixError.invalidTimestamp }
                                    if first == nil {
                                        first = a
                                        firstNS = DispatchTime.now().uptimeNanoseconds - started
                                    }
                                    keptEnd = b
                                    let actual = one.data[(Int(a - start) * one.stride)..<(Int(b - start) * one.stride)]
                                    let expected = reference.data[(Int(a) * one.stride)..<(Int(b) * one.stride)]
                                    compared += actual.count
                                    if !actual.elementsEqual(expected) { mismatches += 1 }
                                }

                                for _ in 0..<2048 {
                                    if !full && keptEnd == expectedEnd { break }
                                    let rc = av_read_frame(context, packet)
                                    if rc == eof {
                                        let sent = avcodec_send_packet(decoder, nil)
                                        guard sent >= 0 || sent == eof,
                                              try drain(observe) == eof
                                        else { throw MatrixError.invalidFixture }
                                        terminal = true
                                        break
                                    }
                                    guard rc >= 0 else { throw MatrixError.invalidFixture }
                                    defer { av_packet_unref(packet) }
                                    guard packet.pointee.stream_index == 0 else { continue }
                                    packets += 1
                                    payloadBytes += Int(packet.pointee.size)
                                    guard avcodec_send_packet(decoder, packet) >= 0
                                    else { throw MatrixError.invalidFixture }
                                    _ = try drain(observe)
                                }
                            }
                            let elapsed = DispatchTime.now().uptimeNanoseconds - started
                            let after = resourceSnapshotR16()
                            let newEvents = endpoint.snapshot().dropFirst(requestBefore)
                            let transportOK = remote
                                ? newEvents.allSatisfy { $0.status == 206 }
                                : newEvents.isEmpty
                            let bytes = newEvents.reduce(0) { $0 + $1.bytes }
                            let emptyEOF = target == item.total && terminal
                                && rawFirst != nil && rawEnd == item.total
                                && first == nil && keptEnd == nil && compared == 0
                            let coverage = target < item.total && first == target
                                && keptEnd == expectedEnd
                                && compared == Int(expectedEnd - target) * reference.stride
                            let complete = code == 0 && (emptyEOF || coverage)
                                && mismatches == 0 && transportOK
                                && (!full || (terminal && rawEnd == item.total))
                                && !codes.isEmpty && codes.last == 0
                                && codes.count <= anchors.count && codes.dropLast().allSatisfy { $0 == -1 }
                            var deltaCPU: UInt64?
                            if let a = before.cpuUS, let b = after.cpuUS, b >= a { deltaCPU = UInt64(b - a) }
                            if complete {
                                if warmup { warmExact += 1; profileWarm += 1 }
                                else {
                                    exact += 1; profileExact += 1
                                    times.append(elapsed); seekTimes.append(seekNS)
                                    if let firstNS { firstTimes.append(firstNS) }
                                    if let deltaCPU { cpuTimes.append(deltaCPU) }
                                }
                            } else if code < 0 { rejected += 1 }
                            else { incomplete += 1 }
                            if !warmup && (deltaCPU == nil || before.residentBytes == nil || after.residentBytes == nil) {
                                resourceMissing += 1
                            }
                            print("G0_B03_R16B_CASE \(caseLabel) codes=\(codes.map(String.init).joined(separator: ",")) finalCode=\(code) first=\(first.map(String.init) ?? "none") keptEnd=\(keptEnd.map(String.init) ?? "none") rawEnd=\(rawEnd.map(String.init) ?? "none") terminal=\(terminal) comparedBytes=\(compared) mismatches=\(mismatches) packets=\(packets) payloadBytes=\(payloadBytes) requests=\(newEvents.count) bodyBytes=\(bytes) complete=\(complete)")
                            print("G0_B03_R16B_TIMING \(caseLabel) seekNS=\(seekNS) firstPCMNS=\(firstNS.map(String.init) ?? "none") totalNS=\(elapsed) cpuUS=\(deltaCPU.map(String.init) ?? "none") residentBefore=\(before.residentBytes.map(String.init) ?? "none") residentAfter=\(after.residentBytes.map(String.init) ?? "none")")
                            prior = code < 0 ? "rejected" : (terminal ? "drainedEOF" : "partial")
                        } catch {
                            errors += 1
                            print("G0_B03_R16B_CASE \(caseLabel) setupOrDecodeError=\(error)")
                            // Unexpected decoder errors leave state unknown;
                            // end this owner safely rather than hiding it.
                            break
                        }
                    }
                    print("G0_B03_R16B_PRECLOSE \(label) residentBytes=\(resourceSnapshotR16().residentBytes.map(String.init) ?? "none")")
                }

                do {
                    try runContext()
                } catch {
                    errors += 1
                    print("G0_B03_R16B_CONTEXT \(label) setupError=\(error)")
                }
                let afterClose = resourceSnapshotR16()
                let allEvents = endpoint.snapshot()
                print("G0_B03_R16B_PROFILE \(label) measuredExact=\(profileExact) warmExact=\(profileWarm) requests=\(allEvents.count) bodyBytes=\(allEvents.reduce(0) { $0 + $1.bytes }) residentBeforeOpen=\(beforeOpen.residentBytes.map(String.init) ?? "none") residentAfterClose=\(afterClose.residentBytes.map(String.init) ?? "none") maxRSSDarwin=\(afterClose.maxRSS.map(String.init) ?? "none") totalN=\(times.count) totalP50NS=\(percentile(times, 0.50)) totalP95NS=\(percentile(times, 0.95)) seekN=\(seekTimes.count) seekP50NS=\(percentile(seekTimes, 0.50)) seekP95NS=\(percentile(seekTimes, 0.95)) firstN=\(firstTimes.count) firstP50NS=\(percentile(firstTimes, 0.50)) firstP95NS=\(percentile(firstTimes, 0.95)) cpuN=\(cpuTimes.count) cpuP50US=\(percentile(cpuTimes, 0.50)) cpuP95US=\(percentile(cpuTimes, 0.95))")
            }
        }
        print("G0_B03_R16B_SUMMARY contexts=\(contexts) measured=\(measured) exact=\(exact) warm=\(warm) warmExact=\(warmExact) rejected=\(rejected) incomplete=\(incomplete) errors=\(errors) resourceMissing=\(resourceMissing)")
        XCTAssertEqual(contexts, 4)
        XCTAssertEqual(measured, 80)
        XCTAssertEqual(warm, 16)
        XCTAssertEqual(exact, 80)
        XCTAssertEqual(warmExact, 16)
        XCTAssertEqual(rejected + incomplete + errors, 0)
        // No performance or RSS threshold; no device or leak certification.
    }

    // R16C: isolated owner per worker, distinct fixture shapes and HTTP
    // endpoints. Serial control and concurrent waves use identical inputs.
    // The open barrier proves overlapping source lifetimes, not CPU-core
    // parallelism. No XCTest instance or AV* pointer crosses worker queues.
    private struct R16CInput: Sendable {
        let id: String
        let url: URL
        let payload: Data
        let rate: Int32
        let channels: Int
        let total: Int64
        let target: Int64
        let stride: Int
        let sampleFormat: Int32
        let reference: Data
        let remote: Bool
        let retry503: Bool
    }

    private struct R16CResult: Sendable {
        let id: String
        let openedNS: UInt64?
        let closedNS: UInt64
        let startedNS: UInt64
        let barrierOK: Bool
        let complete: Bool
        let requests: Int
        let bodyBytes: Int
        let codes: [Int32]
        let compared: Int
        let mismatches: Int
        let statuses: [Int]
        let first: Int64?
        let end: Int64?
        let firstNS: UInt64?
        let error: String?
    }

    private final class R16CResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [R16CResult] = []
        func append(_ value: R16CResult) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }
        func snapshot() -> [R16CResult] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private static func runR16CWorker(_ input: R16CInput, gate: DispatchGroup?) -> R16CResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var opened: UInt64?
        var released = false
        var barrierOK = gate == nil
        defer {
            if !released { gate?.leave() }
        }
        let endpoint = G0R15EndpointState()
        var codes: [Int32] = []
        var compared = 0
        var mismatches = 0
        var first: Int64?
        var end: Int64?
        var rawEnd: Int64?
        var firstNS: UInt64?
        var complete = false
        var failure: String?
        do {
            try autoreleasepool {
                var server: G0R15LoopbackServer?
                if input.remote {
                    endpoint.configure(payload: input.payload, range: true,
                        failures: input.retry503 ? 1 : 0, failureStatus: 503)
                    server = try G0R15LoopbackServer(endpoint: endpoint, delayMS: 5)
                }
                defer { server?.stop() }
                var anchors: [Int64] = []
                for offset: Int64 in [0, Int64(input.rate) / 8, Int64(input.rate) / 2] {
                    let a = max(0, input.target - offset)
                    if !anchors.contains(a) { anchors.append(a) }
                }
                let result = try nativePCMSequenceR9Worker(
                    url: server?.url ?? input.url, targetTick: input.target,
                    sessionConfiguration: .ephemeral,
                    onOpened: {
                        opened = DispatchTime.now().uptimeNanoseconds
                        if let gate {
                            released = true
                            gate.leave()
                            barrierOK = gate.wait(timeout: .now() + 10) == .success
                        }
                    },
                    expectedRate: input.rate, expectedChannels: input.channels,
                    retryAnchors: Array(anchors.dropFirst()),
                    onSeek: { code, _ in codes.append(code) },
                    onFrame: { frame in
                        var one = NativePCMSequenceR9()
                        try one.append(frame, expectedRate: input.rate,
                            expectedChannels: input.channels)
                        guard let a = one.firstTick, let b = one.endTick,
                              b <= input.total, rawEnd == nil || rawEnd == a,
                              one.stride == input.stride,
                              one.sampleFormat == input.sampleFormat
                        else { throw MatrixError.invalidFixture }
                        rawEnd = b
                        if b <= input.target { return }
                        let kept = max(a, input.target)
                        guard end == nil || end == kept
                        else { throw MatrixError.invalidTimestamp }
                        if first == nil {
                            first = kept
                            firstNS = DispatchTime.now().uptimeNanoseconds - started
                        }
                        end = b
                        let actual = one.data.dropFirst(Int(kept - a) * input.stride)
                        let expected = input.reference[(Int(kept) * input.stride)..<(Int(b) * input.stride)]
                        compared += actual.count
                        if !actual.elementsEqual(expected) { mismatches += 1 }
                    }
                )
                let events = endpoint.snapshot()
                let statuses = events.map { $0.status }
                let transportOK: Bool
                if !input.remote {
                    transportOK = events.isEmpty
                } else if input.retry503 {
                    transportOK = events.count >= 2 && statuses.first == 503
                        && events[0].requestStart == events[1].requestStart
                        && statuses.dropFirst().allSatisfy { $0 == 206 }
                } else {
                    transportOK = !events.isEmpty && statuses.allSatisfy { $0 == 206 }
                }
                complete = result.code == 0 && barrierOK && opened != nil
                    && first == input.target && end == input.total && rawEnd == input.total
                    && compared == Int(input.total - input.target) * input.stride
                    && mismatches == 0 && transportOK && !codes.isEmpty
                    && codes.last == 0 && codes.count <= anchors.count
                    && codes.dropLast().allSatisfy { $0 == -1 }
            }
        } catch {
            failure = String(describing: error)
        }
        let events = endpoint.snapshot()
        return R16CResult(id: input.id, openedNS: opened,
            closedNS: DispatchTime.now().uptimeNanoseconds, startedNS: started,
            barrierOK: barrierOK, complete: complete, requests: events.count,
            bodyBytes: events.reduce(0) { $0 + $1.bytes }, codes: codes,
            compared: compared, mismatches: mismatches, statuses: events.map { $0.status },
            first: first, end: end, firstNS: firstNS, error: failure)
    }

    func testG0B03ConcurrentOwnerIsolationObservation() throws {
        let specs: [(String, String, Int32, Int, Int64, Int64, Bool, Bool)] = [
            ("local44", "025", 44100, 2, 11025, 2756, false, false),
            ("localSurround48", "r13_surround48_s24_b4096", 48000, 6, 72000, 36000, false, false),
            ("http96", "r13_stereo96_s24_b8192_short", 96000, 2, 24000, 1, true, true),
            ("http44", "200", 44100, 2, 88200, 78336, true, false)
        ]
        var inputs: [R16CInput] = []
        for (id, tag, rate, channels, total, target, remote, retry) in specs {
            let local = try fixture(tag, withSeektable: false)
            let payload = try Data(contentsOf: local)
            let linear = try nativePCMSequenceR9(url: local, targetTick: nil,
                expectedRate: rate, expectedChannels: channels)
            let ref = linear.pcm
            guard linear.code == 0, ref.firstTick == 0, ref.endTick == total,
                  ref.channels == channels, ref.stride > 0,
                  ref.data.count == Int(total) * ref.stride,
                  let format = ref.sampleFormat,
                  !payload.isEmpty, payload.count <= 8 * 1024 * 1024
            else { throw MatrixError.invalidFixture }
            inputs.append(R16CInput(id: id, url: local, payload: payload,
                rate: rate, channels: channels, total: total, target: target,
                stride: ref.stride, sampleFormat: format, reference: ref.data,
                remote: remote, retry503: retry))
        }
        var attempted = 0
        var exact = 0
        var serialExact = 0
        var concurrentExact = 0
        var overlapWaves = 0
        var errors = 0
        var resourceMissing = 0

        for wave in 0..<5 {
            let concurrent = wave != 0
            let before = resourceSnapshotR16()
            let waveStarted = DispatchTime.now().uptimeNanoseconds
            let collector = R16CResults()
            if concurrent {
                let gate = DispatchGroup()
                let finished = DispatchGroup()
                for _ in inputs { gate.enter() }
                for input in inputs {
                    let queue = DispatchQueue(label: "apolo.g0.r16c.\(wave).\(input.id)")
                    queue.async(group: finished) {
                        collector.append(Self.runR16CWorker(input, gate: gate))
                    }
                }
                // Workers retain their own endpoints and contexts until they
                // finish. Never force-free a timed-out worker's resources.
                guard finished.wait(timeout: .now() + 60) == .success else {
                    XCTFail("R16C owner wave timed out; no cross-thread free")
                    return
                }
            } else {
                for input in inputs {
                    collector.append(Self.runR16CWorker(input, gate: nil))
                }
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - waveStarted
            let after = resourceSnapshotR16()
            let results = collector.snapshot().sorted { $0.id < $1.id }
            let opened = results.compactMap { $0.openedNS }
            let latestOpen = opened.max()
            let earliestClose = results.map { $0.closedNS }.min()
            var overlap: UInt64 = 0
            if opened.count == inputs.count, let a = latestOpen, let b = earliestClose, b > a {
                overlap = b - a
            }
            let overlapOK = concurrent ? overlap > 0 : overlap == 0
            if concurrent && overlapOK { overlapWaves += 1 }
            var waveExact = 0
            for result in results {
                attempted += 1
                if result.complete {
                    exact += 1; waveExact += 1
                    if concurrent { concurrentExact += 1 } else { serialExact += 1 }
                }
                if result.error != nil { errors += 1 }
                print("G0_B03_R16C_CASE wave=\(wave) mode=\(concurrent ? "parallel4" : "serial") owner=\(result.id) codes=\(result.codes.map(String.init).joined(separator: ",")) first=\(result.first.map(String.init) ?? "none") end=\(result.end.map(String.init) ?? "none") comparedBytes=\(result.compared) mismatches=\(result.mismatches) requests=\(result.requests) bodyBytes=\(result.bodyBytes) statuses=\(result.statuses.map(String.init).joined(separator: ",")) barrierOK=\(result.barrierOK) complete=\(result.complete) error=\(result.error ?? "none")")
                print("G0_B03_R16C_TIMING wave=\(wave) owner=\(result.id) openNS=\(result.openedNS.map { $0 - result.startedNS }.map(String.init) ?? "none") firstPCMNS=\(result.firstNS.map(String.init) ?? "none") totalWithCloseNS=\(result.closedNS - result.startedNS)")
            }
            var cpu: UInt64?
            if let a = before.cpuUS, let b = after.cpuUS, b >= a { cpu = UInt64(b - a) }
            if cpu == nil || before.residentBytes == nil || after.residentBytes == nil {
                resourceMissing += 1
            }
            print("G0_B03_R16C_WAVE wave=\(wave) owners=\(results.count) exact=\(waveExact) overlapOK=\(overlapOK) allOwnerOverlapNS=\(overlap) totalNS=\(elapsed) processCPUUS=\(cpu.map(String.init) ?? "none") residentBefore=\(before.residentBytes.map(String.init) ?? "none") residentAfter=\(after.residentBytes.map(String.init) ?? "none") maxRSSDarwin=\(after.maxRSS.map(String.init) ?? "none")")
            XCTAssertEqual(results.count, 4)
            XCTAssertEqual(Set(results.map { $0.id }), Set(inputs.map { $0.id }))
            XCTAssertTrue(overlapOK)
        }
        print("G0_B03_R16C_SUMMARY attempted=\(attempted) exact=\(exact) serialExact=\(serialExact) concurrentExact=\(concurrentExact) overlapWaves=\(overlapWaves) errors=\(errors) resourceMissingWaves=\(resourceMissing)")
        XCTAssertEqual(attempted, 20)
        XCTAssertEqual(exact, 20)
        XCTAssertEqual(serialExact, 4)
        XCTAssertEqual(concurrentExact, 16)
        XCTAssertEqual(overlapWaves, 4)
        XCTAssertEqual(errors, 0)
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


/// Serialized fixture state for the R15A URLProtocol endpoint. Each
/// case has a fresh URLSession; the laboratory runs tests serially.
private final class G0R15EndpointState: @unchecked Sendable {
    struct Event {
        let requestStart: Int
        let start: Int
        let status: Int
        let bytes: Int
    }
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }
    private let lock = NSLock()
    private var payload = Data()
    private var range = true
    private var failures = 0
    private var failureStatus = 0
    private var malformed = false
    private var events: [Event] = []

    func configure(payload: Data, range: Bool, failures: Int = 0,
                   failureStatus: Int = 0, malformed: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.payload = payload
        self.range = range
        self.failures = failures
        self.failureStatus = failureStatus
        self.malformed = malformed
        events = []
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func reply(for request: URLRequest) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        let parts = header.hasPrefix("bytes=")
            ? header.dropFirst(6).split(separator: "-") : []
        let start = parts.count == 2 ? Int(parts[0]) ?? -1 : -1
        let requestedEnd = parts.count == 2 ? Int(parts[1]) ?? -1 : -1
        var status = 200
        var responseStart = 0
        var body = payload
        var headers = ["Accept-Ranges": range ? "bytes" : "none"]
        if failures > 0 {
            failures -= 1
            status = failureStatus
            body = Data()
        } else if range {
            if start < 0 || start >= payload.count || requestedEnd < start {
                status = 416
                body = Data()
                headers["Content-Range"] = "bytes */\(payload.count)"
            } else {
                status = 206
                responseStart = start
                let end = min(requestedEnd, payload.count - 1)
                body = payload.subdata(in: start..<(end + 1))
                let reportedStart = malformed ? start + 1 : start
                headers["Content-Range"] = "bytes \(reportedStart)-\(end)/\(payload.count)"
            }
        }
        headers["Content-Length"] = String(body.count)
        events.append(Event(requestStart: start, start: responseStart, status: status, bytes: body.count))
        return Reply(status: status, headers: headers, body: body)
    }
}

private final class G0R15URLProtocol: URLProtocol, @unchecked Sendable {
    static let state = G0R15EndpointState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "g0-r15.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.state.reply(for: request)
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


/// Test-only HTTP/1.1 server bound exclusively to IPv4 loopback. One
/// request per connection, bounded header, no external endpoints or TLS.
/// Response body metrics are bytes selected by the server, not TCP counters.
private final class G0R15LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0R15EndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.r15.loopback")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(connection, endpoint: endpoint, delayMS: delayMS, queue: queue, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port, port.rawValue != 0,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.flac")
        else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.url = url
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }

    private static func receive(
        _ connection: NWConnection, endpoint: G0R15EndpointState,
        delayMS: Int, queue: DispatchQueue, accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data, _, complete, error in
            var header = accumulated
            if let data { header.append(data) }
            guard error == nil, header.count <= 16384 else { connection.cancel(); return }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                guard let text = String(data: header.prefix(upTo: end.lowerBound), encoding: .utf8)
                else { connection.cancel(); return }
                let lines = text.components(separatedBy: "\r\n")
                guard let first = lines.first, first.hasPrefix("GET /fixture.flac ")
                else { connection.cancel(); return }
                var request = URLRequest(url: URL(string: "http://127.0.0.1/fixture.flac")!)
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 && parts[0].lowercased() == "range" {
                        request.setValue(parts[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
                    }
                }
                let reply = endpoint.reply(for: request)
                let reason: String
                switch reply.status {
                case 200: reason = "OK"
                case 206: reason = "Partial Content"
                case 416: reason = "Range Not Satisfiable"
                case 503: reason = "Service Unavailable"
                default: reason = "Error"
                }
                var response = "HTTP/1.1 \(reply.status) \(reason)\r\nConnection: close\r\nContent-Type: application/octet-stream\r\n"
                for key in reply.headers.keys.sorted() {
                    response += "\(key): \(reply.headers[key]!)\r\n"
                }
                response += "\r\n"
                var bytes = Data(response.utf8)
                bytes.append(reply.body)
                let packet = bytes
                queue.asyncAfter(deadline: .now() + .milliseconds(delayMS)) {
                    connection.send(content: packet, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            } else if complete {
                connection.cancel()
            } else {
                Self.receive(connection, endpoint: endpoint, delayMS: delayMS, queue: queue, accumulated: header)
            }
        }
    }
}


private final class G0R15CResult: @unchecked Sendable {
    struct Value {
        let first: Int32
        let next: Int32
        let hasError: Bool
        let bytesExact: Bool
        let finishedNS: UInt64
    }
    private let lock = NSLock()
    private var value: Value?
    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
    func snapshot() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
