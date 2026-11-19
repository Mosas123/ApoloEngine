import XCTest
@testable import ApoloEngine

final class CodecSupportTests: XCTestCase {
    func testKnownCodecsUseAVPlayer() {
        XCTAssertEqual(CodecSupport.route(forCodec: "aac"), .avPlayer)
        XCTAssertEqual(CodecSupport.route(forCodec: "EAC3"), .avPlayer)
        XCTAssertEqual(CodecSupport.route(forCodec: "alac"), .avPlayer)
    }

    func testFLACUsesLibavcodec() {
        XCTAssertEqual(CodecSupport.route(forCodec: "flac"), .libavcodec)
        XCTAssertEqual(
            CodecSupport.route(forCodec: "flac", container: "flac"),
            .libavcodec
        )
    }

    func testContainerWinsOverCodec() {
        XCTAssertEqual(
            CodecSupport.route(
                forCodec: "aac",
                container: "mov,mp4,m4a,3gp,3g2,mj2"
            ),
            .avPlayer
        )
        XCTAssertEqual(
            CodecSupport.route(forCodec: "aac", container: "matroska,webm"),
            .libavcodec
        )
        XCTAssertEqual(
            CodecSupport.route(forCodec: "flac", container: "ogg"),
            .libavcodec
        )
    }

    func testOpusAndVorbisUseLibavcodec() {
        XCTAssertEqual(CodecSupport.route(forCodec: "opus"), .libavcodec)
        XCTAssertEqual(CodecSupport.route(forCodec: "vorbis"), .libavcodec)
    }

    func testUnknownCodecUsesLibavcodec() {
        XCTAssertEqual(CodecSupport.route(forCodec: "wmapro"), .libavcodec)
        XCTAssertEqual(CodecSupport.route(forCodec: "truehd"), .libavcodec)
    }
}
