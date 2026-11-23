import Foundation

/// Source-free telemetry about the *actual media clock* versus monotonic time.
/// This doesn't decide whether audio was heard or whether EOF is genuine.
/// App seeks reset the baseline, so explicit seeking isn't mistaken for a
/// decoder discontinuity. Samples are never persisted to user library data.
enum NativeClockMotion: String, Sendable {
    case playing
    case paused
    case waiting
}

struct NativeClockTrace: Equatable, Sendable {
    enum Kind: String, Sendable {
        case baseline
        case periodic
        case jump
        case final
    }

    let kind: Kind
    let position: TimeInterval
    let uptimeSinceStart: TimeInterval
    let playerRate: Double
    let motion: NativeClockMotion
    let sampledWall: TimeInterval
    let sampledMedia: TimeInterval
    let mediaExcessOverRate: TimeInterval
    let largestSingleExcess: TimeInterval
    let jumpCount: Int
    let samplingGapCount: Int
    let nonUnitRateSampleCount: Int
}

/// The 0.25s AVQueuePlayer periodic callback is normally frequent enough to
/// distinguish a single +21s PTS leap from gradual accelerated playback.
/// Long/paused intervals are reported as sampling gaps, NOT a finding.
struct NativeClockAudit: Sendable {
    private struct Sample: Sendable {
        let position: TimeInterval
        let uptime: TimeInterval
        let rate: Double
        let motion: NativeClockMotion
    }

    private var firstUptime: TimeInterval?
    private var lastReportedUptime: TimeInterval?
    private var previous: Sample?
    private(set) var sampledWall: TimeInterval = 0
    private(set) var sampledMedia: TimeInterval = 0
    private(set) var mediaExcessOverRate: TimeInterval = 0
    private(set) var largestSingleExcess: TimeInterval = 0
    private(set) var jumpCount = 0
    private(set) var samplingGapCount = 0
    private(set) var nonUnitRateSampleCount = 0

    mutating func reset() {
        self = NativeClockAudit()
    }

    /// A seek is a deliberate timeline discontinuity. Keep the aggregate
    /// counters but don't compare the new position to the pre-seek value.
    mutating func invalidateBaseline() {
        previous = nil
    }

    mutating func observe(
        position: TimeInterval,
        uptime: TimeInterval,
        playerRate: Double,
        motion: NativeClockMotion
    ) -> NativeClockTrace? {
        guard position.isFinite, position >= 0,
              uptime.isFinite, uptime >= 0,
              playerRate.isFinite, playerRate >= 0 else { return nil }

        if firstUptime == nil { firstUptime = uptime }
        let sample = Sample(
            position: position, uptime: uptime, rate: playerRate, motion: motion
        )
        let old = previous
        // Discard late callbacks; never move the baseline backward in time.
        if let old, uptime <= old.uptime { return nil }
        previous = sample

        var jumped = false
        if let old {
            let wall = uptime - old.uptime
            let media = position - old.position
            if wall > 3 {
                // A background scheduling pause may conceal any number of
                // timeline transitions; don't pretend they were observed.
                samplingGapCount += 1
            } else if wall >= 0.025 {
                let expected = wall * ((old.rate + playerRate) / 2)
                let excess = media - expected

                if old.motion == .playing, motion == .playing {
                    sampledWall += wall
                    sampledMedia += max(0, media)
                    mediaExcessOverRate += excess
                    if abs(playerRate - 1) > 0.02 {
                        nonUnitRateSampleCount += 1
                    }
                }

                // Even if AVPlayer already says "paused" at a true EOF,
                // detect a sudden media leap between adjacent observations.
                // The caller resets this baseline for explicit app seeks.
                if excess > 0.90 {
                    jumpCount += 1
                    largestSingleExcess = max(largestSingleExcess, excess)
                    jumped = true
                }
            }
        }

        let due = lastReportedUptime.map { uptime - $0 >= 10 } ?? true
        guard due || jumped else { return nil }
        lastReportedUptime = uptime
        return snapshot(
            kind: jumped ? .jump : (old == nil ? .baseline : .periodic),
            sample: sample
        )
    }

    mutating func finish(
        position: TimeInterval,
        uptime: TimeInterval,
        playerRate: Double,
        motion: NativeClockMotion
    ) -> NativeClockTrace? {
        guard position.isFinite, position >= 0,
              uptime.isFinite, uptime >= 0,
              playerRate.isFinite, playerRate >= 0 else { return nil }
        // Keep any final item jump evidence, even when the final callback
        // follows an already dequeued AVQueuePlayer.currentItem.
        _ = observe(position: position, uptime: uptime, playerRate: playerRate, motion: motion)
        return snapshot(
            kind: .final,
            sample: Sample(position: position, uptime: uptime, rate: playerRate, motion: motion)
        )
    }

    private func snapshot(kind: NativeClockTrace.Kind, sample: Sample) -> NativeClockTrace {
        NativeClockTrace(
            kind: kind,
            position: sample.position,
            uptimeSinceStart: max(0, sample.uptime - (firstUptime ?? sample.uptime)),
            playerRate: sample.rate,
            motion: sample.motion,
            sampledWall: sampledWall,
            sampledMedia: sampledMedia,
            mediaExcessOverRate: mediaExcessOverRate,
            largestSingleExcess: largestSingleExcess,
            jumpCount: jumpCount,
            samplingGapCount: samplingGapCount,
            nonUnitRateSampleCount: nonUnitRateSampleCount
        )
    }
}
