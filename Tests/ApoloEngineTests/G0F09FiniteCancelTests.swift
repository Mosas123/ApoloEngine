import Foundation
import XCTest
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

final class G0F09FiniteCancelTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    // Replaced only in ephemeral candidate runner, never in committed Sources.
    private func makeCancel(_ stream: HTTPStream, beforeRegistration: Bool) -> @Sendable () -> Void {
        return {} // G0_E2_CONTROL_CANCEL
    }

    private func runCase(route: String, pre: Bool, trial: Int) throws {
        let state = E2State()
        E2DelayProtocol.install(state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [E2DelayProtocol.self]
        config.urlCache = nil
        let url = try XCTUnwrap(URL(string: "https://f09e2.invalid/bytes"))
        let stream = HTTPStream(url: url, headers: [:], configuration: config)
        let cancel = makeCancel(stream, beforeRegistration: pre)
        let worker = DispatchQueue(label: "g0.f09e2.worker")
        let command = DispatchQueue(label: "g0.f09e2.command")
        let marker = DispatchSemaphore(value: 0)
        let commandDone = DispatchSemaphore(value: 0)
        let candidate = ProcessInfo.processInfo.environment["G0_FINITE_MODE"] == "candidate"
        var trigger = DispatchTime.now().uptimeNanoseconds

        worker.async {
            var buffer = [UInt8](repeating: 0, count: 32)
            let code: Int32
            if route == "avio" {
                if let transport = HTTPTransport(stream: stream), let ctx = transport.context {
                    code = buffer.withUnsafeMutableBufferPointer { avio_read(ctx, $0.baseAddress!, 32) }
                    transport.close() // FFmpeg owner stays on this queue.
                } else { code = Int32.min }
            } else {
                code = Int32(buffer.withUnsafeMutableBufferPointer {
                    stream.read(into: $0.baseAddress!, count: 32)
                })
            }
            state.finish(code: code, error: stream.hasError)
        }
        worker.async {
            state.markQueue()
            marker.signal()
        }

        if !pre {
            guard state.started.wait(timeout: .now() + .seconds(5)) == .success else {
                XCTFail("request did not start")
                _ = marker.wait(timeout: .now() + .seconds(8))
                return
            }
            trigger = DispatchTime.now().uptimeNanoseconds
            command.async {
                let start = DispatchTime.now().uptimeNanoseconds
                cancel()
                state.markCommand(start: start)
                commandDone.signal()
            }
        } else {
            // For candidate, makeCancel cancelled the token before registration.
            state.markCommand(start: trigger)
            commandDone.signal()
        }

        let commandOK = commandDone.wait(timeout: .now() + .seconds(8)) == .success
        let queueOK = marker.wait(timeout: .now() + .seconds(8)) == .success
        let s = state.snapshot()
        func ms(_ end: UInt64) -> String {
            guard end >= trigger, end > 0 else { return "na" }
            return String(format: "%.3f", Double(end - trigger) / 1_000_000)
        }
        let within = queueOK && s.marker >= trigger && s.marker - trigger < 1_000_000_000
        print("G0_F09E2_CASE route=\(route) pre=\(pre) trial=\(trial) requests=\(s.requests) stopCallbacks=\(s.stops) delivered=\(s.delivered) code=\(s.code) error=\(s.error) commandOK=\(commandOK) queueOK=\(queueOK) cancelCallMs=\(String(format: "%.3f", Double(s.commandDuration)/1_000_000)) readExitMs=\(ms(s.exit)) queueMs=\(ms(s.marker)) within1s=\(within)")
        XCTAssertTrue(commandOK)
        XCTAssertTrue(queueOK)
        if candidate {
            XCTAssertEqual(s.code, route == "avio" ? -5 : 0)
            XCTAssertTrue(s.error)
            if pre { XCTAssertEqual(s.requests, 0) }
            else { XCTAssertEqual(s.requests, 1); XCTAssertTrue(within, "retain original <1s queue-release gate") }
        } else {
            XCTAssertEqual(s.code, 32)
            XCTAssertFalse(s.error)
            XCTAssertEqual(s.requests, 1)
        }
    }

    func testFiniteCancelMatrix() throws {
        for route in ["stream", "avio"] {
            try runCase(route: route, pre: true, trial: 0)
            for trial in 1...3 {
                try runCase(route: route, pre: false, trial: trial)
            }
        }
        print("G0_F09E2_SUMMARY profiles=8 serverDelayMs=2000")
    }
}

private final class E2State: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var requests = 0
    private var stops = 0
    private var delivered = 0
    private var code: Int32 = Int32.min
    private var error = false
    private var exit: UInt64 = 0
    private var marker: UInt64 = 0
    private var commandDuration: UInt64 = 0
    func begin() { lock.lock(); requests += 1; lock.unlock(); started.signal() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func deliver() { lock.lock(); delivered += 1; lock.unlock() }
    func finish(code: Int32, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.code = code; self.error = error; exit = DispatchTime.now().uptimeNanoseconds
    }
    func markQueue() { lock.lock(); marker = DispatchTime.now().uptimeNanoseconds; lock.unlock() }
    func markCommand(start: UInt64) {
        lock.lock(); commandDuration = DispatchTime.now().uptimeNanoseconds - start; lock.unlock()
    }
    func snapshot() -> (requests: Int, stops: Int, delivered: Int, code: Int32, error: Bool, exit: UInt64, marker: UInt64, commandDuration: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stops, delivered, code, error, exit, marker, commandDuration)
    }
}

private final class E2DelayProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var current: E2State?
    private let lock = NSRecursiveLock()
    private var state: E2State?
    private var stopped = false

    static func install(_ state: E2State) {
        stateLock.lock(); current = state; stateLock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09e2.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.stateLock.lock(); let s = Self.current; Self.stateLock.unlock()
        lock.lock(); state = s; lock.unlock()
        s?.begin()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.sendResponse()
        }
    }
    private func sendResponse() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-63/64", "Content-Length": "64"]) else { return }
        state?.deliver()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((0..<64).map { UInt8($0) }))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; state?.stop()
    }
}
