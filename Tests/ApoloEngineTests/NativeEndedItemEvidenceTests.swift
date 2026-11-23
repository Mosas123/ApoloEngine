import XCTest
@testable import ApoloEngine

final class NativeEndedItemEvidenceTests: XCTestCase {
    func testEndedItemDoesNotDependOnQueueCurrentItem() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: 183.68, endedDuration: 183.712,
            lastObservedPosition: 183.42, lastObservedDuration: 183.712,
            observationMatchesEndedItem: true
        )
        XCTAssertEqual(snapshot.position ?? -1, 183.68, accuracy: 0.001)
        XCTAssertEqual(snapshot.duration ?? -1, 183.712, accuracy: 0.001)
        XCTAssertEqual(snapshot.origin, .endedItem)
    }

    func testRemovedCurrentItemReportingZeroUsesItemMatchedTime() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: 0, endedDuration: nil,
            lastObservedPosition: 183.54, lastObservedDuration: 183.712,
            observationMatchesEndedItem: true
        )
        XCTAssertEqual(snapshot.position ?? -1, 183.54, accuracy: 0.001)
        XCTAssertEqual(snapshot.duration ?? -1, 183.712, accuracy: 0.001)
        XCTAssertEqual(snapshot.origin, .lastObserved)
    }

    func testMissingTimeIsUnknownNotInventedZero() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: nil, endedDuration: nil,
            lastObservedPosition: nil, lastObservedDuration: nil,
            observationMatchesEndedItem: false
        )
        XCTAssertNil(snapshot.position)
        XCTAssertNil(snapshot.duration)
        XCTAssertEqual(snapshot.origin, .unknown)
    }

    func testStalePreviousItemCannotContaminateNewTrackEnd() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: nil, endedDuration: nil,
            lastObservedPosition: 169.176, lastObservedDuration: 169.176,
            observationMatchesEndedItem: false
        )
        XCTAssertNil(snapshot.position)
        XCTAssertNil(snapshot.duration)
        XCTAssertEqual(snapshot.origin, .unknown)
    }

    func testItemProvidedZeroIsKeptWhenNoReliableFallbackExists() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: 0, endedDuration: 184.0,
            lastObservedPosition: 180, lastObservedDuration: 184.0,
            observationMatchesEndedItem: false
        )
        XCTAssertEqual(snapshot.position, 0)
        XCTAssertEqual(snapshot.duration, 184.0)
        XCTAssertEqual(snapshot.origin, .endedItem)
    }

    func testNaNInfinityNegativeTimesDoNotLeakIntoMetrics() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: .nan, endedDuration: .infinity,
            lastObservedPosition: -1, lastObservedDuration: 0,
            observationMatchesEndedItem: true
        )
        XCTAssertNil(snapshot.position)
        XCTAssertNil(snapshot.duration)
        XCTAssertEqual(snapshot.origin, .unknown)
    }

    func testLegitimatelyEarlyItemEndIsNotAutoDeclaredNormal() {
        let snapshot = NativeEndedItemEvidence.make(
            endedPosition: 162.5, endedDuration: 183.7,
            lastObservedPosition: 162.3, lastObservedDuration: 183.7,
            observationMatchesEndedItem: true
        )
        XCTAssertEqual(snapshot.position ?? -1, 162.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.duration ?? -1, 183.7, accuracy: 0.001)
        // The consumer still decides what to do with an early EOF.
        // The engine must report measured evidence, not fake completion.
    }
}
