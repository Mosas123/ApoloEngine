import XCTest
@testable import ApoloEngine

final class RendererRouteRecoveryPolicyTests: XCTestCase {
    func testUnpluggingExternalAudioRequiresExplicitPlayOnSpeaker() {
        XCTAssertTrue(
            RendererRouteRecoveryPolicy.requiresManualPlay(
                previouslyExternal: true,
                nowBuiltIn: true
            )
        )
    }

    func testConnectingHeadphonesPermitsAutomaticRepriming() {
        XCTAssertFalse(
            RendererRouteRecoveryPolicy.requiresManualPlay(
                previouslyExternal: false,
                nowBuiltIn: false
            )
        )
        XCTAssertFalse(
            RendererRouteRecoveryPolicy.requiresManualPlay(
                previouslyExternal: true,
                nowBuiltIn: false
            )
        )
    }

    func testSpeakerOnlyFlushDoesNotInventPrivacyPause() {
        XCTAssertFalse(
            RendererRouteRecoveryPolicy.requiresManualPlay(
                previouslyExternal: false,
                nowBuiltIn: true
            )
        )
    }

    func testRecoveryUsesCurrentPositionNotTrackStart() {
        XCTAssertEqual(
            RendererRouteRecoveryPolicy.recoveryPosition(
                clock: 125.625,
                trackStart: 100
            ),
            25.625
        )
        XCTAssertEqual(
            RendererRouteRecoveryPolicy.recoveryPosition(
                clock: 12.4,
                trackStart: 0
            ),
            12.4
        )
    }

    func testInvalidClockCannotCauseUnsafeSeek() {
        XCTAssertNil(
            RendererRouteRecoveryPolicy.recoveryPosition(
                clock: .nan,
                trackStart: 0
            )
        )
        XCTAssertNil(
            RendererRouteRecoveryPolicy.recoveryPosition(
                clock: -1,
                trackStart: 0
            )
        )
        XCTAssertNil(
            RendererRouteRecoveryPolicy.recoveryPosition(
                clock: 2,
                trackStart: 4
            )
        )
        XCTAssertNil(
            RendererRouteRecoveryPolicy.recoveryPosition(
                clock: 2,
                trackStart: .infinity
            )
        )
    }
}
