import XCTest
@testable import ApoloEngine

final class NativeClockAuditTests: XCTestCase {
    func testSteadyOneXPlaybackDoesNotInventJumps() {
        var audit = NativeClockAudit()
        for second in 0...32 {
            _ = audit.observe(
                position: Double(second), uptime: 100 + Double(second),
                playerRate: 1, motion: .playing
            )
        }
        let final = audit.finish(
            position: 33, uptime: 133, playerRate: 1, motion: .playing
        )
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.kind, .final)
        XCTAssertEqual(final?.jumpCount, 0)
        XCTAssertEqual(final?.sampledWall ?? -1, 33, accuracy: 0.001)
        XCTAssertEqual(final?.sampledMedia ?? -1, 33, accuracy: 0.001)
        XCTAssertEqual(final?.mediaExcessOverRate ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(final?.samplingGapCount, 0)
    }

    func testOneTwentyOneSecondLeapIsVisibleAndIsNotPlayedTime() {
        var audit = NativeClockAudit()
        for second in 0...30 {
            _ = audit.observe(
                position: Double(second), uptime: 200 + Double(second),
                playerRate: 1, motion: .playing
            )
        }
        // One second of real time later, the item clock jumps +22.
        let jump = audit.observe(
            position: 52, uptime: 231, playerRate: 1, motion: .playing
        )
        XCTAssertEqual(jump?.kind, .jump)
        XCTAssertEqual(jump?.jumpCount, 1)
        XCTAssertEqual(jump?.largestSingleExcess ?? -1, 21, accuracy: 0.001)
        XCTAssertEqual(jump?.mediaExcessOverRate ?? -1, 21, accuracy: 0.001)
        XCTAssertEqual(jump?.sampledWall ?? -1, 31, accuracy: 0.001)
        XCTAssertEqual(jump?.sampledMedia ?? -1, 52, accuracy: 0.001)
    }

    func testSteadyAcceleratedMediaWithoutPlayerRateIsMeasurable() {
        var audit = NativeClockAudit()
        for second in 0...25 {
            _ = audit.observe(
                position: Double(second) * 1.13,
                uptime: 500 + Double(second),
                playerRate: 1, motion: .playing
            )
        }
        let final = audit.finish(
            position: 26 * 1.13, uptime: 526,
            playerRate: 1, motion: .playing
        )
        XCTAssertEqual(final?.jumpCount, 0)
        XCTAssertEqual(final?.sampledWall ?? -1, 26, accuracy: 0.001)
        XCTAssertEqual(final?.mediaExcessOverRate ?? -1, 3.38, accuracy: 0.005)
    }

    func testExpectedNonUnitPlayerRateExplainsFasterMediaClock() {
        var audit = NativeClockAudit()
        for second in 0...15 {
            _ = audit.observe(
                position: Double(second) * 1.13,
                uptime: 500 + Double(second),
                playerRate: 1.13, motion: .playing
            )
        }
        let final = audit.finish(
            position: 16 * 1.13, uptime: 516,
            playerRate: 1.13, motion: .playing
        )
        XCTAssertEqual(final?.jumpCount, 0)
        XCTAssertEqual(final?.mediaExcessOverRate ?? -1, 0, accuracy: 0.005)
        XCTAssertGreaterThan(final?.nonUnitRateSampleCount ?? 0, 0)
    }

    func testHugeBackgroundSamplingGapIsNotDeclaredASkip() {
        var audit = NativeClockAudit()
        _ = audit.observe(position: 0, uptime: 100, playerRate: 1, motion: .playing)
        _ = audit.observe(position: 1, uptime: 101, playerRate: 1, motion: .playing)
        let sample = audit.observe(
            position: 74, uptime: 201, playerRate: 0, motion: .paused
        )
        // The 100-second gap is unresolved, NOT proof of a 73-second seek.
        XCTAssertEqual(sample?.jumpCount, 0)
        XCTAssertEqual(sample?.samplingGapCount, 1)
        XCTAssertEqual(sample?.sampledMedia ?? -1, 1, accuracy: 0.001)
    }

    func testExplicitSeekResetsJumpBaselineWithoutErasingPriorTotals() {
        var audit = NativeClockAudit()
        _ = audit.observe(position: 0, uptime: 100, playerRate: 1, motion: .playing)
        _ = audit.observe(position: 1, uptime: 101, playerRate: 1, motion: .playing)
        audit.invalidateBaseline()
        _ = audit.observe(position: 120, uptime: 101.5, playerRate: 1, motion: .playing)
        let final = audit.finish(
            position: 121, uptime: 102.5, playerRate: 1, motion: .playing
        )
        XCTAssertEqual(final?.jumpCount, 0)
        XCTAssertEqual(final?.sampledMedia ?? -1, 2, accuracy: 0.001)
    }

    func testInvalidAndOutOfOrderClocksCannotCorruptEvidence() {
        var audit = NativeClockAudit()
        XCTAssertNil(audit.observe(
            position: .nan, uptime: 100, playerRate: 1, motion: .playing
        ))
        _ = audit.observe(position: 0, uptime: 101, playerRate: 1, motion: .playing)
        XCTAssertNil(audit.observe(
            position: 1, uptime: 100.5, playerRate: 1, motion: .playing
        ))
        XCTAssertNil(audit.observe(
            position: .infinity, uptime: 102, playerRate: 1, motion: .playing
        ))
        let final = audit.finish(
            position: 1, uptime: 102, playerRate: 1, motion: .playing
        )
        XCTAssertEqual(final?.jumpCount, 0)
        XCTAssertEqual(final?.sampledWall ?? -1, 1, accuracy: 0.001)
    }

    func testResetPreventsPreviousItemContamination() {
        var audit = NativeClockAudit()
        _ = audit.observe(position: 183, uptime: 200, playerRate: 1, motion: .playing)
        audit.reset()
        let next = audit.observe(position: 0, uptime: 201, playerRate: 1, motion: .playing)
        XCTAssertEqual(next?.kind, .baseline)
        XCTAssertEqual(next?.jumpCount, 0)
        XCTAssertEqual(next?.uptimeSinceStart ?? -1, 0, accuracy: 0.001)
    }
}
