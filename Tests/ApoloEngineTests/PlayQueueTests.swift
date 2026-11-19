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

    func testReplaceUpdatesQueuedTrack() {
        var queue = PlayQueue()
        let a = track("a")
        queue.enqueue(a)

        var updated = a
        updated.replayGainDB = -7
        updated.effectiveGainDB = 3

        XCTAssertTrue(queue.replace(a, with: updated))
        XCTAssertEqual(queue.upcoming.first?.replayGainDB, -7)
        XCTAssertEqual(queue.upcoming.first?.effectiveGainDB, 3)
    }

    func testTrackEqualityIgnoresProbedFields() {
        let a = track("a")
        var b = a
        b.replayGainDB = -7
        b.effectiveGainDB = 3
        XCTAssertEqual(a, b)
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
