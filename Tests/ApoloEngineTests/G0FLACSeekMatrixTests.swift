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
