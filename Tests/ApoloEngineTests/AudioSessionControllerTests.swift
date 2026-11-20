import AVFoundation
import XCTest
@testable import ApoloEngine

final class AudioSessionControllerTests: XCTestCase {
    @MainActor
    func testInterruptionCallbacksAndOptions() {
        let controller = AudioSessionController(managesSession: false)
        var began = 0
        var ended: [Bool] = []
        controller.onInterruptionBegan = { began += 1 }
        controller.onInterruptionEnded = { ended.append($0) }

        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.began.rawValue,
            optionsRaw: 0
        )
        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
            optionsRaw: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        )
        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
            optionsRaw: 0
        )

        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, [true, false])
    }

    @MainActor
    func testOnlyOldDeviceUnavailableReportsRouteLoss() {
        let controller = AudioSessionController(managesSession: false)
        var lost = 0
        controller.onRouteLost = { lost += 1 }

        controller.handleRouteChange(
            reasonRaw: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        )
        controller.handleRouteChange(
            reasonRaw: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        )

        XCTAssertEqual(lost, 1)
    }
}
