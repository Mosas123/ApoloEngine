import Foundation
import os

/// Structured, privacy-safe measurements for Console and Instruments.
enum AudioDiagnostics {
    static let playback = Logger(
        subsystem: "com.cl0udly.ApoloEngine",
        category: "playback"
    )
    static let session = Logger(
        subsystem: "com.cl0udly.ApoloEngine",
        category: "session"
    )
    static let live = Logger(
        subsystem: "com.cl0udly.ApoloEngine",
        category: "live"
    )

    static func milliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// Monotonic latency probe. Never use wall-clock dates for audio timings.
struct AudioProbe {
    private let start = ContinuousClock.now

    var milliseconds: Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
