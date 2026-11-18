import XCTest
@testable import ApoloEngine

final class PlayQueueTests: XCTestCase {
    private func track(_ name: String) -> ApoloTrack {
        ApoloTrack(url: URL(fileURLWithPath: "/tmp/\(name).mp3"))
    }

    func testAdvanceAndPrevious() {
        var queue = PlayQueue()
        let a = track("a")
        let b = track("b")
        let c = track("c")

        queue.start(a)
        queue.enqueue(b)
        queue.enqueue(c)

        XCTAssertEqual(queue.current, a)
        XCTAssertEqual(queue.upcoming, [b, c])

        XCTAssertEqual(queue.advance(), b)
        XCTAssertEqual(queue.history, [a])

        XCTAssertEqual(queue.advance(), c)
        XCTAssertEqual(queue.history, [a, b])

        XCTAssertEqual(queue.previous(), b)
        XCTAssertEqual(queue.upcoming, [c])
        XCTAssertEqual(queue.history, [a])

        XCTAssertEqual(queue.previous(), a)
        XCTAssertEqual(queue.upcoming, [b, c])
        XCTAssertNil(queue.previous())
    }

    func testConsumeKeepsHistory() {
        var queue = PlayQueue()
        let a = track("a")
        let b = track("b")

        queue.start(a)
        queue.enqueue(b)

        XCTAssertTrue(queue.consume(b))
        XCTAssertEqual(queue.current, b)
        XCTAssertTrue(queue.upcoming.isEmpty)
        XCTAssertEqual(queue.history, [a])

        XCTAssertFalse(queue.consume(track("z")))
    }

    func testClearEmptiesEverything() {
        var queue = PlayQueue()
        queue.start(track("a"))
        queue.enqueue(track("b"))
        queue.clear()

        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.upcoming.isEmpty)
        XCTAssertTrue(queue.history.isEmpty)
    }
}
