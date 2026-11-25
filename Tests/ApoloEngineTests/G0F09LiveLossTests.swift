import Foundation
import XCTest
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

final class G0F09LiveLossTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func until(_ predicate: () -> Bool, seconds: Double = 5) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        repeat {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return predicate()
    }

    func testLossOrderingMatrix() throws {
        for mode in ["immediate", "confirmedBuffer", "confirmedRead", "cleanEnd"] {
            for route in ["stream", "avio"] {
                for trial in 1...3 {
                    try runCase(mode: mode, route: route, trial: trial)
                }
            }
        }
        print("G0_F09F1_SUMMARY profiles=24")
    }

    private func runCase(mode: String, route: String, trial: Int) throws {
        let state = F09F1LossState(mode: mode)
        let key = "\(mode)-\(route)-\(trial)"
        F09F1LossProtocol.install(key, state)
        defer { state.release.signal(); F09F1LossProtocol.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [F09F1LossProtocol.self]
        config.urlCache = nil
        let url = try XCTUnwrap(URL(string: "https://f09f1.invalid/" + key))
        let stream = LiveHTTPStream(url: url, headers: [:], capacity: 128, configuration: config,
                                    onHTTPStatus: { state.status($0) })
        let transport: LiveHTTPTransport?
        if route == "avio" { transport = try XCTUnwrap(LiveHTTPTransport(stream: stream)) }
        else { transport = nil; stream.start() }
        defer { transport?.close(); stream.close() }

        var payload = Data()
        var codes = [Int32]()
        func read(_ count: Int) -> Int32 {
            var bytes = [UInt8](repeating: 0, count: count)
            let rc = bytes.withUnsafeMutableBufferPointer { ptr -> Int32 in
                if let ctx = transport?.context {
                    return avio_read(ctx, ptr.baseAddress!, Int32(count))
                }
                return Int32(stream.read(into: ptr.baseAddress!, count: count))
            }
            codes.append(rc)
            if rc > 0 { payload.append(contentsOf: bytes.prefix(Int(rc))) }
            return rc
        }
        guard state.sent.wait(timeout: .now() + .seconds(5)) == .success else {
            XCTFail("mock did not emit payload")
            return
        }
        var confirmed = false
        var bufferedBefore = stream.bufferedBytes
        var beforeLoss = 0
        if mode == "confirmedBuffer" || mode == "confirmedRead" {
            confirmed = until { stream.bufferedBytes == 16 || stream.hasError }
                && stream.bufferedBytes == 16
            bufferedBefore = stream.bufferedBytes
            XCTAssertTrue(confirmed, "payload must reach production buffer before loss")
            if mode == "confirmedRead", confirmed {
                XCTAssertEqual(read(8), 8)
                beforeLoss = payload.count
            }
            state.release.signal()
        }
        // Wait for terminal failure before reading remaining buffered bytes.
        let terminalObserved = until { stream.hasError }
        let bufferedAfter = stream.bufferedBytes
        if terminalObserved {
            for _ in 0..<4 {
                if read(64) <= 0 { break }
            }
            _ = read(64)
        }
        let snapshot = state.snapshot()
        let expectedTerminal: Int32 = route == "avio" ? -5 : 0
        let expected = Data((0..<16).map { UInt8($0) })
        print("G0_F09F1_CASE key=\(key) confirmed=\(confirmed) bufferedBefore=\(bufferedBefore) readBeforeLoss=\(beforeLoss) bufferedAfter=\(bufferedAfter) terminal=\(terminalObserved) requests=\(snapshot.requests) status=\(snapshot.status) sent=\(snapshot.sent) failures=\(snapshot.failures) stops=\(snapshot.stops) codes=\(codes) bytes=\(payload.count) hex=\(payload.map { String(format: "%02x", $0) }.joined()) error=\(stream.hasError)")
        XCTAssertTrue(terminalObserved)
        XCTAssertEqual(snapshot.requests, 1)
        XCTAssertEqual(snapshot.status, 200)
        XCTAssertEqual(snapshot.sent, 16)
        XCTAssertEqual(snapshot.failures, mode == "cleanEnd" ? 0 : 1)
        XCTAssertEqual(Array(codes.suffix(2)), [expectedTerminal, expectedTerminal])
        if mode == "immediate" {
            // Preserve original strict reproduction in #90 (run separately).
            // Here report whether bytes reached the buffer, not assume didLoad
            // on URLProtocol proves delegate acceptance.
            XCTAssertTrue(payload.isEmpty || payload == expected)
        } else {
            XCTAssertEqual(payload, expected)
        }
        if mode == "confirmedBuffer" { XCTAssertEqual(bufferedAfter, 16) }
        if mode == "confirmedRead" { XCTAssertEqual(beforeLoss, 8) }
    }
}

private final class F09F1LossState: @unchecked Sendable {
    let mode: String
    let sent = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var requests = 0
    private var statusCode = 0
    private var sentBytes = 0
    private var failures = 0
    private var stops = 0
    init(mode: String) { self.mode = mode }
    func begin() { lock.lock(); requests += 1; lock.unlock() }
    func status(_ n: Int) { lock.lock(); statusCode = n; lock.unlock() }
    func emitted(_ n: Int) { lock.lock(); sentBytes += n; lock.unlock(); sent.signal() }
    func failure() { lock.lock(); failures += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func snapshot() -> (requests: Int, status: Int, sent: Int, failures: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, statusCode, sentBytes, failures, stops)
    }
}

private final class F09F1LossProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: F09F1LossState] = [:]
    private let instanceLock = NSRecursiveLock()
    private var stopped = false
    private var state: F09F1LossState?
    static func install(_ key: String, _ state: F09F1LossState) {
        lock.lock(); states[key] = state; lock.unlock()
    }
    static func remove(_ key: String) {
        lock.lock(); states.removeValue(forKey: key); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09f1.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); let s = Self.states[url.lastPathComponent]; Self.lock.unlock()
        guard let s, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"]) else { return }
        instanceLock.lock()
        state = s
        s.begin()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((0..<16).map { UInt8($0) }))
        s.emitted(16)
        if s.mode == "immediate" {
            s.failure()
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else if s.mode == "cleanEnd" {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            DispatchQueue.global().async { [weak self] in
                guard s.release.wait(timeout: .now() + .seconds(10)) == .success else { return }
                self?.disconnect(s)
            }
        }
        instanceLock.unlock()
    }
    private func disconnect(_ s: F09F1LossState) {
        instanceLock.lock(); defer { instanceLock.unlock() }
        guard !stopped else { return }
        s.failure()
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {
        instanceLock.lock(); defer { instanceLock.unlock() }
        stopped = true; state?.stop()
    }
}
