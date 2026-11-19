import Foundation
import XCTest
@testable import ApoloEngine

final class LiveRetryTests: XCTestCase {
    func testRetryPolicyHasBoundedBackoff() {
        XCTAssertNil(LiveRetryPolicy.delay(forAttempt: 0))
        XCTAssertEqual(LiveRetryPolicy.delay(forAttempt: 1), 1)
        XCTAssertEqual(LiveRetryPolicy.delay(forAttempt: 2), 2)
        XCTAssertEqual(LiveRetryPolicy.delay(forAttempt: 3), 4)
        XCTAssertNil(LiveRetryPolicy.delay(forAttempt: 4))
        XCTAssertNil(LiveRetryPolicy.delay(forAttempt: 100))
    }

    func testCancelledTokenStopsLateRegistration() {
        let token = LiveStreamCancellation()
        token.cancel()

        let stream = LiveHTTPStream(
            url: URL(string: "https://station.example/stream")!,
            headers: [:]
        )
        token.register(stream)
        stream.start()

        var bytes = [UInt8](repeating: 0, count: 4)
        let start = Date()
        let read = bytes.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 4)
        }
        XCTAssertEqual(read, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testCancelWakesReadWithoutWaitingForNetworkTimeout() {
        let token = LiveStreamCancellation()
        let stream = LiveHTTPStream(
            url: URL(string: "https://station.example/stream")!,
            headers: [:]
        )
        token.register(stream)

        let started = expectation(description: "reader started")
        let finished = expectation(description: "reader woke")
        let results = ReadResult()
        DispatchQueue.global(qos: .userInitiated).async {
            started.fulfill()
            var bytes = [UInt8](repeating: 0, count: 4)
            let count = bytes.withUnsafeMutableBufferPointer {
                stream.read(into: $0.baseAddress!, count: 4)
            }
            results.store(count)
            finished.fulfill()
        }

        wait(for: [started], timeout: 1)
        Thread.sleep(forTimeInterval: 0.05)
        let start = Date()
        token.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(results.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testTerminalHTTPStatusIsRecordedWithoutSourceURL() {
        let token = LiveStreamCancellation()
        token.recordHTTPStatus(503)
        XCTAssertNil(token.terminalHTTPStatus)
        token.recordHTTPStatus(403)
        XCTAssertEqual(token.terminalHTTPStatus, 403)
        token.recordHTTPStatus(401)
        XCTAssertEqual(token.terminalHTTPStatus, 401)
        token.recordHTTPStatus(200)
        XCTAssertNil(token.terminalHTTPStatus)
    }
}

private final class ReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    func store(_ count: Int) {
        lock.lock()
        value = count
        lock.unlock()
    }

    var count: Int? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
