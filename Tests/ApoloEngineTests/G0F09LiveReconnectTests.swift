#if G0_F09F3_ENABLED
import Foundation
import XCTest
@testable import ApoloEngine

final class G0F09LiveReconnectTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    @MainActor
    private func engine() -> ApoloEngine {
        ApoloEngine(managesSystemMediaControls: false, managesAudioSession: false)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while !predicate(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @MainActor
    func testBackoffCommands() async throws {
        for command in ["stop", "pause", "switch", "playing", "duplicateFailure"] {
            let e = engine()
            let a = try XCTUnwrap(URL(string: "https://f09f3.invalid/a"))
            let b = try XCTUnwrap(URL(string: "https://f09f3.invalid/b"))
            let recorder = F09F3Recorder()
            e.g0F09F3Open = { [weak e] track, epoch in
                recorder.record(track.url.lastPathComponent, epoch)
                if command == "duplicateFailure" && recorder.opens.count > 1 { e?.g0F09F3State(.playing) }
                else if track.url == b { e?.g0F09F3State(.playing) }
                else { e?.g0F09F3State(.failed("synthetic")) }
            }
            try await e.loadLive(url: a)
            XCTAssertTrue(e.g0F09F3Pending)
            let beforeEpoch = e.loadEpoch
            switch command {
            case "stop": e.stop()
            case "pause": e.pause()
            case "switch": try await e.loadLive(url: b)
            case "playing": e.g0F09F3State(.playing)
            default:
                e.g0F09F3State(.failed("duplicate"))
                e.g0F09F3State(.failed("duplicate again"))
                XCTAssertEqual(e.g0F09F3Attempts, 1)
            }
            try await Task.sleep(for: .milliseconds(1400))
            let names = recorder.opens.map { $0.name }
            let expected = command == "switch" ? ["a","b"] : command == "duplicateFailure" ? ["a","a"] : ["a"]
            print("G0_F09F3_COMMAND command=\(command) opens=\(names.joined(separator: ",")) epochs=\(recorder.opens.map { String($0.epoch) }.joined(separator: ",")) beforeEpoch=\(beforeEpoch) finalEpoch=\(e.loadEpoch) pending=\(e.g0F09F3Pending) opening=\(e.g0F09F3Opening) attempts=\(e.g0F09F3Attempts) current=\(e.currentTrack?.url.lastPathComponent ?? "none") state=\(e.state)")
            XCTAssertEqual(names, expected)
            XCTAssertFalse(e.g0F09F3Pending)
            XCTAssertFalse(e.g0F09F3Opening)
            if command == "stop" { XCTAssertNil(e.currentTrack); XCTAssertEqual(e.state, .idle) }
            if command == "switch" { XCTAssertEqual(e.currentTrack?.url, b) }
            e.stop()
        }
    }

    @MainActor
    func testRetryBudgetAndTerminalStatus() async throws {
        let a = try XCTUnwrap(URL(string: "https://f09f3.invalid/a"))
        for status in [403, 503] {
            let e = engine()
            let recorder = F09F3Recorder()
            e.g0F09F3Open = { [weak e] track, epoch in
                recorder.record(track.url.lastPathComponent, epoch)
                e?.g0F09F3HTTPStatus(status)
                e?.g0F09F3State(.failed("synthetic"))
            }
            try await e.loadLive(url: a)
            if status == 403 {
                try await Task.sleep(for: .milliseconds(1400))
            } else {
                let done = await waitUntil({ recorder.opens.count == 4 && !e.g0F09F3Pending && !e.g0F09F3Opening }, seconds: 12)
                XCTAssertTrue(done)
                try await Task.sleep(for: .milliseconds(1200))
            }
            let times = recorder.opens.map { $0.time }
            let gaps = zip(times.dropFirst(), times).map { Double($0.0 - $0.1) / 1_000_000 }
            print("G0_F09F3_BUDGET status=\(status) opens=\(times.count) attempts=\(e.g0F09F3Attempts) pending=\(e.g0F09F3Pending) opening=\(e.g0F09F3Opening) gapsMs=\(gaps.map { String(format: "%.3f", $0) }.joined(separator: ","))")
            XCTAssertEqual(times.count, status == 403 ? 1 : 4)
            XCTAssertEqual(e.g0F09F3Attempts, status == 403 ? 0 : 3)
            XCTAssertFalse(e.g0F09F3Pending)
            XCTAssertFalse(e.g0F09F3Opening)
            if status == 503 {
                XCTAssertEqual(gaps.count, 3)
                for (gap, minimum) in zip(gaps, [990.0,1990.0,3990.0]) { XCTAssertGreaterThanOrEqual(gap, minimum) }
            }
            e.stop()
        }
        let now = Date(timeIntervalSince1970: 1000)
        for seconds in [0.0, 59.999, 60.0, 60.001] {
            let reset = LiveRetryPolicy.shouldResetBudget(playingSince: now.addingTimeInterval(-seconds), now: now)
            XCTAssertEqual(reset, seconds >= 60)
            print("G0_F09F3_RESET seconds=\(seconds) reset=\(reset)")
        }
        XCTAssertFalse(LiveRetryPolicy.shouldResetBudget(playingSince: nil, now: now))
    }

    @MainActor
    func testOverlappingRetryOwnership() async throws {
        let e = engine()
        let recorder = F09F3Recorder()
        let a = try XCTUnwrap(URL(string: "https://f09f3.invalid/a"))
        let b = try XCTUnwrap(URL(string: "https://f09f3.invalid/b"))
        e.g0F09F3Open = { [weak e] track, epoch in
            let name = track.url.lastPathComponent
            recorder.record(name, epoch)
            let count = recorder.opens.filter { $0.name == name }.count
            if count == 1 {
                e?.g0F09F3State(.failed("synthetic"))
            } else if name == "a" {
                _ = await self.waitUntil({ recorder.releaseA }, seconds: 6)
                // Obsolete attempt completes with an error, as a cancelled probe can.
                throw URLError(.cancelled)
            } else {
                _ = await self.waitUntil({ recorder.releaseB }, seconds: 6)
                e?.g0F09F3State(.playing)
            }
        }
        defer { recorder.releaseA = true; recorder.releaseB = true; e.stop() }
        try await e.loadLive(url: a)
        let aStarted = await waitUntil { recorder.opens.filter { $0.name == "a" }.count == 2 && e.g0F09F3Opening }
        XCTAssertTrue(aStarted)
        guard aStarted else { return }
        try await e.loadLive(url: b)
        let bStarted = await waitUntil { recorder.opens.filter { $0.name == "b" }.count == 2 && e.g0F09F3Opening }
        XCTAssertTrue(bStarted)
        guard bStarted else { return }
        let epochB = e.loadEpoch
        recorder.releaseA = true
        try await Task.sleep(for: .milliseconds(200))
        let openingAfterA = e.g0F09F3Opening
        print("G0_F09F3_OWNERSHIP opens=\(recorder.opens.map { $0.name }.joined(separator: ",")) epochB=\(epochB) finalEpoch=\(e.loadEpoch) openingAfterOldCompletion=\(openingAfterA) pending=\(e.g0F09F3Pending) current=\(e.currentTrack?.url.lastPathComponent ?? "none")")
        XCTAssertEqual(e.loadEpoch, epochB)
        XCTAssertEqual(e.currentTrack?.url, b)
        XCTAssertTrue(openingAfterA, "obsolete retry completion must not clear current retry ownership")
        recorder.releaseB = true
        let settled = await waitUntil { e.state == .playing && !e.g0F09F3Opening }
        XCTAssertTrue(settled)
    }
}

@MainActor
private final class F09F3Recorder {
    var opens: [(name: String, epoch: UInt64, time: UInt64)] = []
    var releaseA = false
    var releaseB = false
    func record(_ name: String, _ epoch: UInt64) {
        opens.append((name, epoch, DispatchTime.now().uptimeNanoseconds))
    }
}
#endif
