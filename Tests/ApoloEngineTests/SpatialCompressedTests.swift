import XCTest
@testable import ApoloEngine

final class SpatialCompressedTests: XCTestCase {
    func testEAC3AndAC3AreSpatialCompressed() {
        XCTAssertTrue(AVPlayerHost.isSpatialCompressed("audio/eac3"))
        XCTAssertTrue(AVPlayerHost.isSpatialCompressed("audio/ac3"))
        XCTAssertTrue(AVPlayerHost.isSpatialCompressed("audio/ec+3"))
    }

    func testAACAndFLACKeepTheTap() {
        XCTAssertFalse(AVPlayerHost.isSpatialCompressed("audio/mp4"))
        XCTAssertFalse(AVPlayerHost.isSpatialCompressed("audio/flac"))
        XCTAssertFalse(AVPlayerHost.isSpatialCompressed(nil))
    }

    func testAtmosTrackCarriesTheHint() {
        let track = ApoloTrack(
            url: URL(string: "https://cdn.example/a.m4a")!,
            isAtmos: true
        )
        XCTAssertTrue(track.isAtmos)
    }
}
