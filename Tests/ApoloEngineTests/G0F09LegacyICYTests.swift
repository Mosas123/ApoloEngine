import Foundation
import Network
import XCTest
@testable import ApoloEngine

final class G0F09LegacyICYTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    func testHeaderBoundaries() throws {
        let prefix = "ICY 200 OK\r\nX: "
        let suffix = "\r\n\r\n"
        for length in [16383, 16384, 16385] {
            let header = prefix + String(repeating: "a", count: length - prefix.utf8.count - suffix.utf8.count) + suffix
            for split in [1, length - 2, length] {
                var parser = LegacyICYHeaderParser()
                let bytes = Data(header.utf8)
                let audio = Data([0, 13, 10, 255])
                var accepted = false
                var failure = "none"
                do {
                    let first = try parser.consume(Data(bytes.prefix(split)))
                    if let first {
                        accepted = first.statusCode == 200 && first.initialAudio.isEmpty
                    } else {
                        let second = try parser.consume(Data(bytes.dropFirst(split)) + audio)
                        accepted = second?.statusCode == 200 && second?.initialAudio == audio
                    }
                } catch { failure = String(describing: error) }
                print("G0_F09F5_BOUNDARY bytes=\(length) split=\(split) accepted=\(accepted) failure=\(failure)")
                XCTAssertEqual(accepted, length <= 16384)
                XCTAssertEqual(failure, length <= 16384 ? "none" : "headersTooLarge")
            }
        }
        for status in ["099","100","200","301","403","599","600","+20","20","2000"] {
            var parser = LegacyICYHeaderParser()
            let result = try? parser.consume(Data("ICY \(status) OK\r\n\r\n".utf8))
            let expected = status.count == 3 && status.allSatisfy { $0.isASCII && $0.isNumber } && (100...599).contains(Int(status) ?? 0)
            print("G0_F09F5_STATUS raw=\(status) accepted=\(result != nil)")
            XCTAssertEqual(result != nil, expected)
        }
        // An LF-only header must terminate before arbitrary compressed body bytes,
        // including a later CRLFCRLF sequence. Observe the coalesced case too.
        let header = Data("ICY 200 OK\nContent-Type: audio/ogg\n\n".utf8)
        let body = Data([0,13,10,13,10,255,42])
        for mode in ["coalesced","headerFirst"] {
            var parser = LegacyICYHeaderParser()
            var accepted = false
            var failure = "none"
            do {
                let r = try parser.consume(mode == "coalesced" ? header + body : header)
                accepted = r?.statusCode == 200 && r?.initialAudio == (mode == "coalesced" ? body : Data())
            } catch { failure = String(describing: error) }
            print("G0_F09F5_LF mode=\(mode) accepted=\(accepted) failure=\(failure)")
            XCTAssertTrue(accepted, "body CRLF sequence must not override earlier LF header boundary")
        }
    }

    func testLoopbackFallbackContracts() throws {
        for mode in ["icy","403","redirect","html","blocked","httpsParse","httpLoss","httpResponseParse"] {
            let header: String
            var body = Data()
            switch mode {
            case "icy":
                header = "ICY 200 OK\r\nContent-Type: audio/ogg\r\nicy-metaint: 4\r\n\r\n"
                body = Data("abcd".utf8) + Data([1]) + Data("StreamTitle='A';".utf8) + Data("efgh".utf8) + Data([0])
            case "403": header = "ICY 403 Forbidden\r\n\r\n"
            case "redirect": header = "ICY 302 Found\r\nLocation: http://127.0.0.1:1/other\r\n\r\n"
            case "html": header = "ICY 200 OK\r\nContent-Type: text/html\r\n\r\n"; body = Data("not audio".utf8)
            default: header = ""
            }
            let state = F09F5Server(response: Data(header.utf8) + body)
            let listener = try NWListener(using: .tcp, on: .any)
            defer { listener.cancel(); state.close() }
            listener.stateUpdateHandler = { status in
                if case .ready = status { state.ready.signal() }
            }
            listener.newConnectionHandler = { conn in state.accept(conn) }
            listener.start(queue: state.queue)
            XCTAssertEqual(state.ready.wait(timeout: .now() + .seconds(5)), .success)
            let port = try XCTUnwrap(listener.port?.rawValue)
            let scheme = mode == "httpsParse" ? "https" : "http"
            let url = try XCTUnwrap(URL(string: "\(scheme)://127.0.0.1:\(port)/station%20test?x=1"))
            F09F5Mock.install(mode)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [F09F5Mock.self]
            let stream = LiveHTTPStream(url: url, headers: ["Authorization":"Bearer synthetic","Cookie":"synthetic=1"],
                capacity: 64, configuration: config,
                onICYTitle: { state.title($0) }, onHTTPStatus: { state.status($0) })
            defer { stream.close() }
            stream.start()
            let fallback = !["httpsParse","httpLoss","httpResponseParse"].contains(mode)
            if fallback {
                XCTAssertEqual(state.requested.wait(timeout: .now() + .seconds(5)), .success)
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            if mode == "icy" {
                while stream.bufferedBytes != 8 && !stream.hasError && DispatchTime.now().uptimeNanoseconds < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                XCTAssertEqual(stream.bufferedBytes, 8)
            } else if mode != "blocked" {
                while !stream.hasError && DispatchTime.now().uptimeNanoseconds < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                XCTAssertTrue(stream.hasError)
            }
            let before = stream.bufferedBytes
            let start = DispatchTime.now().uptimeNanoseconds
            stream.close()
            var data = [UInt8](repeating: 0, count: 64)
            let n = data.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 64) }
            let end = data.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 64) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let s = state.snapshot()
            let request = s.request.lowercased()
            print("G0_F09F5_TCP mode=\(mode) connections=\(s.count) requestOK=\(request.contains("get /station%20test?x=1 http/1.0")) credentials=\(request.contains("authorization:") || request.contains("cookie:")) metadataHeader=\(request.contains("icy-metadata: 1")) before=\(before) bytes=\(n) end=\(end) error=\(stream.hasError) statuses=\(s.statuses) titles=\(s.titles) closeReadMs=\(String(format: "%.3f",ms))")
            XCTAssertEqual(s.count, fallback ? 1 : 0)
            if fallback {
                XCTAssertTrue(request.contains("get /station%20test?x=1 http/1.0"))
                XCTAssertTrue(request.contains("icy-metadata: 1"))
                XCTAssertFalse(request.contains("authorization:") || request.contains("cookie:"))
            }
            XCTAssertEqual(n, mode == "icy" ? 8 : 0)
            if mode == "icy" {
                XCTAssertEqual(Data(data.prefix(n)), Data("abcdefgh".utf8))
                XCTAssertEqual(s.titles, ["A"])
            }
            XCTAssertEqual(end, 0)
            XCTAssertEqual(stream.hasError, !["icy","blocked"].contains(mode))
        }
    }
}

private final class F09F5Server: @unchecked Sendable {
    let queue = DispatchQueue(label: "g0.f09f5.server")
    let ready = DispatchSemaphore(value: 0)
    let requested = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let response: Data
    private var connections: [NWConnection] = []
    private var request = Data()
    private var statuses: [Int] = []
    private var titles: [String] = []
    init(response: Data) { self.response = response }
    func accept(_ conn: NWConnection) {
        lock.lock(); connections.append(conn); lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] status in
            guard case .ready = status, let self, let conn else { return }
            self.receive(conn)
        }
        conn.start(queue: queue)
    }
    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, error == nil, let data else { return }
            self.lock.lock()
            self.request.append(data)
            let finished = self.request.range(of: Data([13,10,13,10])) != nil
            self.lock.unlock()
            if finished {
                if !self.response.isEmpty { conn.send(content: self.response, completion: .contentProcessed { _ in }) }
                self.requested.signal()
            } else if !complete { self.receive(conn) }
        }
    }
    func title(_ s: String) { lock.lock(); titles.append(s); lock.unlock() }
    func status(_ n: Int) { lock.lock(); statuses.append(n); lock.unlock() }
    func snapshot() -> (count: Int, request: String, statuses: [Int], titles: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (connections.count,String(decoding: request, as: UTF8.self),statuses,titles)
    }
    func close() {
        lock.lock(); let c = connections; lock.unlock()
        for conn in c { conn.cancel() }
    }
}
private final class F09F5Mock: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = ""
    static func install(_ value: String) { lock.lock(); mode = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let mode = Self.mode; Self.lock.unlock()
        if mode == "httpResponseParse", let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"audio/ogg"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didFailWithError: URLError(mode == "httpLoss" ? .networkConnectionLost : .cannotParseResponse))
    }
    override func stopLoading() {}
}
