import Foundation
import os

/// Structured, privacy-safe measurements for Console, Instruments and the
/// on-device Files app. No URLs, titles or headers are written here.
enum AudioDiagnostics {
    enum Category: String {
        case playback
        case session
        case live
    }

    enum Level: String {
        case debug
        case notice
    }

    static func record(
        _ category: Category,
        _ message: String,
        level: Level = .notice
    ) {
        switch (category, level) {
        case (.playback, .debug):
            log.playback.debug("\(message, privacy: .public)")
        case (.playback, .notice):
            log.playback.notice("\(message, privacy: .public)")
        case (.session, .debug):
            log.session.debug("\(message, privacy: .public)")
        case (.session, .notice):
            log.session.notice("\(message, privacy: .public)")
        case (.live, .debug):
            log.live.debug("\(message, privacy: .public)")
        case (.live, .notice):
            log.live.notice("\(message, privacy: .public)")
        }
        FileSink.shared.append(category: category.rawValue, level: level.rawValue, message: message)
    }

    static func milliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static let log = (
        playback: Logger(subsystem: "com.cl0udly.ApoloEngine", category: "playback"),
        session: Logger(subsystem: "com.cl0udly.ApoloEngine", category: "session"),
        live: Logger(subsystem: "com.cl0udly.ApoloEngine", category: "live")
    )
}

/// Keeps a small rotating file in Documents. Trop exposes Documents through
/// UIFileSharingEnabled, so this is readable from the iPhone Files app without
/// a Mac or Xcode.
private final class FileSink: @unchecked Sendable {
    static let shared = FileSink()

    private let queue = DispatchQueue(label: "com.cl0udly.ApoloEngine.diagnostics")
    private let maxBytes = 1_000_000
    private var handle: FileHandle?
    private var size = 0

    private init() {}

    func append(category: String, level: String, message: String) {
        queue.async { [weak self] in
            guard let self,
                  let url = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                  ).first?.appendingPathComponent("apolo-diagnostics.log")
            else { return }

            let line = "\(Date().ISO8601Format()) [\(level)][\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if self.handle == nil {
                self.open(url)
            }
            if self.size > self.maxBytes {
                try? self.handle?.close()
                self.handle = nil
                try? data.write(to: url, options: .atomic)
                self.size = data.count
                self.open(url)
                return
            }
            if let handle = self.handle {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                self.size += data.count
            } else {
                try? data.write(to: url, options: .atomic)
                self.size = data.count
                self.open(url)
            }
        }
    }

    private func open(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        handle = file
        size = (try? file.seekToEnd()).map(Int.init) ?? 0
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
