import XCTest
@testable import ApoloEngine

final class SeekTransientRampTests: XCTestCase {
    func testConvertsThreeMillisecondRampAtCommonSampleRates() {
        XCTAssertEqual(SeekTransientRamp.frameCount(sampleRate: 48_000), 144)
        XCTAssertEqual(SeekTransientRamp.frameCount(sampleRate: 44_100), 132)
        XCTAssertEqual(SeekTransientRamp.frameCount(sampleRate: 0), 0)
    }

    func testRampKeepsAllFramesAndChannelsAcrossBufferBoundaries() {
        // 1000 Hz -> 3-frame ramp. The fourth frame must be untouched.
        var stereo: [Float] = [1, -1, 1, -1, 1, -1, 1, -1]
        var consumed = 0
        stereo.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                XCTFail("Missing test buffer")
                return
            }
            SeekTransientRamp.apply(
                interleaved: base,
                frames: 2,
                channels: 2,
                fadeFrames: 3,
                consumedFrames: &consumed
            )
            SeekTransientRamp.apply(
                interleaved: base.advanced(by: 4),
                frames: 2,
                channels: 2,
                fadeFrames: 3,
                consumedFrames: &consumed
            )
        }
        XCTAssertEqual(consumed, 3)
        XCTAssertEqual(stereo[0], 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stereo[1], -1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stereo[2], 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stereo[3], -2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stereo[4], 1)
        XCTAssertEqual(stereo[5], -1)
        XCTAssertEqual(stereo[6], 1)
        XCTAssertEqual(stereo[7], -1)
    }

    func testAlreadyCompleteRampLeavesAudioUntouched() {
        var samples: [Float] = [0.25, -0.5]
        var consumed = 3
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            SeekTransientRamp.apply(
                interleaved: base,
                frames: 1,
                channels: 2,
                fadeFrames: 3,
                consumedFrames: &consumed
            )
        }
        XCTAssertEqual(samples, [0.25, -0.5])
        XCTAssertEqual(consumed, 3)
    }
}
