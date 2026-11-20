import Foundation
import XCTest
@testable import ApoloEngine

final class LiveResilienceTests: XCTestCase {
    func testDecoderCallbacksAreFencedByEpochAndRoute() {
        let current: UInt64 = 42
        XCTAssertTrue(ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: current,
            engineEpoch: current,
            route: .libavcodec
        ))
        XCTAssertFalse(ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: current - 1,
            engineEpoch: current,
            route: .libavcodec
        ))
        XCTAssertFalse(ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: current,
            engineEpoch: current,
            route: .avPlayer
        ))
        // loadEpoch is wrapping; an old event from the previous epoch cannot
        // be attributed to a fresh session at zero.
        XCTAssertFalse(ApoloEngine.acceptsDecoderCallback(
            callbackEpoch: UInt64.max,
            engineEpoch: 0,
            route: .libavcodec
        ))
    }

    func testRetryBudgetResetsOnlyAfter60SecondsOfPlaying() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(LiveRetryPolicy.shouldResetBudget(
            playingSince: nil, now: now
        ))
        XCTAssertFalse(LiveRetryPolicy.shouldResetBudget(
            playingSince: now.addingTimeInterval(-59.9), now: now
        ))
        XCTAssertTrue(LiveRetryPolicy.shouldResetBudget(
            playingSince: now.addingTimeInterval(-60), now: now
        ))
        XCTAssertTrue(LiveRetryPolicy.shouldResetBudget(
            playingSince: now.addingTimeInterval(-600), now: now
        ))
        for attempt in 1...5 {
            XCTAssertEqual(
                LiveRetryPolicy.delay(forAttempt: attempt),
                attempt <= 3 ? TimeInterval(1 << (attempt - 1)) : nil
            )
        }
    }

    func testSeveralMegabytesThroughFixedSizeRingKeepOrder() {
        let buffer = LiveAudioBuffer(capacity: 4_096)
        var expected = [UInt8]()
        var totalWritten = 0
        var totalRead = 0

        func consume(_ wanted: Int) {
            let amount = min(wanted, buffer.bufferedBytes)
            guard amount > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: amount)
            let count = bytes.withUnsafeMutableBufferPointer {
                buffer.read(into: $0.baseAddress!, count: amount, timeout: 0)
            }
            XCTAssertEqual(count, amount)
            XCTAssertEqual(bytes, Array(expected.prefix(amount)))
            expected.removeFirst(amount)
            totalRead += count
        }

        // More than 3 MiB of traffic over a 4 KiB ring. No fixture/network
        // responses or unbounded arrays need to be retained by the engine.
        for index in 0..<12_000 {
            let size = 96 + ((index * 37) % 512)
            let payload = (0..<size).map {
                UInt8(truncatingIfNeeded: index + $0)
            }
            while buffer.bufferedBytes + size > buffer.capacity {
                consume(67 + (index % 241))
            }
            XCTAssertTrue(buffer.append(Data(payload)))
            expected.append(contentsOf: payload)
            totalWritten += size
            if index.isMultiple(of: 3) {
                consume(1 + ((index * 7) % 421))
            }
            XCTAssertLessThanOrEqual(buffer.bufferedBytes, buffer.capacity)
            XCTAssertEqual(buffer.bufferedBytes, expected.count)
        }
        while buffer.bufferedBytes > 0 { consume(257) }
        XCTAssertGreaterThan(totalWritten, 3 * 1_024 * 1_024)
        XCTAssertEqual(totalWritten, totalRead)
        XCTAssertTrue(expected.isEmpty)
        XCTAssertEqual(buffer.bufferedBytes, 0)
        XCTAssertEqual(buffer.capacity, 4_096)
        buffer.close()
    }

    func testActualLibavHostLoadsWithItsAssignedEpoch() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "tone", withExtension: "flac",
            subdirectory: "Fixtures"
        ))
        let started = expectation(description: "loading callback with epoch")
        let host = LibavcodecAudioHost(
            onState: { state, epoch in
                if state == .loading && epoch == 71 { started.fulfill() }
            },
            onTime: { _, _ in },
            onTrackChange: { _, _ in }
        )
        host.load(url: url, httpHeaders: [:], epoch: 71)
        wait(for: [started], timeout: 8)
        host.stop()
    }
}
