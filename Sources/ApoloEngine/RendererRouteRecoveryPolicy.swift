import Foundation

/// Pure decisions for rebuilding the libavcodec renderer after AVFoundation
/// discards queued PCM during a hardware output change.
enum RendererRouteRecoveryPolicy {
    /// Disconnection must not automatically start playback on the iPhone
    /// speaker. A subsequent explicit Play may rebuild the renderer there.
    static func requiresManualPlay(
        previouslyExternal: Bool,
        nowBuiltIn: Bool
    ) -> Bool {
        previouslyExternal && nowBuiltIn
    }

    /// Re-prime from the current playback clock, never from song zero.
    /// Invalid or stale timestamps must not trigger an arbitrary seek.
    static func recoveryPosition(
        clock: TimeInterval,
        trackStart: TimeInterval
    ) -> TimeInterval? {
        guard clock.isFinite, trackStart.isFinite,
              clock >= trackStart, trackStart >= 0 else { return nil }
        return clock - trackStart
    }
}
