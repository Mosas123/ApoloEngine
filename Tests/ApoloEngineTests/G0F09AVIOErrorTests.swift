import Foundation
import XCTest
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

final class G0F09AVIOErrorTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func stream(_ mode: String) throws -> HTTPStream {
        F09E1Protocol.reset(mode)
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [F09E1Protocol.self]
        c.urlCache = nil
        return HTTPStream(url: try XCTUnwrap(URL(string: "https://f09e1.invalid/bytes")),
                          headers: [:], configuration: c)
    }
    private func read(_ stream: HTTPStream, _ count: Int) -> (Int, String) {
        var buffer = [UInt8](repeating: 0, count: count)
        let n = buffer.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: count) }
        return (n, buffer.prefix(max(0, min(n, count))).map { String(format: "%02x", $0) }.joined())
    }
    func testF09E1HTTPContracts() throws {
        let modes = ["known", "unknown", "changed", "wrongUnit", "invalidTotal",
                     "shortBody", "overRange", "empty200", "status416", "status403",
                     "lossOnce", "lossAlways", "status503"]
        for mode in modes {
            let s = try stream(mode)
            let size = s.seek(offset: 0, whence: 0x10000)
            let a = read(s, 8)
            let seek = s.seek(offset: 32, whence: 0)
            let b = read(s, 8)
            let end = s.seek(offset: 64, whence: 0)
            let c = read(s, 8)
            let req = F09E1Protocol.snapshot()
            XCTAssertLessThanOrEqual(req.count, 20)
            if mode == "known" || mode == "lossOnce" {
                XCTAssertEqual(size, 64); XCTAssertEqual(a.0, 8)
                XCTAssertEqual(b.0, 8); XCTAssertEqual(c.0, 0)
                XCTAssertFalse(s.hasError)
                XCTAssertEqual(a.1, "0001020304050607")
                XCTAssertEqual(b.1, "2021222324252627")
            }
            print("G0_F09E1_HTTP mode=\(mode) size=\(size) a=\(a.0):\(a.1) seek=\(seek) b=\(b.0):\(b.1) end=\(end) c=\(c.0):\(c.1) error=\(s.hasError) requests=\(req.joined(separator: ","))")
        }
        print("G0_F09E1_HTTP_SUMMARY profiles=\(modes.count)")
    }
    func testF09E1AVIOReturns() throws {
        let modes = ["known", "unknown", "changed", "shortBody", "empty200",
                     "status416", "status403", "lossOnce", "lossAlways", "status503"]
        for mode in modes {
            let s = try stream(mode)
            let t = try XCTUnwrap(HTTPTransport(stream: s))
            defer { t.close() }
            let c = try XCTUnwrap(t.context)
            var codes: [Int32] = []
            var bytes = [UInt8](repeating: 0, count: 24)
            var received = Data()
            for _ in 0..<8 {
                let n = bytes.withUnsafeMutableBufferPointer { avio_read(c, $0.baseAddress!, 24) }
                codes.append(n)
                if n > 0 { received.append(contentsOf: bytes.prefix(Int(n))) }
                if n < 0 { break }
            }
            let repeatCode = bytes.withUnsafeMutableBufferPointer { avio_read(c, $0.baseAddress!, 24) }
            let req = F09E1Protocol.snapshot()
            XCTAssertLessThanOrEqual(req.count, 20)
            if mode == "known" || mode == "lossOnce" {
                XCTAssertEqual(received, Data((0..<64).map { UInt8($0) }))
                XCTAssertEqual(codes.last, -541478725)
                XCTAssertEqual(repeatCode, -541478725)
                XCTAssertFalse(s.hasError)
            }
            print("G0_F09E1_AVIO mode=\(mode) codes=\(codes.map(String.init).joined(separator: ",")) repeat=\(repeatCode) bytes=\(received.count) payload=\(received.map { String(format: "%02x", $0) }.joined()) avioError=\(c.pointee.error) streamError=\(s.hasError) requests=\(req.joined(separator: ","))")
        }
        print("G0_F09E1_AVIO_SUMMARY profiles=\(modes.count)")
    }
}

private final class F09E1Protocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = "known"
    nonisolated(unsafe) private static var requests: [String] = []
    static func reset(_ mode: String) {
        lock.lock(); defer { lock.unlock() }
        self.mode = mode; requests = []
    }
    static func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09e1.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let range = request.value(forHTTPHeaderField: "Range"),
              range.hasPrefix("bytes=") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let bounds = range.dropFirst(6).split(separator: "-")
        guard bounds.count == 2, let start = Int(bounds[0]), let requestedEnd = Int(bounds[1]), start >= 0, requestedEnd >= start else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        Self.lock.lock()
        let mode = Self.mode
        let first = Self.requests.isEmpty
        Self.requests.append("\(start)-\(requestedEnd)")
        Self.lock.unlock()
        if mode == "lossAlways" || (mode == "lossOnce" && first) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        var status = 206
        var body = Data()
        var headers: [String: String] = [:]
        if mode == "status416" || start >= 64 {
            status = 416; headers["Content-Range"] = "bytes */64"
        } else if mode == "status403" { status = 403 }
        else if mode == "status503" { status = 503 }
        else if mode == "empty200" { status = 200 }
        else {
            let end = min(63, requestedEnd, start + 15)
            let unit = mode == "wrongUnit" ? "items" : "bytes"
            var total = "64"
            if mode == "unknown" { total = "*" }
            if mode == "invalidTotal" { total = "nonsense" }
            if mode == "changed" && start > 0 { total = "80" }
            let last = mode == "overRange" ? requestedEnd + 1 : end
            // Keep adversarial body bounded: overRange is an inconsistent declaration, not a giant allocation.
            headers["Content-Range"] = "\(unit) \(start)-\(last)/\(total)"
            body = Data((start...end).map { UInt8($0) })
            if mode == "shortBody" { body.removeLast() }
        }
        headers["Content-Length"] = String(body.count)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
