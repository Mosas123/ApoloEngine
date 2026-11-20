import Foundation
import XCTest
@testable import ApoloEngine

final class LiveHTTPStreamTests: XCTestCase {
    func testLiveNetworkStripsICYAndDeliversAudio() {
        MockLiveURLProtocol.payload = [
            Data("abcd".utf8),
            Data([1]) + Data("StreamTitle='A';".utf8),
            Data("efgh".utf8)
        ]
        MockLiveURLProtocol.headers = [
            "Content-Type": "audio/ogg",
            "icy-metaint": "4",
        ]
        MockLiveURLProtocol.statusCode = 200

        let titles = LiveTitleRecorder()
        let stream = LiveHTTPStream(
            url: URL(string: "https://radio.mock/stream")!,
            headers: [:],
            capacity: 128,
            configuration: configuration(),
            onICYTitle: { titles.record($0) }
        )
        stream.start()
        defer { stream.close() }

        var bytes = [UInt8](repeating: 0, count: 8)
        var count = 0
        while count < 8 {
            let next = bytes.withUnsafeMutableBufferPointer {
                stream.read(
                    into: $0.baseAddress!.advanced(by: count),
                    count: 8 - count
                )
            }
            if next == 0 { break }
            count += next
        }
        XCTAssertEqual(count, 8)
        XCTAssertEqual(bytes, Array("abcdefgh".utf8))
        XCTAssertEqual(titles.values, ["A"])
    }

    func testRejectedRadioResponseFailsWithoutBufferGrowth() {
        MockLiveURLProtocol.payload = [Data([1, 2, 3])]
        MockLiveURLProtocol.headers = ["Content-Type": "text/html"]
        MockLiveURLProtocol.statusCode = 200

        let stream = LiveHTTPStream(
            url: URL(string: "https://radio.mock/login")!,
            headers: [:],
            capacity: 32,
            configuration: configuration()
        )
        stream.start()
        defer { stream.close() }

        var bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 8)
        }, 0)
        XCTAssertTrue(stream.hasError)
        XCTAssertEqual(stream.bufferedBytes, 0)
    }

    func test403MarksCancellationTokenAsTerminal() {
        MockLiveURLProtocol.payload = [Data()]
        MockLiveURLProtocol.headers = ["Content-Type": "audio/ogg"]
        MockLiveURLProtocol.statusCode = 403

        let token = LiveStreamCancellation()
        let stream = LiveHTTPStream(
            url: URL(string: "https://radio.mock/restricted")!,
            headers: [:],
            capacity: 32,
            configuration: configuration(),
            onHTTPStatus: { token.recordHTTPStatus($0) }
        )
        token.register(stream)
        stream.start()
        defer { token.cancel() }

        var bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 8)
        }, 0)
        XCTAssertEqual(token.terminalHTTPStatus, 403)
        XCTAssertTrue(stream.hasError)
    }

    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLiveURLProtocol.self]
        return config
    }
}

private final class LiveTitleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class MockLiveURLProtocol: URLProtocol {
    nonisolated(unsafe) static var payload: [Data] = []
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "radio.mock"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: Self.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        for part in Self.payload {
            client?.urlProtocol(self, didLoad: part)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
