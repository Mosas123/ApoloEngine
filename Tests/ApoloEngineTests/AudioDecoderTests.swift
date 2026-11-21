import CoreMedia
import XCTest
@testable import ApoloEngine

final class AudioDecoderTests: XCTestCase {
    func testDecodesPCMWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apolo-tone-\(UUID().uuidString).wav")
        try makeToneWAV().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = AudioDecoder()
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }

        var buffers = 0
        var samples = 0
        while let buffer = try decoder.readNextBuffer() {
            buffers += 1
            samples += CMSampleBufferGetNumSamples(buffer)
            if buffers > 2_000 { break }
        }

        XCTAssertGreaterThan(buffers, 0)
        XCTAssertGreaterThan(samples, 0)
    }

    func testStartOffsetShiftsTheTimeline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apolo-offset-\(UUID().uuidString).wav")
        try makeToneWAV().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = AudioDecoder()
        decoder.startOffsetSeconds = 10
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }

        let first = try XCTUnwrap(try decoder.readNextBuffer())
        let pts = CMSampleBufferGetPresentationTimeStamp(first).seconds
        XCTAssertEqual(pts, 10, accuracy: 0.01)
    }

    func testAdoptsAnAlreadyOpenedSource() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apolo-adopt-\(UUID().uuidString).wav")
        try makeToneWAV().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try OpenedSource.open(url: url)
        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }

        var samples = 0
        while let buffer = try decoder.readNextBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertGreaterThan(samples, 0)
    }

    func testDecodesFLAC() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "flac",
                subdirectory: "Fixtures"
            )
        )
        let source = try OpenedSource.open(url: url)
        XCTAssertEqual(source.info.audioTracks.first?.codec, "flac")
        XCTAssertEqual(source.info.audioTracks.first?.channels, 2)

        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }

        var samples = 0
        while let buffer = try decoder.readNextBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertGreaterThan(samples, 0)
    }

    /// Regression for Trop downloads/imports in the iOS Documents/Downloads
    /// folder. Foundation percent-encodes spaces, brackets and unicode in
    /// absoluteString, while FFmpeg's file protocol expects a real path.
    func testDecodesDownloadedFLACWithSpecialFilename() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "flac",
                subdirectory: "Fixtures"
            )
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Apolo Download QA \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let names = [
            "Bad Bunny - BAILE INoLVIDABLE [a1Femq4NPxs].flac",
            "Björk - Jóga #100% [imported].flac",
            "Soda Stereo - Un Millón De Años Luz [abc123].flac"
        ]
        for name in names {
            let localURL = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixture, to: localURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
            XCTAssertTrue(localURL.absoluteString.contains("%20"))

            do {
                let source = try OpenedSource.open(url: localURL)
                XCTAssertEqual(source.info.audioTracks.first?.codec, "flac")

                let decoder = AudioDecoder()
                try decoder.adopt(source)
                defer { decoder.close() }

                let pcm = try XCTUnwrap(try decoder.readNextBuffer())
                XCTAssertGreaterThan(CMSampleBufferGetNumSamples(pcm), 0)
            }
        }
    }

    func testDecodesAPE() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "ape",
                subdirectory: "Fixtures"
            )
        )
        let source = try OpenedSource.open(url: url)
        XCTAssertEqual(source.info.audioTracks.first?.codec, "ape")
        XCTAssertEqual(source.info.audioTracks.first?.channels, 2)

        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }

        var samples = 0
        while let buffer = try decoder.readNextBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertGreaterThan(samples, 0)
    }

    func testDecodesTTA() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "tta",
                subdirectory: "Fixtures"
            )
        )
        let source = try OpenedSource.open(url: url)
        XCTAssertEqual(source.info.audioTracks.first?.codec, "tta")
        XCTAssertEqual(source.info.audioTracks.first?.channels, 2)

        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }

        var samples = 0
        while let buffer = try decoder.readNextBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertGreaterThan(samples, 0)
    }

    func testMP4MuxerIsAvailable() {
        XCTAssertTrue(EAC3Passthrough.isMP4MuxerAvailable())
    }

    private func makeToneWAV(
        sampleRate: Int = 44_100,
        seconds: Double = 0.25,
        channels: Int = 2,
        bitsPerSample: Int = 16
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = frames * blockAlign

        var data = Data()
        func appendU32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func appendU16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)
        appendU16(1)
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        appendU32(UInt32(dataSize))

        for frame in 0..<frames {
            let phase = 2 * Double.pi * 440 * Double(frame) / Double(sampleRate)
            let sample = Int16(sin(phase) * 12_000)
            for _ in 0..<channels {
                var little = sample.littleEndian
                data.append(Data(bytes: &little, count: 2))
            }
        }
        return data
    }
}
