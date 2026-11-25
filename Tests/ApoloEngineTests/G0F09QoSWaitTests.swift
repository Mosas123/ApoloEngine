import Foundation
import XCTest
@testable import ApoloEngine

final class G0F09QoSWaitTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["G0_F09E22_ENABLED"] == "1")
    }

    private func makeCancel(_ stream: HTTPStream) -> @Sendable () -> Void {
        return {} // G0_E22_CANCEL
    }

    func testQoSWaitMatrix() throws {
        // Alternate order on the second repetition to reduce warm-up bias.
        let profiles = ["global-user", "global-default", "serial-user", "serial-default"]
        for trial in 1...2 {
            let ordered = trial == 1 ? profiles : Array(profiles.reversed())
            let waits = trial == 1 ? ["xctest", "semaphore"] : ["semaphore", "xctest"]
            for profile in ordered {
                for waiter in waits {
                    try runCase(profile: profile, waiter: waiter, trial: trial)
                }
            }
        }
        print("G0_F09E22_SUMMARY profiles=16")
    }

    private func runCase(profile: String, waiter: String, trial: Int) throws {
        let key = "\(profile)-\(waiter)-\(trial)"
        let state = E22State()
        E22HangProtocol.install(key, state)
        defer { E22HangProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [E22HangProtocol.self]
        configuration.urlCache = nil
        let url = try XCTUnwrap(URL(string: "https://f09e22.invalid/" + key))
        let stream = HTTPStream(url: url, headers: [:], configuration: configuration)
        let cancel = makeCancel(stream)
        let finished = expectation(description: key)
        let user = profile.hasSuffix("-user")
        let qos: DispatchQoS = user ? .userInitiated : .default
        let worker = profile.hasPrefix("global") ? DispatchQueue.global(qos: qos.qosClass) :
            DispatchQueue(label: "g0.f09e22." + key, qos: qos)
        print("G0_F09E22_BEGIN key=\(key)")
        worker.async {
            state.mark("workerEnter")
            var bytes = [UInt8](repeating: 0, count: 32)
            let rc = bytes.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 32) }
            state.finish(rc, stream.hasError)
            state.mark("beforeFulfill")
            if waiter == "xctest" { finished.fulfill() }
            state.mark("afterFulfill")
            state.done.signal()
        }
        guard state.started.wait(timeout: .now() + .seconds(5)) == .success else {
            cancel()
            if waiter == "xctest" { wait(for: [finished], timeout: 8) }
            else { finished.fulfill(); wait(for: [finished], timeout: 1); _ = state.done.wait(timeout: .now() + .seconds(8)) }
            XCTFail("request did not start")
            return
        }
        let wall = Date()
        state.mark("trigger")
        cancel()
        state.mark("cancelReturn")
        var completed = false
        if waiter == "xctest" {
            // Keep historical wait timeout and main test-thread cancellation.
            wait(for: [finished], timeout: 2)
            state.mark("waitReturn")
            completed = state.done.wait(timeout: .now() + .seconds(8)) == .success
        } else {
            completed = state.done.wait(timeout: .now() + .seconds(2)) == .success
            state.mark("waitReturn")
            if !completed { completed = state.done.wait(timeout: .now() + .seconds(8)) == .success }
            // Balance the unused XCTest expectation outside the measured interval.
            finished.fulfill()
            wait(for: [finished], timeout: 1)
        }
        let wallMs = Date().timeIntervalSince(wall) * 1000
        let stopObserved = state.stopSeen.wait(timeout: .now() + .milliseconds(500)) == .success
        let snapshot = state.snapshot()
        let trigger = snapshot.times["trigger"] ?? 0
        func ms(_ name: String) -> String {
            guard let t = snapshot.times[name], t >= trigger else { return "na" }
            return String(format: "%.3f", Double(t - trigger) / 1_000_000)
        }
        func within(_ name: String) -> Bool {
            guard let t = snapshot.times[name], t >= trigger else { return false }
            return t - trigger < 1_000_000_000
        }
        print("G0_F09E22_CASE key=\(key) requests=\(snapshot.requests) stops=\(snapshot.stops) stopObserved=\(stopObserved) rc=\(snapshot.rc) error=\(snapshot.error) completed=\(completed) cancelMs=\(ms("cancelReturn")) workerMs=\(ms("readReturn")) beforeFulfillMs=\(ms("beforeFulfill")) afterFulfillMs=\(ms("afterFulfill")) waitMs=\(ms("waitReturn")) wallMs=\(String(format: "%.3f", wallMs)) stopMs=\(ms("stop")) workerWithin1s=\(within("readReturn")) waiterWithin1s=\(within("waitReturn"))")
        XCTAssertTrue(completed)
        XCTAssertEqual(snapshot.requests, 1)
        XCTAssertEqual(snapshot.rc, 0)
        XCTAssertTrue(snapshot.error)
        XCTAssertTrue(within("readReturn"), "worker <1s")
        XCTAssertTrue(within("waitReturn"), "historical waiter <1s")
    }
}

private final class E22State: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let stopSeen = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var times: [String: UInt64] = [:]
    private var requests = 0
    private var stops = 0
    private var rc = -1
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
    func finish(_ rc: Int, _ error: Bool) {
        lock.lock(); self.rc = rc; self.error = error
        times["readReturn"] = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }
    func snapshot() -> (times: [String: UInt64], requests: Int, stops: Int, rc: Int, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (times, requests, stops, rc, error)
    }
}

private final class E22HangProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: E22State] = [:]
    static func install(_ key: String, _ state: E22State) {
        lock.lock(); states[key] = state; lock.unlock()
    }
    static func remove(_ key: String) {
        lock.lock(); states.removeValue(forKey: key); lock.unlock()
    }
    private func current() -> E22State? {
        guard let key = request.url?.lastPathComponent else { return nil }
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.states[key]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09e22.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { current()?.begin() }
    override func stopLoading() { current()?.stop() }
}
