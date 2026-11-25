import Foundation
import XCTest
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

final class G0F09LiveCancelTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    func testCancellationMatrix() throws {
        for mode in ["preRegister", "blocked", "buffered"] {
            for route in ["stream", "avio"] {
                for trial in 1...3 {
                    try runCase(mode: mode, route: route, trial: trial)
                }
            }
        }
        print("G0_F09F2_SUMMARY profiles=18")
    }

    func testRetryAndTerminalPolicy() {
        let token = LiveStreamCancellation()
        for status in [401,403,404,410,429,500,503,200,206] {
            token.recordHTTPStatus(status)
            let expected: Int? = [401,403,404,410].contains(status) ? status : nil
            XCTAssertEqual(token.terminalHTTPStatus, expected)
            print("G0_F09F2_STATUS status=\(status) terminal=\(token.terminalHTTPStatus ?? 0)")
        }
        for attempt in [-1,0,1,2,3,4,100] {
            let expected: TimeInterval? = [1:1,2:2,3:4][attempt]
            XCTAssertEqual(LiveRetryPolicy.delay(forAttempt: attempt), expected)
            print("G0_F09F2_RETRY attempt=\(attempt) delay=\(String(describing: LiveRetryPolicy.delay(forAttempt: attempt)))")
        }
    }

    private func runCase(mode: String, route: String, trial: Int) throws {
        let key = "\(mode)-\(route)-\(trial)"
        let state = F09F2State(mode: mode)
        F09F2Protocol.install(key, state)
        defer { F09F2Protocol.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [F09F2Protocol.self]
        config.urlCache = nil
        let url = try XCTUnwrap(URL(string: "https://f09f2.invalid/" + key))
        let stream = LiveHTTPStream(url: url, headers: [:], capacity: 128, configuration: config)
        let token = LiveStreamCancellation()
        if mode == "preRegister" { token.cancel() }
        token.register(stream)
        let transport: LiveHTTPTransport?
        if route == "avio" {
            transport = try XCTUnwrap(LiveHTTPTransport(stream: stream))
        } else {
            transport = nil
            stream.start()
        }
        if mode != "preRegister" {
            guard state.started.wait(timeout: .now() + .seconds(5)) == .success else {
                token.cancel(); transport?.close(); XCTFail("request did not start"); return
            }
        }
        if mode == "buffered" {
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while stream.bufferedBytes != 16 && !stream.hasError && DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertEqual(stream.bufferedBytes, 16)
        }
        let bufferedBefore = stream.bufferedBytes
        let worker = DispatchQueue(label: "g0.f09f2.worker")
        if mode != "blocked" {
            state.mark("trigger")
            token.cancel()
            state.mark("cancelReturn")
        }
        worker.async {
            state.entered.signal()
            var codes = [Int32]()
            var payload = Data()
            for _ in 0..<4 {
                var bytes = [UInt8](repeating: 0, count: 64)
                let rc = bytes.withUnsafeMutableBufferPointer { ptr -> Int32 in
                    if let ctx = transport?.context { return avio_read(ctx, ptr.baseAddress!, 64) }
                    return Int32(stream.read(into: ptr.baseAddress!, count: 64))
                }
                codes.append(rc)
                if rc > 0 { payload.append(contentsOf: bytes.prefix(Int(rc))) }
                if codes.count >= 2 && codes.suffix(2).allSatisfy({ $0 <= 0 }) { break }
            }
            state.mark("readReturn")
            state.finish(codes, payload, stream.hasError, stream.bufferedBytes)
            transport?.close()
            stream.close()
            state.mark("closeReturn")
        }
        worker.async {
            state.mark("queue")
            state.done.signal()
        }
        if mode == "blocked" {
            XCTAssertEqual(state.entered.wait(timeout: .now() + .seconds(5)), .success)
            Thread.sleep(forTimeInterval: 0.05)
            state.mark("trigger")
            token.cancel()
            state.mark("cancelReturn")
        }
        let queueOK = state.done.wait(timeout: .now() + .seconds(8)) == .success
        let stopObserved: Bool
        if mode == "preRegister" {
            Thread.sleep(forTimeInterval: 0.05)
            stopObserved = false
        } else {
            stopObserved = state.stopSeen.wait(timeout: .now() + .milliseconds(500)) == .success
        }
        let s = state.snapshot()
        let trigger = s.times["trigger"] ?? 0
        func ms(_ name: String) -> String {
            guard let t = s.times[name], t >= trigger else { return "na" }
            return String(format: "%.3f", Double(t - trigger) / 1_000_000)
        }
        let queueTime = s.times["queue"] ?? UInt64.max
        let within = queueOK && queueTime >= trigger && queueTime-trigger < 1_000_000_000
        print("G0_F09F2_CASE key=\(key) requests=\(s.requests) stops=\(s.stops) stopObserved=\(stopObserved) bufferedBefore=\(bufferedBefore) bufferedAfter=\(s.buffered) codes=\(s.codes) bytes=\(s.payload.count) error=\(s.error) queueOK=\(queueOK) cancelMs=\(ms("cancelReturn")) readMs=\(ms("readReturn")) closeMs=\(ms("closeReturn")) queueMs=\(ms("queue")) stopMs=\(ms("stop")) within1s=\(within)")
        XCTAssertTrue(queueOK)
        // Separate explicit laboratory target from historical 8-second XCTest gate.
        XCTAssertTrue(within, "live worker queue release target <1s")
        XCTAssertEqual(s.requests, mode == "preRegister" ? 0 : 1)
        let terminal: Int32 = route == "avio" ? -5 : 0
        XCTAssertEqual(Array(s.codes.suffix(2)), [terminal, terminal])
        XCTAssertEqual(s.payload, mode == "buffered" ? Data((0..<16).map { UInt8($0) }) : Data())
        XCTAssertFalse(s.error)
        XCTAssertEqual(s.buffered, 0)
    }
}

private final class F09F2State: @unchecked Sendable {
    let mode: String
    let started = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let stopSeen = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var times: [String: UInt64] = [:]
    private var requests = 0
    private var stops = 0
    private var codes = [Int32]()
    private var payload = Data()
    private var error = false
    private var buffered = 0
    init(mode: String) { self.mode = mode }
    func begin() { lock.lock(); requests += 1; lock.unlock(); started.signal() }
    func stop() { lock.lock(); stops += 1; times["stop"] = DispatchTime.now().uptimeNanoseconds; lock.unlock(); stopSeen.signal() }
    func mark(_ name: String) { lock.lock(); times[name] = DispatchTime.now().uptimeNanoseconds; lock.unlock() }
    func finish(_ codes: [Int32], _ payload: Data, _ error: Bool, _ buffered: Int) {
        lock.lock(); defer { lock.unlock() }
        self.codes = codes; self.payload = payload; self.error = error; self.buffered = buffered
    }
    func snapshot() -> (times: [String: UInt64], requests: Int, stops: Int, codes: [Int32], payload: Data, error: Bool, buffered: Int) {
        lock.lock(); defer { lock.unlock() }
        return (times,requests,stops,codes,payload,error,buffered)
    }
}

private final class F09F2Protocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String:F09F2State] = [:]
    static func install(_ key: String, _ state: F09F2State) { lock.lock(); states[key] = state; lock.unlock() }
    static func remove(_ key: String) { lock.lock(); states.removeValue(forKey: key); lock.unlock() }
    private func current() -> F09F2State? {
        guard let key = request.url?.lastPathComponent else { return nil }
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.states[key]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09f2.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let s = current(), let url = request.url else { return }
        if s.mode == "buffered", let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"audio/mpeg"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((0..<16).map { UInt8($0) }))
        }
        s.begin()
        // No completion: explicit caller cancellation is the only terminal event.
    }
    override func stopLoading() { current()?.stop() }
}
