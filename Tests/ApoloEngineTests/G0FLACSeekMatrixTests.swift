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
