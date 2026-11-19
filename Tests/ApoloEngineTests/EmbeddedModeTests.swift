import XCTest
@testable import ApoloEngine

final class EmbeddedModeTests: XCTestCase {
    func testEmbeddedModeDoesNotRequireSystemOwnership() async {
        await MainActor.run {
            let engine = ApoloEngine(
                managesSystemMediaControls: false,
                managesAudioSession: false
            )
            XCTAssertEqual(engine.state, .idle)
            engine.stop()
            XCTAssertEqual(engine.state, .idle)
        }
    }
}
