import XCTest
@testable import ApoloEngine

final class RemoteRoutingTests: XCTestCase {
    func testRemoteFLACUsesFFmpeg() {
        XCTAssertTrue(
            ApoloEngine.shouldUseFFmpegForRemote(
                URL(string: "https://cdn.example/a.flac")!
            )
        )
        XCTAssertTrue(
            ApoloEngine.shouldUseFFmpegForRemote(
                URL(string: "https://cdn.example/play?mime=audio%2Fflac&token=x")!
            )
        )
    }

    func testLocalFLACStaysOnAVPlayer() {
        XCTAssertFalse(
            ApoloEngine.shouldUseFFmpegForRemote(
                URL(fileURLWithPath: "/tmp/a.flac")
            )
        )
    }

    func testRemoteAACStaysOnAVPlayer() {
        XCTAssertFalse(
            ApoloEngine.shouldUseFFmpegForRemote(
                URL(string: "https://cdn.example/a.m4a")!
            )
        )
        XCTAssertFalse(
            ApoloEngine.shouldUseFFmpegForRemote(
                URL(string: "https://cdn.example/play?mime=audio%2Fmp4")!
            )
        )
    }

    func testNativeLiveSupportsHLSAndContinuousAppleAudio() {
        XCTAssertTrue(ApoloEngine.supportsNativeLive(
            URL(string: "https://radio.example/live.m3u8")!,
            hint: "application/vnd.apple.mpegurl"
        ))
        XCTAssertTrue(ApoloEngine.supportsNativeLive(
            URL(string: "https://radio.example/listen.mp3")!,
            hint: "audio/mpeg"
        ))
        XCTAssertTrue(ApoloEngine.supportsNativeLive(
            URL(string: "https://radio.example/stream")!,
            hint: "audio/aac"
        ))
    }

    func testFFmpegLiveSupportsOggOpusAndFLAC() {
        XCTAssertTrue(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/live.ogg")!
        ))
        XCTAssertTrue(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/live.opus")!
        ))
        XCTAssertTrue(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/stream")!,
            hint: "audio/ogg; codecs=opus"
        ))
        XCTAssertTrue(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/live.flac")!
        ))
        XCTAssertFalse(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/live.m3u8")!
        ))
        XCTAssertFalse(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/station.pls")!
        ))
        XCTAssertFalse(ApoloEngine.supportsFFmpegLive(
            URL(string: "https://station.example/live.mp3")!
        ))
    }

    func testNativeLiveRejectsUnsupportedOrPlaylistSources() {
        XCTAssertFalse(ApoloEngine.supportsNativeLive(
            URL(string: "https://radio.example/live.ogg")!,
            hint: "audio/ogg"
        ))
        XCTAssertFalse(ApoloEngine.supportsNativeLive(
            URL(string: "https://radio.example/playlist.pls")!
        ))
        XCTAssertFalse(ApoloEngine.supportsNativeLive(
            URL(string: "https://radio.example/listen.m3u")!
        ))
        XCTAssertFalse(ApoloEngine.supportsNativeLive(
            URL(fileURLWithPath: "/tmp/live.mp3")
        ))
        XCTAssertFalse(ApoloEngine.supportsNativeLive(
            URL(string: "ftp://radio.example/stream.mp3")!
        ))
    }

    func testLegacyICYHintOnlyOptInForLiveRouting() {
        let station = URL(string: "http://legacy.example/live.mp3")!
        XCTAssertTrue(ApoloEngine.supportsNativeLive(
            station, hint: "audio/mpeg"
        ))
        XCTAssertFalse(ApoloEngine.supportsFFmpegLive(
            station, hint: "audio/mpeg"
        ))
        XCTAssertFalse(ApoloEngine.supportsNativeLive(
            station, hint: "application/x-icy"
        ))
        XCTAssertTrue(ApoloEngine.supportsFFmpegLive(
            station, hint: "application/x-icy"
        ))
        XCTAssertFalse(ApoloEngine.shouldUseFFmpegForRemote(
            station, hint: "application/x-icy"
        ))
        XCTAssertFalse(ApoloEngine.supportsFFmpegLive(
            URL(string: "http://legacy.example/live.m3u8")!,
            hint: "application/x-icy"
        ))
    }

    func testOpaqueRemoteURLNeedsAHint() {
        let opaque = URL(string: "https://cdn.example/stream?token=x")!
        XCTAssertFalse(ApoloEngine.shouldUseFFmpegForRemote(opaque))
        XCTAssertTrue(
            ApoloEngine.shouldUseFFmpegForRemote(opaque, hint: "audio/flac")
        )
        XCTAssertTrue(
            ApoloEngine.shouldUseFFmpegForRemote(
                opaque,
                hint: "audio/webm; codecs=\"opus\""
            )
        )
        XCTAssertFalse(
            ApoloEngine.shouldUseFFmpegForRemote(opaque, hint: "audio/mp4")
        )
    }
}
