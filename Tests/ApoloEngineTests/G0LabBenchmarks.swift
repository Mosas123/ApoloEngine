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

        let target = duration > 0 ? max(0, min(duration * 0.25, duration - 0.01)) : 0
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

    /// Controlled seek fixture: two seconds of 44.1-kHz stereo PCM WAV.
    /// Unlike the 250-ms FLAC regression fixture, the target is separated
    /// from startup and there are sufficient decoded frames after the seek.
    private func makeSeekControlWAV() throws -> URL {
        let sampleRate = 44_100
        let frames = 2 * sampleRate
        let channels = 2
        let dataSize = frames * channels * MemoryLayout<Int16>.size
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g0-seek-control-\(UUID().uuidString).wav")

        var data = Data(capacity: 44 + dataSize)
        func appendU32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendU32(16)
        appendU16(1)
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * channels * 2))
        appendU16(UInt16(channels * 2))
        appendU16(16)
        data.append(contentsOf: Array("data".utf8))
        appendU32(UInt32(dataSize))
        for i in 0..<frames {
            var sample = Int16(sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)) * 12_000)
                .littleEndian
            withUnsafeBytes(of: &sample) { bytes in
                for _ in 0..<channels { data.append(contentsOf: bytes) }
            }
        }
        try data.write(to: url)
        return url
    }

    func testG0SeekToPCM20Times() throws {
        let url = try makeSeekControlWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try seekToFirstPCM(url) // Warm-up.
        var values: [UInt64] = []
        for _ in 0..<repetitions {
            values.append(try seekToFirstPCM(url))
        }
        report("local-wav-seek-to-first-pcm-control", values)
    }

    /// An observation, NOT a success assertion: the original 250-ms FLAC
    /// fixture returned unsupportedFormat on avformat_seek_file in G0 #45219830168.
    /// Preserve the outcome visibly for B03 rather than claiming FLAC seek passes.
    func testG0ShortFLACSeekObservation() throws {
        let url = try fixture()
        do {
            let ns = try seekToFirstPCM(url)
            print("G0_LAB phase=short-flac-seek-observation outcome=success elapsedNs=\(ns)")
        } catch {
            print("G0_LAB phase=short-flac-seek-observation outcome=error error=\(error)")
        }
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
