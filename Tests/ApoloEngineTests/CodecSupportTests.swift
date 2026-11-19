import XCTest
@testable import ApoloEngine

final class CodecSupportTests: XCTestCase {
    func testKnownCodecsUseAVPlayer() {
        XCTAssertEqual(CodecSupport.route(forCodec: "flac"), .avPlayer)
        XCTAssertEqual(CodecSupport.route(forCodec: "EAC3"), .avPlayer)
        XCTAssertEqual(CodecSupport.route(forCodec: "alac"), .avPlayer)
    }

    func testUnknownCodecUsesLibavcodec() {
        XCTAssertEqual(CodecSupport.route(forCodec: "wmapro"), .libavcodec)
        XCTAssertEqual(CodecSupport.route(forCodec: "truehd"), .libavcodec)
    }

    func testSignedYouTubeWebMUsesFFmpeg() async {
        let webm = URL(string: "https://r1.googlevideo.com/videoplayback?expire=123&mime=audio%2Fwebm")!
        let opus = URL(string: "https://example.org/audio.opus")!
        let mp4 = URL(string: "https://r1.googlevideo.com/videoplayback?mime=audio%2Fmp4")!
        let file = URL(fileURLWithPath: "/tmp/song.webm")
        let routes = await MainActor.run {
            [
                ApoloEngine.prefersFFmpegForRemote(webm),
                ApoloEngine.prefersFFmpegForRemote(opus),
                ApoloEngine.prefersFFmpegForRemote(mp4),
                ApoloEngine.prefersFFmpegForRemote(file)
            ]
        }
        XCTAssertEqual(routes, [true, true, false, false])
    }
}
