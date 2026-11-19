import XCTest
@testable import ApoloEngine

final class ModelsTests: XCTestCase {
    func testDiagnosticsCarryTheStreamShape() {
        let diagnostics = PlaybackDiagnostics(
            route: .libavcodec,
            container: "flac",
            codec: "flac",
            sampleRate: 96_000,
            channels: 2,
            isAtmos: false,
            duration: 180,
            state: .playing
        )
        XCTAssertEqual(diagnostics.route, .libavcodec)
        XCTAssertEqual(diagnostics.sampleRate, 96_000)
        XCTAssertEqual(diagnostics.state, .playing)
    }

    func testErrorsHaveMessages() {
        for error: ApoloError in [
            .openFailed(code: -1),
            .readFailed(code: -5),
            .unsupportedFormat,
            .noAudioTrack,
            .playbackUnavailable,
        ] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
