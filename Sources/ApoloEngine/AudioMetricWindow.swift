import Foundation

/// Only numeric, allowlisted measurements are accepted here. No URL, track ID,
/// codec payload, headers, or user metadata can enter a metric name.
enum AudioMetricKind: String, CaseIterable, Sendable {
    case probeOpen = "probe.open"
    case probeStreamInfo = "probe.streamInfo"
    case httpRange = "http.range"
    case decoderRead = "decoder.read"
}

/// Bounded, sliding-window statistics. The caller serializes access with a lock.
/// Percentiles are nearest-rank estimates over the last 128 observations, not
/// proof of end-to-end playback latency or CPU/battery consumption.
struct AudioMetricWindow {
    static let windowCapacity = 128
    private var buckets: [AudioMetricKind: Bucket] = [:]

    mutating func record(_ kind: AudioMetricKind, milliseconds: Int) -> Summary? {
        guard milliseconds >= 0 else { return nil }
        var bucket = buckets[kind] ?? Bucket()
        let summary = bucket.add(milliseconds, kind: kind)
        buckets[kind] = bucket
        return summary
    }

    struct Summary: Equatable {
        let kind: AudioMetricKind
        let totalCount: Int
        let windowCount: Int
        let minMs: Int
        let p50Ms: Int
        let p95Ms: Int
        let maxMs: Int

        /// Keep the existing Trop/APOLO_DIAG logger as the only disk writer.
        var logLine: String {
            let uptime = Int(ProcessInfo.processInfo.systemUptime * 1_000)
            return "metric.window v=1 kind=\(kind.rawValue) count=\(windowCount) "
                + "total=\(totalCount) minMs=\(minMs) p50Ms=\(p50Ms) "
                + "p95Ms=\(p95Ms) maxMs=\(maxMs) uptimeMs=\(uptime)"
        }
    }

    private struct Bucket {
        private var values = [Int](repeating: 0, count: AudioMetricWindow.windowCapacity)
        private var next = 0
        private var filled = 0
        private var total = 0

        mutating func add(_ value: Int, kind: AudioMetricKind) -> Summary? {
            values[next] = value
            next = (next + 1) % values.count
            filled = min(filled + 1, values.count)
            total &+= 1

            // First event makes short-lived sessions observable; later samples
            // limit disk volume. No timers, polling, or render-thread work.
            guard total == 1 || total == 8 || total % 32 == 0 else {
                return nil
            }

            let ordered = values.prefix(filled).sorted()
            func percentile(_ numerator: Int) -> Int {
                let rank = max(1, (ordered.count * numerator + 99) / 100)
                return ordered[rank - 1]
            }
            return Summary(
                kind: kind,
                totalCount: total,
                windowCount: filled,
                minMs: ordered[0],
                p50Ms: percentile(50),
                p95Ms: percentile(95),
                maxMs: ordered[ordered.count - 1]
            )
        }
    }
}
