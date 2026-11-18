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
}
