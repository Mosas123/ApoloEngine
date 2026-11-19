import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class HTTPStreamTests: XCTestCase {
    func testHTTPStreamReadsAndSeeks() {
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

    func testHTTPAVIOProbesAndDecodesAWAV() throws {
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
        while let buffer = decoder.readNextBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
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

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Length": "\(Self.payload.count)",
                      "Accept-Ranges": "bytes",
                  ]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
