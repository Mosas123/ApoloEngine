import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import CoreMedia
import Darwin
import Dispatch
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

        mutating func append(_ buffer: CMSampleBuffer) throws {
            let count = CMSampleBufferGetNumSamples(buffer)
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard count > 0, seconds.isFinite, seconds >= 0,
                  let block = CMSampleBufferGetDataBuffer(buffer)
            else { throw MatrixError.invalidTimestamp }
            let tick = Int64((seconds * 44100).rounded())
            guard abs(seconds * 44100 - Double(tick)) < 0.001,
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

        mutating func append(_ frame: UnsafeMutablePointer<AVFrame>) throws {
            let value = frame.pointee
            let start = value.pts
            let count = Int(value.nb_samples)
            let format = AVSampleFormat(rawValue: value.format)
            let width = Int(av_get_bytes_per_sample(format))
            let channelCount = Int(value.ch_layout.nb_channels)
            guard start >= 0, count > 0, value.sample_rate == 44100,
                  channelCount == 2, width > 0,
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
        retryAnchors: [Int64] = [],
        onPrimePacket: ((Int) -> Void)? = nil,
        onPacket: ((Int) -> Void)? = nil,
        onSeek: ((Int32, UInt64) -> Void)? = nil,
        onFrame: ((UnsafeMutablePointer<AVFrame>) throws -> Void)? = nil
    ) throws -> (code: Int32, pcm: NativePCMSequenceR9) {
        let source = try OpenedSource.open(url: url)
        var ownedFormat = source.takeFormatContext()
        defer { avformat_close_input(&ownedFormat) }
        guard let context = ownedFormat,
              context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0],
              stream.pointee.time_base.num == 1,
              stream.pointee.time_base.den == 44100,
              let parameters = stream.pointee.codecpar,
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
                    try output.append(frame)
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
        format: CMFormatDescription
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
            duration: CMTime(value: 1, timescale: 44100),
            presentationTimeStamp: CMTime(value: tick, timescale: 44100),
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
