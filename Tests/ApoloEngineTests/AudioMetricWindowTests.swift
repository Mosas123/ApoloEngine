import Testing
@testable import ApoloEngine

struct AudioMetricWindowTests {
    @Test func nearestRankPercentilesForBoundedWindow() {
        var metrics = AudioMetricWindow()
        var last: AudioMetricWindow.Summary?
        for ms in 0..<32 {
            if let summary = metrics.record(.decoderRead, milliseconds: ms) {
                last = summary
            }
        }
        #expect(last?.totalCount == 32)
        #expect(last?.windowCount == 32)
        #expect(last?.minMs == 0)
        #expect(last?.p50Ms == 15)
        #expect(last?.p95Ms == 30)
        #expect(last?.maxMs == 31)
    }

    @Test func metricsArePerKindAndUseOnlyLatest128Samples() {
        var metrics = AudioMetricWindow()
        for _ in 0..<32 {
            _ = metrics.record(.httpRange, milliseconds: 500)
        }
        var last: AudioMetricWindow.Summary?
        for _ in 0..<128 {
            if let summary = metrics.record(.httpRange, milliseconds: 5) {
                last = summary
            }
        }
        #expect(last?.windowCount == 128)
        #expect(last?.totalCount == 160)
        #expect(last?.p95Ms == 5)
        #expect(last?.maxMs == 5)

        let separate = metrics.record(.probeOpen, milliseconds: 89)
        #expect(separate?.totalCount == 1)
        #expect(separate?.p50Ms == 89)
        #expect(separate?.logLine.contains("kind=probe.open") == true)
        #expect(separate?.logLine.contains("uptimeMs=") == true)
    }

    @Test func invalidDurationsAreIgnoredAndShortSessionsAreCaptured() {
        var metrics = AudioMetricWindow()
        #expect(metrics.record(.decoderRead, milliseconds: -1) == nil)
        let first = metrics.record(.decoderRead, milliseconds: 0)
        #expect(first?.totalCount == 1)
        #expect(first?.p95Ms == 0)
        for _ in 0..<6 {
            #expect(metrics.record(.decoderRead, milliseconds: 1) == nil)
        }
        #expect(metrics.record(.decoderRead, milliseconds: 9)?.totalCount == 8)
    }
}
