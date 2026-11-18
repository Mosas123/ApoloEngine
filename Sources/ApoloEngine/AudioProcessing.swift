import Foundation

/// Five fixed-band EQ plus preamp, in dB. The centre frequencies follow the
/// usual bass / low-mid / mid / high-mid / treble split.
public struct EqualizerSettings: Sendable, Equatable {
    public static let bandFrequencies: [Double] = [60, 240, 1_000, 3_500, 10_000]
    public static let flat = EqualizerSettings()

    public var bandsDB: [Double]
    public var preampDB: Double

    public init(bandsDB: [Double]? = nil, preampDB: Double = 0) {
        let points = bandsDB ?? Array(repeating: 0, count: Self.bandFrequencies.count)
        self.bandsDB = Array(points.prefix(Self.bandFrequencies.count))
            + Array(
                repeating: 0,
                count: max(0, Self.bandFrequencies.count - points.count)
            )
        self.preampDB = preampDB
    }
}

/// Interleaved Float32 EQ and peak limiter. Runs on the decoder queue, right
/// before the PCM is packaged into a `CMSampleBuffer`.
final class AudioProcessingChain {
    private let sampleRate: Double
    private let channels: Int
    private var filters: [[Biquad]]
    private var limiter: Limiter
    private var preamp: Float
    private let limiterEnabled: Bool

    init(
        sampleRate: Double,
        channels: Int,
        settings: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.limiterEnabled = limiterEnabled
        self.limiter = Limiter(ceilingDB: -1, sampleRate: sampleRate)

        let totalGainDB = settings.preampDB + trackGainDB
        self.preamp = totalGainDB.isFinite
            ? Float(pow(10, totalGainDB / 20))
            : 1

        let bands = settings.bandsDB
        self.filters = (0..<self.channels).map { _ in
            zip(EqualizerSettings.bandFrequencies, bands).compactMap { frequency, gain in
                guard gain != 0, gain.isFinite else { return nil }
                return Biquad.peaking(
                    frequency: frequency,
                    q: 1,
                    gainDB: gain,
                    sampleRate: sampleRate
                )
            }
        }
    }

    func process(planar: [UnsafeMutablePointer<Float>], frames: Int) {
        guard frames > 0 else { return }
        let count = min(planar.count, filters.count)
        guard count > 0 else { return }
        guard !filters[0].isEmpty || limiterEnabled || preamp != 1 else { return }

        for frame in 0..<frames {
            var peak: Float = 0

            for channel in 0..<count {
                var sample = planar[channel][frame] * preamp
                for index in filters[channel].indices {
                    sample = filters[channel][index].process(sample)
                }
                planar[channel][frame] = sample
                peak = max(peak, abs(sample))
            }

            if limiterEnabled {
                let gain = limiter.gain(forPeak: peak)
                if gain < 1 {
                    for channel in 0..<count {
                        planar[channel][frame] *= gain
                    }
                }
            }
        }
    }

    func process(interleaved: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let channelCount = channels
        guard !filters[0].isEmpty || limiterEnabled || preamp != 1 else { return }

        for frame in 0..<frames {
            let base = frame * channelCount
            var peak: Float = 0

            for channel in 0..<channelCount {
                var sample = interleaved[base + channel] * preamp
                for index in filters[channel].indices {
                    sample = filters[channel][index].process(sample)
                }
                interleaved[base + channel] = sample
                peak = max(peak, abs(sample))
            }

            if limiterEnabled {
                let gain = limiter.gain(forPeak: peak)
                if gain < 1 {
                    for channel in 0..<channelCount {
                        interleaved[base + channel] *= gain
                    }
                }
            }
        }
    }
}

struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    /// RBJ cookbook high shelf, normalised by a0. Used by the K-weighting
    /// pre-filter of the loudness analyser.
    static func highShelf(
        frequency: Double,
        q: Double,
        gainDB: Double,
        sampleRate: Double
    ) -> Biquad {
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let root = 2 * sqrt(amplitude) * alpha

        let a0 = (amplitude + 1) - (amplitude - 1) * cosine + root
        return Biquad(
            b0: Float(amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + root) / a0),
            b1: Float(-2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine) / a0),
            b2: Float(amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - root) / a0),
            a1: Float(2 * ((amplitude - 1) - (amplitude + 1) * cosine) / a0),
            a2: Float(((amplitude + 1) - (amplitude - 1) * cosine - root) / a0)
        )
    }

    /// RBJ cookbook high pass, normalised by a0. The second K-weighting stage.
    static func highPass(
        frequency: Double,
        q: Double,
        sampleRate: Double
    ) -> Biquad {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)

        let a0 = 1 + alpha
        return Biquad(
            b0: Float(((1 + cosine) / 2) / a0),
            b1: Float(-(1 + cosine) / a0),
            b2: Float(((1 + cosine) / 2) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha) / a0)
        )
    }

    /// RBJ cookbook peaking EQ, normalised by a0.
    static func peaking(
        frequency: Double,
        q: Double,
        gainDB: Double,
        sampleRate: Double
    ) -> Biquad {
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)

        let a0 = 1 + alpha / amplitude
        return Biquad(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosine) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha / amplitude) / a0)
        )
    }
}

struct Limiter {
    private let ceiling: Float
    private let releaseCoefficient: Float
    private var envelope: Float = 1

    init(ceilingDB: Double, releaseSeconds: Double = 0.05, sampleRate: Double) {
        ceiling = Float(pow(10, ceilingDB / 20))
        releaseCoefficient = Float(
            exp(-1 / (releaseSeconds * sampleRate))
        )
    }

    /// Instant attack on the current peak, exponential release afterwards.
    mutating func gain(forPeak peak: Float) -> Float {
        let target = peak > ceiling ? ceiling / peak : 1
        if target < envelope {
            envelope = target
        } else {
            envelope = target + (envelope - target) * releaseCoefficient
        }
        return envelope
    }
}
