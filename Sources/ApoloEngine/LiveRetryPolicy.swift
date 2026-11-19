import Foundation

/// Bounded reconnect schedule for unexpected live-radio failures.
/// Reopening the source builds a fresh demuxer; never splice a new Ogg/Opus
/// connection into the middle of an existing compressed packet stream.
enum LiveRetryPolicy {
    static let maxAttempts = 3
    static let resetAfterPlaying: TimeInterval = 60

    /// The attempt argument is one-based. Nil means retries are exhausted.
    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return TimeInterval(1 << (attempt - 1))
    }
}
