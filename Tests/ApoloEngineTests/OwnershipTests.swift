import MediaPlayer
import XCTest
@testable import ApoloEngine

final class OwnershipTests: XCTestCase {
    @MainActor
    func testEmbeddedEngineLeavesNowPlayingAlone() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = ["apolo.test": "sentinel"]
        defer { center.nowPlayingInfo = nil }

        let engine = ApoloEngine(
            managesSystemMediaControls: false,
            managesAudioSession: false
        )
        engine.stop()

        XCTAssertEqual(
            center.nowPlayingInfo?["apolo.test"] as? String,
            "sentinel"
        )
    }

    @MainActor
    func testManagedEngineClearsNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = ["apolo.test": "sentinel"]
        defer { center.nowPlayingInfo = nil }

        let engine = ApoloEngine(
            managesSystemMediaControls: true,
            managesAudioSession: false
        )
        engine.stop()

        XCTAssertNil(center.nowPlayingInfo)
    }
}
