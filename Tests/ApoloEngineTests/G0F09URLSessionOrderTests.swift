import Foundation
import Network
import XCTest
@testable import ApoloEngine

private let f09f6Payload = Data((0..<16).map(UInt8.init))

final class G0F09URLSessionOrderTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func until(_ predicate: () -> Bool, seconds: Double = 5) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while !predicate(), DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    func testDirectDelegateVersusLiveBuffer() throws {
        var total = 0
        for transport in ["mock", "tcp"] {
            for mode in ["immediate", "confirmed", "clean"] {
                for route in ["delegate", "stream"] {
                    for trial in 1...3 {
                        try runCase(transport: transport, mode: mode, route: route, trial: trial)
                        total += 1
                    }
                }
            }
        }
        print("G0_F09F6_SUMMARY profiles=\(total)")
        XCTAssertEqual(total, 36)
    }

    private func runCase(transport: String, mode: String, route: String, trial: Int) throws {
        let key = "\(transport)-\(mode)-\(route)-\(trial)"
        let state = F09F6State(mode: mode)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        var listener: NWListener?
        var server: F09F6Server?
        let url: URL
        if transport == "mock" {
            F09F6Protocol.install(key, state)
            config.protocolClasses = [F09F6Protocol.self]
            url = try XCTUnwrap(URL(string: "https://f09f6.invalid/" + key))
        } else {
            let local = F09F6Server(state: state)
            server = local
            let l = try NWListener(using: .tcp, on: .any)
            listener = l
            l.stateUpdateHandler = { status in
                if case .ready = status { local.ready.signal() }
            }
            l.newConnectionHandler = { connection in local.accept(connection) }
            l.start(queue: local.queue)
            guard local.ready.wait(timeout: .now() + .seconds(5)) == .success else {
                l.cancel()
                XCTFail("listener not ready")
                return
            }
            url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(l.port?.rawValue))/" + key))
        }
        defer {
            state.release.signal()
            listener?.cancel()
            server?.close()
            F09F6Protocol.remove(key)
        }

        let delegate = F09F6Delegate()
        var session: URLSession?
        var stream: LiveHTTPStream?
        if route == "delegate" {
            let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            session = s
            var request = URLRequest(url: url)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
            s.dataTask(with: request).resume()
        } else {
            let s = LiveHTTPStream(url: url, headers: [:], capacity: 128,
                                   configuration: config, onHTTPStatus: { state.status($0) })
            stream = s
            s.start()
        }
        defer { session?.invalidateAndCancel(); stream?.close() }
        guard state.sent.wait(timeout: .now() + .seconds(5)) == .success else {
            XCTFail("sender did not submit response")
            return
        }
        func receivedCount() -> Int {
            stream?.bufferedBytes ?? delegate.snapshot().data.count
        }
        var confirmed = false
        var before = receivedCount()
        if mode == "confirmed" {
            confirmed = until { receivedCount() == f09f6Payload.count }
            before = receivedCount()
            XCTAssertTrue(confirmed, "confirm delegate/ring reception before disconnect")
            state.release.signal()
        }
        let terminal = until { stream?.hasError ?? delegate.snapshot().completed }
        let after = receivedCount()
        var got = Data()
        var end = -999
        if let stream, terminal {
            var bytes = [UInt8](repeating: 0, count: 64)
            let n = bytes.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 64) }
            got = Data(bytes.prefix(n))
            end = bytes.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 64) }
        } else if route == "delegate" {
            got = delegate.snapshot().data
        }
        let d = delegate.snapshot()
        let s = state.snapshot()
        print("G0_F09F6_CASE key=\(key) requests=\(s.requests) submitted=\(s.submitted) senderError=\(s.senderError) confirmed=\(confirmed) before=\(before) after=\(after) terminal=\(terminal) bytes=\(got.count) exact=\(got == f09f6Payload) hex=\(got.map { String(format: "%02x", $0) }.joined()) end=\(end) status=\(route == "delegate" ? d.status : s.status) delegateError=\(d.error) events=\(d.events.joined(separator: ",")) streamError=\(stream?.hasError ?? false)")
        XCTAssertTrue(terminal)
        XCTAssertEqual(s.submitted, 16)
        XCTAssertGreaterThanOrEqual(s.requests, 1)
        if mode == "immediate" {
            // A sender callback is not proof of receiver delivery.
            XCTAssertTrue(got.count <= f09f6Payload.count && got == f09f6Payload.prefix(got.count))
        } else {
            XCTAssertEqual(got, f09f6Payload)
        }
        if route == "stream" { XCTAssertEqual(end, 0) }
        if route == "delegate" {
            XCTAssertTrue(d.completed)
            if mode == "clean" { XCTAssertEqual(d.error, 0) }
            else { XCTAssertNotEqual(d.error, 0) }
        }
    }
}

private final class F09F6State: @unchecked Sendable {
    let mode: String
    let sent = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var requests = 0
    private var submitted = 0
    private var statusCode = 0
    private var senderError = false
    init(mode: String) { self.mode = mode }
    func begin() { lock.lock(); requests += 1; lock.unlock() }
    func didSubmit(error: Bool = false) {
        lock.lock(); submitted = 16; senderError = error; lock.unlock()
        sent.signal()
    }
    func status(_ code: Int) { lock.lock(); statusCode = code; lock.unlock() }
    func snapshot() -> (requests: Int, submitted: Int, status: Int, senderError: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (requests, submitted, statusCode, senderError)
    }
}

private final class F09F6Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status = 0
    private var error = 0
    private var completed = false
    private var events = [String]()
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        events.append("response")
        lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        self.data.append(data)
        events.append("data\(data.count)")
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        self.error = (error as NSError?)?.code ?? 0
        completed = true
        events.append("complete")
        lock.unlock()
    }
    func snapshot() -> (data: Data, status: Int, error: Int, completed: Bool, events: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (data, status, error, completed, events)
    }
}

private final class F09F6Protocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String:F09F6State] = [:]
    private let instanceLock = NSRecursiveLock()
    private var stopped = false
    static func install(_ key: String, _ state: F09F6State) {
        lock.lock(); states[key] = state; lock.unlock()
    }
    static func remove(_ key: String) { lock.lock(); states.removeValue(forKey: key); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09f6.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); let s = Self.states[url.lastPathComponent]; Self.lock.unlock()
        guard let s, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type":"audio/mpeg"]) else { return }
        instanceLock.lock(); defer { instanceLock.unlock() }
        s.begin()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: f09f6Payload)
        s.didSubmit()
        if s.mode == "clean" { client?.urlProtocolDidFinishLoading(self) }
        else if s.mode == "immediate" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else {
            DispatchQueue.global().async { [weak self] in
                guard s.release.wait(timeout: .now() + .seconds(10)) == .success, let self else { return }
                self.instanceLock.lock(); defer { self.instanceLock.unlock() }
                if !self.stopped { self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
            }
        }
    }
    override func stopLoading() { instanceLock.lock(); stopped = true; instanceLock.unlock() }
}

private final class F09F6Server: @unchecked Sendable {
    let queue = DispatchQueue(label: "g0.f09f6.tcp")
    let ready = DispatchSemaphore(value: 0)
    private let state: F09F6State
    private let lock = NSLock()
    private var connections = [NWConnection]()
    init(state: F09F6State) { self.state = state }
    func accept(_ c: NWConnection) {
        lock.lock(); connections.append(c); lock.unlock()
        c.stateUpdateHandler = { [weak self, weak c] status in
            guard case .ready = status, let self, let c else { return }
            self.receive(c, Data())
        }
        c.start(queue: queue)
    }
    private func receive(_ c: NWConnection, _ prefix: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak c] data, _, complete, error in
            guard let self, let c, error == nil, let data else { return }
            let request = prefix + data
            if request.range(of: Data([13,10,13,10])) == nil {
                if !complete && request.count < 16384 { self.receive(c, request) }
                return
            }
            self.state.begin()
            // An incomplete Content-Length followed by graceful TCP EOF
            // models truncated HTTP, not a forced TCP RST.
            let length = self.state.mode == "clean" ? 16 : 32
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8) + f09f6Payload
            c.send(content: response, completion: .contentProcessed { [weak self, weak c] error in
                guard let self, let c else { return }
                self.state.didSubmit(error: error != nil)
                if self.state.mode == "confirmed" {
                    DispatchQueue.global().async { [weak self, weak c] in
                        guard let self, let c, self.state.release.wait(timeout: .now() + .seconds(10)) == .success else { return }
                        self.finish(c)
                    }
                } else { self.finish(c) }
            })
        }
    }
    private func finish(_ c: NWConnection) {
        c.send(content: nil, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in })
    }
    func close() {
        lock.lock(); let values = connections; lock.unlock()
        for c in values { c.cancel() }
    }
}
