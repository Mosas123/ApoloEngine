import Foundation
import XCTest
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

final class G0F09HangCancelTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["G0_F09E21_ENABLED"] == "1")
    }

    private func makeCancel(_ stream: HTTPStream) -> @Sendable () -> Void {
        return {} // G0_E21_CANCEL
    }

    func testHangMatrix() throws {
        for route in ["stream", "avio"] {
            for delay in [0, 50, 250] {
                for trial in 1...2 {
                    try runCase(route: route, delay: delay, trial: trial)
                }
            }
        }
        print("G0_F09E21_SUMMARY profiles=12")
    }

    private func runCase(route: String, delay: Int, trial: Int) throws {
        let state = E21State()
        let key = "\(route)-\(delay)-\(trial)"
        E21HangProtocol.install(key, state)
        defer { E21HangProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [E21HangProtocol.self]
        configuration.urlCache = nil
        let url = try XCTUnwrap(URL(string: "https://f09e21.invalid/" + key))
        let stream = HTTPStream(url: url, headers: [:], configuration: configuration)
        let cancel = makeCancel(stream)
        let worker = DispatchQueue(label: "g0.f09e21.worker")
        let command = DispatchQueue(label: "g0.f09e21.command")
        worker.async {
            var bytes = [UInt8](repeating: 0, count: 32)
            var rc: Int32 = Int32.min
            if route == "avio" {
                if let transport = HTTPTransport(stream: stream), let ctx = transport.context {
                    rc = bytes.withUnsafeMutableBufferPointer { avio_read(ctx, $0.baseAddress!, 32) }
                    state.mark("readReturn")
                    transport.close()
                    state.mark("closeReturn")
                }
            } else {
                rc = Int32(bytes.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 32) })
                state.mark("readReturn")
            }
            state.finish(rc, stream.hasError)
        }
        worker.async {
            state.mark("queue")
            state.queueDone.signal()
        }
        guard state.started.wait(timeout: .now() + .seconds(5)) == .success else {
            XCTFail("request did not start")
            cancel()
            _ = state.queueDone.wait(timeout: .now() + .seconds(8))
            return
        }
        if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1000) }
        state.mark("trigger")
        command.async {
            state.mark("cancelEnter")
            cancel()
            state.mark("cancelReturn")
            state.commandDone.signal()
        }
        let commandOK = state.commandDone.wait(timeout: .now() + .seconds(8)) == .success
        let queueOK = state.queueDone.wait(timeout: .now() + .seconds(8)) == .success
        // A late stopLoading may legitimately arrive after the worker returns.
        let stopObserved = state.stopSeen.wait(timeout: .now() + .milliseconds(500)) == .success
        let snapshot = state.snapshot()
        let trigger = snapshot.times["trigger"] ?? 0
        func delta(_ name: String) -> String {
            guard let t = snapshot.times[name], t >= trigger else { return "na" }
            return String(format: "%.3f", Double(t - trigger) / 1_000_000)
        }
        let within = queueOK && (snapshot.times["queue"] ?? UInt64.max) >= trigger &&
            (snapshot.times["queue"] ?? UInt64.max) - trigger < 1_000_000_000
        print("G0_F09E21_CASE key=\(key) triggerNs=\(trigger) requests=\(snapshot.requests) stops=\(snapshot.stops) stopObserved=\(stopObserved) code=\(snapshot.code) error=\(snapshot.error) commandOK=\(commandOK) queueOK=\(queueOK) enterMs=\(delta("cancelEnter")) cancelReturnMs=\(delta("cancelReturn")) readReturnMs=\(delta("readReturn")) closeReturnMs=\(delta("closeReturn")) queueMs=\(delta("queue")) stopMs=\(delta("stop")) within1s=\(within)")
        XCTAssertTrue(commandOK)
        XCTAssertTrue(queueOK)
        XCTAssertEqual(snapshot.requests, 1)
        XCTAssertEqual(snapshot.code, route == "avio" ? -5 : 0)
        XCTAssertTrue(snapshot.error)
        XCTAssertTrue(within, "original <1s queue-release criterion")
    }
}

private final class E21State: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let stopSeen = DispatchSemaphore(value: 0)
    let commandDone = DispatchSemaphore(value: 0)
    let queueDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var times: [String: UInt64] = [:]
    private var requests = 0
    private var stops = 0
    private var code: Int32 = Int32.min
    private var error = false
    func mark(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        times[name] = DispatchTime.now().uptimeNanoseconds
    }
    func begin() {
        lock.lock(); requests += 1; times["start"] = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        started.signal()
    }
    func stop() {
        lock.lock(); stops += 1; times["stop"] = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        stopSeen.signal()
    }
    func finish(_ code: Int32, _ error: Bool) {
        lock.lock(); self.code = code; self.error = error; lock.unlock()
    }
    func snapshot() -> (times: [String: UInt64], requests: Int, stops: Int, code: Int32, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (times, requests, stops, code, error)
    }
}

private final class E21HangProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: E21State] = [:]
    static func install(_ key: String, _ state: E21State) {
        lock.lock(); states[key] = state; lock.unlock()
    }
    static func remove(_ key: String) {
        lock.lock(); states.removeValue(forKey: key); lock.unlock()
    }
    private func current() -> E21State? {
        guard let key = request.url?.lastPathComponent else { return nil }
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.states[key]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09e21.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { current()?.begin() } // Intentionally never responds.
    override func stopLoading() { current()?.stop() }
}
