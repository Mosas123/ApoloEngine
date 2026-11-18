import XCTest
@testable import ApoloEngine

final class AudioProcessingTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testFlatEqualizerIsIdentity() {
        let chain = AudioProcessingChain(
            sampleRate: sampleRate,
            channels: 1,
            settings: .flat,
            limiterEnabled: false
        )
        let original = tone(frequency: 1_000, count: 256, amplitude: 0.25)
        var output = original

        output.withUnsafeMutableBufferPointer { buffer in
            chain.process(interleaved: buffer.baseAddress!, frames: buffer.count)
        }

        for (a, b) in zip(original, output) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }

    func testBassBoostRaisesLowFrequency() {
        let chain = AudioProcessingChain(
            sampleRate: sampleRate,
            channels: 1,
            settings: EqualizerSettings(bandsDB: [6, 0, 0, 0, 0]),
            limiterEnabled: false
        )
        let input = tone(frequency: 60, count: 4_800, amplitude: 0.1)
        var output = input

        output.withUnsafeMutableBufferPointer { buffer in
            chain.process(interleaved: buffer.baseAddress!, frames: buffer.count)
        }

        let before = rms(Array(input[1_000...]))
        let after = rms(Array(output[1_000...]))
        XCTAssertGreaterThan(after / before, 1.5)
    }

    func testLimiterCapsPeaks() {
        let chain = AudioProcessingChain(
            sampleRate: sampleRate,
            channels: 1,
            settings: .flat,
            limiterEnabled: true
        )
        var samples = [Float](repeating: 0.99, count: 64)

        samples.withUnsafeMutableBufferPointer { buffer in
            chain.process(interleaved: buffer.baseAddress!, frames: buffer.count)
        }

        let ceiling = Float(pow(10, -1.0 / 20.0))
        let peak = samples.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, ceiling + 0.001)
    }

    private func tone(frequency: Double, count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(values.count))
    }
}
