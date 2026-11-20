import MediaPlayer
import XCTest
@testable import ApoloEngine

final class NowPlayingControllerTests: XCTestCase {
    @MainActor
    func testLiveCardMarksLiveAndDisablesSeek() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        let controller = NowPlayingController()
        controller.activate()
        defer {
            controller.clear()
            center.nowPlayingInfo = nil
        }

        controller.update(
            title: "Station",
            artist: "Artist",
            album: nil,
            duration: 0,
            elapsed: 0,
            isPlaying: true,
            isLive: true,
            artworkData: nil
        )

        let info = center.nowPlayingInfo
        XCTAssertEqual(
            (info?[MPNowPlayingInfoPropertyIsLiveStream] as? NSNumber)?.boolValue,
            true
        )
        XCTAssertNil(info?[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        XCTAssertFalse(commands.changePlaybackPositionCommand.isEnabled)
    }

    @MainActor
    func testFiniteCardRestoresDurationAndSeek() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        let controller = NowPlayingController()
        controller.activate()
        defer {
            controller.clear()
            center.nowPlayingInfo = nil
        }

        controller.update(
            title: "Song",
            artist: "Artist",
            album: nil,
            duration: 180,
            elapsed: 10,
            isPlaying: true,
            isLive: false,
            artworkData: nil
        )

        let info = center.nowPlayingInfo
        XCTAssertEqual(
            (info?[MPNowPlayingInfoPropertyIsLiveStream] as? NSNumber)?.boolValue,
            false
        )
        XCTAssertEqual(
            (info?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue,
            180
        )
        XCTAssertTrue(commands.changePlaybackPositionCommand.isEnabled)
    }
}
