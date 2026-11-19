import CoreMedia
import XCTest
@testable import ApoloEngine

final class FormatTests: XCTestCase {
    func testReplayGainParsing() {
        XCTAssertEqual(OpenedSource.parseReplayGain("-7.23 dB"), -7.23)
        XCTAssertEqual(OpenedSource.parseReplayGain("+3.0 dB"), 3.0)
        XCTAssertEqual(OpenedSource.parseReplayGain(" -1.5db "), -1.5)
        XCTAssertNil(OpenedSource.parseReplayGain("garbage"))
    }

    func testDec3JOCFlag() {
        XCTAssertTrue(EAC3Passthrough.carriesJOC(dec3: makeDec3(joc: true)))
        XCTAssertFalse(EAC3Passthrough.carriesJOC(dec3: makeDec3(joc: false)))
    }

    func testOpensAndProbesAWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apolo-probe-\(UUID().uuidString).wav")
        try makeWAV().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try OpenedSource.open(url: url)
        defer { source.close() }

        XCTAssertEqual(source.info.audioTracks.first?.channels, 2)
        XCTAssertGreaterThan(source.info.duration, 0)
    }

    private func makeDec3(joc: Bool) -> Data {
        var writer = BitWriter()
        writer.write(0, count: 13)   // data_rate
        writer.write(0, count: 3)    // num_ind_sub => one substream
        writer.write(0, count: 2)    // fscod
        writer.write(16, count: 5)   // bsid
        writer.write(0, count: 1)    // reserved
        writer.write(0, count: 1)    // asvc
        writer.write(0, count: 3)    // bsmod
        writer.write(7, count: 3)    // acmod = 5.1
        writer.write(1, count: 1)    // lfeon
        writer.write(0, count: 3)    // reserved
        writer.write(0, count: 4)    // num_dep_sub
        writer.write(0, count: 1)    // reserved
        writer.write(0, count: 7)    // reserved
        writer.write(joc ? 1 : 0, count: 1)
        return writer.data()
    }

    private func makeWAV(
        sampleRate: Int = 44_100,
        seconds: Double = 0.25,
        channels: Int = 2
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let blockAlign = channels * 2
        let byteRate = sampleRate * blockAlign
        let dataSize = frames * blockAlign

        var data = Data()
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }

        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))
        for _ in 0..<(frames * channels) {
            var sample = Int16(1_000).littleEndian
            data.append(Data(bytes: &sample, count: 2))
        }
        return data
    }
}

private struct BitWriter {
    private var bits: [UInt8] = []

    mutating func write(_ value: UInt32, count: Int) {
        for index in stride(from: count - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> UInt32(index)) & 1))
        }
    }

    func data() -> Data {
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit == 1 {
            bytes[index / 8] |= UInt8(0x80 >> (index % 8))
        }
        return Data(bytes)
    }
}
