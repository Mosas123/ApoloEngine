import Foundation

/// ITU-R BS.1770 / EBU R128 integrated loudness.
///
/// Offline analysis of interleaved Float32 PCM. K-weighting, 400 ms blocks
/// with 75% overlap, absolute (-70 LUFS) and relative (-10 LU) gating.
///
/// A music app uses it to compute a per-track ReplayGain-style gain; the
/// engine applies that gain (and its limiter) on the libavcodec route. For
/// live streaming there is no lookahead, so use the value when the track is
/// known or when the container carries `replaygain_track_gain`.
public enum LoudnessAnalyzer {
    public static let absoluteGateLUFS = -70.0
    public static let relativeGateLU = -10.0

    /// Integrated loudness, or `-.infinity` for silence.
    public static func integratedLoudness(
        interleaved: [Float],
        channels: Int,
        sampleRate: Double
    ) -> Double {
        guard channels > 0, sampleRate > 0, !interleaved.isEmpty else {
            return -.infinity
        }

        let weights = channelWeights(for: channels)
        let hopFrames = max(1, Int(0.1 * sampleRate))
        let frameCount = interleaved.count / channels
        guard frameCount > 0 else { return -.infinity }

        var shelves = (0..<channels).map { _ in
            Biquad.highShelf(
                frequency: 1_681.9744509555319,
                q: 0.7071752369554196,
                gainDB: 3.99984385397,
                sampleRate: sampleRate
            )
        }
        var highPasses = (0..<channels).map { _ in
            Biquad.highPass(
                frequency: 38.13547087602444,
                q: 0.5003270373238773,
                sampleRate: sampleRate
            )
        }

        var hops: [Double] = []
        hops.reserveCapacity(frameCount / hopFrames + 1)
        var hopSum = 0.0
        var hopCount = 0

        for frame in 0..<frameCount {
            let base = frame * channels
            var energy = 0.0
            for channel in 0..<channels {
                var sample = interleaved[base + channel]
                sample = shelves[channel].process(sample)
                sample = highPasses[channel].process(sample)
                energy += weights[channel] * Double(sample * sample)
            }
            hopSum += energy
            hopCount += 1
            if hopCount == hopFrames {
                hops.append(hopSum / Double(hopFrames))
                hopSum = 0
                hopCount = 0
            }
        }
        if hopCount > 0 {
            hops.append(hopSum / Double(hopCount))
        }

        // A 400 ms block is four 100 ms hops, sliding one hop at a time.
        let blockHops = 4
        guard hops.count >= blockHops else {
            let mean = hops.reduce(0, +) / Double(max(1, hops.count))
            return mean > 0 ? -0.691 + 10 * log10(mean) : -.infinity
        }

        var blocks: [Double] = []
        blocks.reserveCapacity(hops.count - blockHops + 1)
        for start in 0...(hops.count - blockHops) {
            let slice = hops[start..<(start + blockHops)]
            blocks.append(slice.reduce(0, +) / Double(blockHops))
        }

        let absolute = blocks.filter { $0 > 0 }
            .filter { -0.691 + 10 * log10($0) > absoluteGateLUFS }
        guard !absolute.isEmpty else { return -.infinity }

        let absoluteMean = absolute.reduce(0, +) / Double(absolute.count)
        let relativeThreshold = -0.691 + 10 * log10(absoluteMean) + relativeGateLU

        let gated = absolute.filter { -0.691 + 10 * log10($0) > relativeThreshold }
        guard !gated.isEmpty else { return -.infinity }

        let gatedMean = gated.reduce(0, +) / Double(gated.count)
        return -0.691 + 10 * log10(gatedMean)
    }

    /// Gain in dB that brings the material to `target` LUFS. Zero when the
    /// material is silent.
    public static func gain(
        toTarget target: Double,
        interleaved: [Float],
        channels: Int,
        sampleRate: Double
    ) -> Double {
        let loudness = integratedLoudness(
            interleaved: interleaved,
            channels: channels,
            sampleRate: sampleRate
        )
        guard loudness.isFinite else { return 0 }
        return target - loudness
    }

    private static func channelWeights(for channels: Int) -> [Double] {
        switch channels {
        case 6:
            // 5.1, FFmpeg order: FL FR FC LFE BL BR. LFE is excluded.
            return [1, 1, 1, 0, 1.41, 1.41]
        case 8:
            // 7.1: FL FR FC LFE BL BR SL SR.
            return [1, 1, 1, 0, 1.41, 1.41, 1.41, 1.41]
        default:
            return Array(repeating: 1, count: max(1, channels))
        }
    }
}
