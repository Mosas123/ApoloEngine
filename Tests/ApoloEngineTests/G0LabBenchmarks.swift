import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

/// Opt-in lab measurements. No network or renderer, no production code changes.
/// Run only with APOLO_G0_LAB=1; normal CI discovers these tests but skips them.
final class G0LabBenchmarks: XCTestCase {
    private let repetitions = 20

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1",
            "G0 lab benchmarks are opt-in; use the dedicated diagnostic workflow"
        )
    }

    private enum FixtureError: Error {
        case missingPCM
        case unboundedRead
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "flac",
                subdirectory: "Fixtures"
            )
        )
    }

    private func elapsedNanoseconds(_ action: () throws -> Void) throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        try action()
        return DispatchTime.now().uptimeNanoseconds - started
    }

    private func report(_ phase: String, _ values: [UInt64]) {
        let sorted = values.sorted()
        XCTAssertEqual(sorted.count, repetitions)
        guard !sorted.isEmpty else { return }
        func nearestRank(_ fraction: Double) -> UInt64 {
            let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
            return sorted[index]
        }
        print(
            "G0_LAB phase=\(phase) samples=\(sorted.count) unit=nanoseconds "
                + "min=\(sorted[0]) p50=\(nearestRank(0.50)) "
                + "p95=\(nearestRank(0.95)) max=\(sorted[sorted.count - 1])"
        )
    }

    private func probeAndClose(_ url: URL) throws {
        let source = try OpenedSource.open(url: url)
        source.close()
    }

    /// FFmpeg demux + decoder + Apolo PCM conversion/DSP + CoreMedia packaging.
    /// Not an isolated libavcodec benchmark and deliberately does not use AVIO HTTP.
    private func decodeToEOF(_ url: URL) throws -> Int {
        let decoder = AudioDecoder()
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }
        var frames = 0
        var reads = 0
        while let buffer = try decoder.readNextBuffer() {
            frames += CMSampleBufferGetNumSamples(buffer)
            reads += 1
            if reads > 10_000 { throw FixtureError.unboundedRead }
        }
        guard frames > 0 else { throw FixtureError.missingPCM }
        return frames
    }

    /// Open and prime before starting the timer; measure seek through first decoded
    /// PCM. Excludes open and close, includes FFmpeg seek, resampler reset and read.
    private func seekToFirstPCM(_ url: URL) throws -> UInt64 {
        let source = try OpenedSource.open(url: url)
        let duration = source.info.duration
        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }
        guard try decoder.readNextBuffer() != nil else { throw FixtureError.missingPCM }

        let target = duration > 0 ? min(duration * 0.25, 0.10) : 0
        let started = DispatchTime.now().uptimeNanoseconds
        try decoder.seek(to: target)
        let first = try decoder.readNextBuffer()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        guard first != nil else { throw FixtureError.missingPCM }
        return elapsed
    }

    func testG0ProbeOpenClose20Times() throws {
        let url = try fixture()
        try probeAndClose(url) // Warm-up, not counted.
        var values: [UInt64] = []
        for _ in 0..<repetitions {
            values.append(try elapsedNanoseconds { try probeAndClose(url) })
        }
        report("local-flac-probe-and-close", values)
    }

    func testG0DecodeToEOF20Times() throws {
        let url = try fixture()
        let expectedFrames = try decodeToEOF(url) // Warm-up and correctness check.
        var values: [UInt64] = []
        for _ in 0..<repetitions {
            var decodedFrames = 0
            values.append(try elapsedNanoseconds {
                decodedFrames = try decodeToEOF(url)
            })
            XCTAssertEqual(decodedFrames, expectedFrames, "Frame count must not vary across cycles")
        }
        report("local-flac-open-decode-to-eof-close", values)
    }

    func testG0SeekToPCM20Times() throws {
        let url = try fixture()
        _ = try seekToFirstPCM(url) // Warm-up.
        var values: [UInt64] = []
        for _ in 0..<repetitions {
            values.append(try seekToFirstPCM(url))
        }
        report("local-flac-seek-to-first-pcm", values)
    }

    /// XCTest collects process-level CPU and memory metrics for an entire
    /// repeatable 20-cycle scenario. These are simulator lab metrics, not
    /// physical iPhone RSS/energy or isolated decoder CPU.
    func testG0LifecycleCPUAndMemory() throws {
        let url = try fixture()
        try probeAndClose(url) // Warm-up.
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            for _ in 0..<repetitions {
                do {
                    _ = try decodeToEOF(url)
                } catch {
                    XCTFail("G0 decode/open/close failed: \(error)")
                    return
                }
            }
        }
    }
}
