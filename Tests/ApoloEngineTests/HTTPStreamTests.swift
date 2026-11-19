import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class HTTPStreamTests: XCTestCase {
    func testHTTPStreamReadsAndSeeks() {
        MockURLProtocol.supportsRange = true
        MockURLProtocol.payload = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let stream = HTTPStream(
            url: URL(string: "https://mock.local/bytes")!,
            headers: [:],
            configuration: makeConfiguration()
        )

        var first = [UInt8](repeating: 0, count: 4)
        let read = first.withUnsafeMutableBufferPointer { buffer in
            stream.read(into: buffer.baseAddress!, count: 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(first, [0, 1, 2, 3])

        XCTAssertEqual(stream.seek(offset: 2, whence: 0), 2)
        var second = [UInt8](repeating: 0, count: 2)
        let readAgain = second.withUnsafeMutableBufferPointer { buffer in
            stream.read(into: buffer.baseAddress!, count: 2)
        }
        XCTAssertEqual(readAgain, 2)
        XCTAssertEqual(second, [2, 3])

        XCTAssertEqual(stream.seek(offset: 0, whence: 0x10000), 8)
        XCTAssertEqual(stream.seek(offset: -2, whence: 2), 6)
    }

    func testHTTPStreamFallsBackWhenRangeIsIgnored() {
        MockURLProtocol.supportsRange = false
        MockURLProtocol.payload = Data([9, 8, 7, 6])
        let stream = HTTPStream(
            url: URL(string: "https://mock.local/full")!,
            headers: [:],
            configuration: makeConfiguration()
        )

        var buffer = [UInt8](repeating: 0, count: 4)
        let read = buffer.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(buffer, [9, 8, 7, 6])
    }

    func testHTTPAVIOProbesAndDecodesAWAV() throws {
        MockURLProtocol.supportsRange = true
        MockURLProtocol.payload = makeWAV()
        let url = URL(string: "https://mock.local/tone.wav")!
        let source = try OpenedSource.open(
            url: url,
            sessionConfiguration: makeConfiguration()
        )
        XCTAssertEqual(source.info.audioTracks.first?.channels, 2)

        let decoder = AudioDecoder()
        try decoder.adopt(source)
        defer { decoder.close() }

        var samples = 0
        var buffers = 0
        while let buffer = decoder.readNextBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
            buffers += 1
            if buffers > 2_000 {
                XCTFail("the decoder never signalled EOF")
                break
            }
        }
        XCTAssertGreaterThan(samples, 0)
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
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

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var supportsRange = true

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let full = Self.payload
        var body = full
        var status = 200
        var headers = [
            "Content-Length": "\(full.count)",
            "Accept-Ranges": Self.supportsRange ? "bytes" : "none",
        ]

        if Self.supportsRange,
           let header = request.value(forHTTPHeaderField: "Range"),
           let requested = Self.parseRange(header, total: full.count) {
            status = 206
            body = full.subdata(in: requested.lowerBound..<requested.upperBound)
            headers["Content-Length"] = "\(body.count)"
            headers["Content-Range"] =
                "bytes \(requested.lowerBound)-\(requested.upperBound - 1)/\(full.count)"
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parseRange(
        _ header: String,
        total: Int
    ) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1])
        else { return nil }
        let lower = max(0, min(start, total))
        let upper = max(lower, min(end + 1, total))
        return lower..<upper
    }
}
