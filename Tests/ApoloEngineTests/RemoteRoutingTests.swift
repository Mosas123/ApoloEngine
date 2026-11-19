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
