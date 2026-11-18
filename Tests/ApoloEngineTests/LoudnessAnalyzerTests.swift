import XCTest
@testable import ApoloEngine

final class LoudnessAnalyzerTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testHalvingAmplitudeDropsSixDecibels() {
        let loud = sine(amplitude: 0.5)
        let quiet = sine(amplitude: 0.25)

        let loudLUFS = LoudnessAnalyzer.integratedLoudness(
            interleaved: loud,
            channels: 1,
            sampleRate: sampleRate
        )
        let quietLUFS = LoudnessAnalyzer.integratedLoudness(
            interleaved: quiet,
            channels: 1,
            sampleRate: sampleRate
        )

        XCTAssertEqual(loudLUFS - quietLUFS, 6.02, accuracy: 0.2)
    }

    func testGainBringsMaterialToTarget() {
        let samples = sine(amplitude: 0.3)
        let loudness = LoudnessAnalyzer.integratedLoudness(
            interleaved: samples,
            channels: 1,
            sampleRate: sampleRate
        )
        let gain = LoudnessAnalyzer.gain(
            toTarget: -14,
            interleaved: samples,
            channels: 1,
            sampleRate: sampleRate
        )

        XCTAssertEqual(loudness + gain, -14, accuracy: 0.01)
    }

    func testSilenceHasNoGain() {
        let silence = [Float](repeating: 0, count: 48_000)
        let loudness = LoudnessAnalyzer.integratedLoudness(
            interleaved: silence,
            channels: 1,
            sampleRate: sampleRate
        )
        let gain = LoudnessAnalyzer.gain(
            toTarget: -14,
            interleaved: silence,
            channels: 1,
            sampleRate: sampleRate
        )

        XCTAssertFalse(loudness.isFinite)
        XCTAssertEqual(gain, 0)
    }

    private func sine(amplitude: Float, seconds: Double = 2) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * 1_000 * Double(index) / sampleRate))
        }
    }
}
