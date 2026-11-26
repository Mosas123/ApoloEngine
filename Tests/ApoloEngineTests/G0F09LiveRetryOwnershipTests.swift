#if G0_F09F31_ENABLED
import Foundation
import XCTest
@testable import ApoloEngine

final class G0F09LiveRetryOwnershipTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    @MainActor
    private func until(_ predicate: () -> Bool, seconds: Double = 8) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while !predicate(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @MainActor
    func testObsoleteCompletionCannotScheduleExtraRetry() async throws {
        for outcome in ["success", "error"] {
            try await runCase(outcome)
        }
    }

    @MainActor
    private func runCase(_ outcome: String) async throws {
        let e = ApoloEngine(managesSystemMediaControls: false, managesAudioSession: false)
        let a = try XCTUnwrap(URL(string: "https://f09f31.invalid/a"))
        let b = try XCTUnwrap(URL(string: "https://f09f31.invalid/b"))
        let r = F09F31State()
        e.g0F09F31RetryFinished = { epoch in
            r.finished.append(epoch)
        }
        e.g0F09F3Open = { [weak e] track, epoch in
            guard let e else { return }
            let name = track.url.lastPathComponent
            r.opens.append((name, epoch))
            let count = r.opens.filter { $0.0 == name }.count
            if count == 1 {
                e.g0F09F3State(.failed("synthetic initial"))
            } else if name == "a" {
                let released = await self.until({ r.releaseA }, seconds: 20)
                if !released || outcome == "error" { throw URLError(.cancelled) }
                // Successful obsolete opening: no simulated stale state publication.
                return
            } else if count == 2 {
                _ = await self.until({ r.releaseB }, seconds: 20)
                // B's original retry remains in flight until explicit release.
                if e.loadEpoch == epoch { e.g0F09F3State(.playing) }
            } else {
                // Observe unexpected additional B opening without permitting
                // any further retry cascade.
                if e.loadEpoch == epoch { e.g0F09F3State(.playing) }
            }
        }
        defer {
            r.releaseA = true; r.releaseB = true
            e.stop()
            e.g0F09F3Open = nil
            e.g0F09F31RetryFinished = nil
        }
        try await e.loadLive(url: a)
        let aStarted = await until { r.opens.filter { $0.0 == "a" }.count == 2 && e.g0F09F3Opening }
        XCTAssertTrue(aStarted)
        guard aStarted else { return }
        let epochA = e.loadEpoch
        try await e.loadLive(url: b)
        let bStarted = await until { r.opens.filter { $0.0 == "b" }.count == 2 && e.g0F09F3Opening }
        XCTAssertTrue(bStarted)
        guard bStarted else { return }
        let epochB = e.loadEpoch
        r.releaseA = true
        let aFinished = await until { r.finished.contains(epochA) }
        XCTAssertTrue(aFinished)
        guard aFinished else { return }
        let openingAfterA = e.g0F09F3Opening
        XCTAssertEqual(e.loadEpoch, epochB)
        XCTAssertEqual(e.currentTrack?.url, b)
        XCTAssertTrue(openingAfterA, "obsolete retry must not clear ownership")
        // Synthetic failure for the current B epoch, while its opener is still
        // waiting. This probes the actual scheduler guard, not a host callback.
        e.g0F09F3State(.failed("synthetic current failure during open"))
        let pendingAfterFailure = e.g0F09F3Pending
        let attemptsAfterFailure = e.g0F09F3Attempts
        XCTAssertFalse(pendingAfterFailure, "current in-flight retry must suppress duplicate scheduling")
        XCTAssertEqual(attemptsAfterFailure, 1)
        // Second retry delay is 2s; observe for 3s without releasing B.
        try await Task.sleep(for: .seconds(3))
        let names = r.opens.map { $0.0 }.joined(separator: ",")
        let epochs = r.opens.map { String($0.1) }.joined(separator: ",")
        let bOpens = r.opens.filter { $0.0 == "b" }.count
        print("G0_F09F31_CASE outcome=\(outcome) epochA=\(epochA) epochB=\(epochB) oldFinished=\(aFinished) openingAfterOld=\(openingAfterA) pendingAfterFailure=\(pendingAfterFailure) attemptsAfterFailure=\(attemptsAfterFailure) bReleased=\(r.releaseB) bOpens=\(bOpens) opens=\(names) epochs=\(epochs) finalEpoch=\(e.loadEpoch) current=\(e.currentTrack?.url.lastPathComponent ?? "none")")
        XCTAssertEqual(bOpens, 2, "no extra B open before original B retry completes")
        XCTAssertEqual(e.loadEpoch, epochB)
        r.releaseB = true
        let bFinished = await until { r.finished.contains(epochB) }
        XCTAssertTrue(bFinished)
    }
}

@MainActor
private final class F09F31State {
    var opens: [(String, UInt64)] = []
    var finished: [UInt64] = []
    var releaseA = false
    var releaseB = false
}
#endif
