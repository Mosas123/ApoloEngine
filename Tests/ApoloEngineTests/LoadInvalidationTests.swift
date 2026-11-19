import XCTest
@testable import ApoloEngine

final class LoadInvalidationTests: XCTestCase {
    @MainActor
    func testStopAdvancesTheEngineEpoch() {
        let engine = ApoloEngine(
            managesSystemMediaControls: false,
            managesAudioSession: false
        )
        let before = engine.loadEpoch
        engine.stop()
        XCTAssertEqual(engine.loadEpoch, before &+ 1)
    }

    @MainActor
    func testStopAdvancesTheHostGeneration() {
        let host = AVPlayerHost()
        let before = host.loadGeneration
        host.stop()
        XCTAssertEqual(host.loadGeneration, before &+ 1)
    }
}
