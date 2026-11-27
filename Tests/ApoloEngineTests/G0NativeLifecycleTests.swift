import AVFoundation
import Foundation
import XCTest
@testable import ApoloEngine

final class G0NativeLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_NATIVE_LIFECYCLE"] == "1")
    }
    private func fixture(seconds: Double, marker: Int16) throws -> URL {
        let rate=48000,n=Int(Double(rate)*seconds)
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func integer<T:FixedWidthInteger>(_ x:T){var v=x.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");integer(UInt32(36+n*4));ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2))
        integer(UInt32(rate));integer(UInt32(rate*4));integer(UInt16(4));integer(UInt16(16));ascii("data");integer(UInt32(n*4))
        for i in 0..<n {integer(Int16(i%127)*16-marker);integer(Int16(i%97)*16-marker)}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try data.write(to:url);return url
    }
#if G0_NATIVE_LIFECYCLE
    @MainActor private final class Events {
        var states=[String](),changes=0,times=[Double]()
        func bind(_ h:AVPlayerHost){
            h.onState={ [weak self] s in self?.states.append(String(describing:s));print("G0_4B101_EVENT state=\(s)") }
            h.onTrackChange={ [weak self] in self?.changes += 1;print("G0_4B101_EVENT trackChange") }
            h.onTime={ [weak self] t in self?.times.append(t) }
        }
    }
    @MainActor private func wait(_ condition:()->Bool, seconds:Double=12) async -> Bool{
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while !condition() && ProcessInfo.processInfo.systemUptime<deadline {try? await Task.sleep(for:.milliseconds(10))}
        return condition()
    }
    @MainActor private func run(_ name:String) async throws {
        print("G0_4B101_PROCESS pid=\(getpid()) scenario=\(name)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a=try fixture(seconds:name=="NaturalNext" ? 0.75:4,marker:1000)
        let b=try fixture(seconds:name=="NaturalNext" ? 1.25:5,marker:500)
        defer{try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let h=AVPlayerHost(),e=Events()
        e.bind(h);h.configure(equalizer:.flat,limiterEnabled:false,trackGainDB:0)
        defer{h.g0ReleaseGate();h.stop()}
        var obs=""
        if name=="PauseLoad" || name=="StopLoad" || name=="ReloadLoad"{
            h.g0ArmGate("load")
            let task=Task{@MainActor in await h.load(url:a,httpHeaders:[:])}
            let reached=await wait{h.g0GateEntered};XCTAssertTrue(reached)
            let old=h.loadGeneration
            if name=="PauseLoad"{h.pause()}
            else if name=="StopLoad"{h.stop()}
            else{await h.load(url:b,httpHeaders:[:]);h.pause()}
            h.g0ReleaseGate();await task.value
            if name=="PauseLoad"{
                XCTAssertEqual(h.loadGeneration,old);XCTAssertEqual(h.g0Items.count,1)
                XCTAssertEqual(h.g0Rate,0);XCTAssertEqual(e.states.last,"paused")
            }else if name=="StopLoad"{
                XCTAssertNotEqual(h.loadGeneration,old);XCTAssertEqual(h.g0Items.count,0)
                XCTAssertEqual(e.states.last,"idle")
            }else{
                XCTAssertNotEqual(h.loadGeneration,old);XCTAssertEqual(h.g0Items.count,1)
                XCTAssertEqual((h.g0Items.first?.asset as? AVURLAsset)?.url,b)
            }
            obs="generation=\(h.loadGeneration) items=\(h.g0Items.count) rate=\(h.g0Rate) states=\(e.states.joined(separator:","))"
        }else{
            await h.load(url:a,httpHeaders:[:]);h.pause()
            XCTAssertEqual(h.g0Items.count,1)
            if name=="ClearPending"{
                h.g0ArmGate("next")
                let task=Task{@MainActor in await h.enqueueNext(ApoloTrack(url:b))}
                let reached=await wait{h.g0GateEntered};XCTAssertTrue(reached)
                let old=h.loadGeneration
                h.clearUpcoming();XCTAssertEqual(h.g0Items.count,1)
                h.g0ReleaseGate();await task.value
                XCTAssertEqual(h.loadGeneration,old)
                obs="itemsAfterPending=\(h.g0Items.count) taps=\(h.g0TapCount) observers=\(h.g0ObserverCount) generation=\(old)"
            }else if name=="ClearRetained"{
                await h.enqueueNext(ApoloTrack(url:b))
                XCTAssertEqual(h.g0Items.count,2)
                let removed=try XCTUnwrap(h.g0Items.last)
                let taps=h.g0TapCount,observers=h.g0ObserverCount
                h.clearUpcoming();XCTAssertEqual(h.g0Items.count,1)
                let before=e.states.count,changes=e.changes
                // Explicitly inject notification for removed item, not a claim of spontaneous Apple delivery.
                NotificationCenter.default.post(name:AVPlayerItem.failedToPlayToEndTimeNotification,object:removed)
                NotificationCenter.default.post(name:AVPlayerItem.didPlayToEndTimeNotification,object:removed)
                obs="tapsBefore=\(taps) tapsAfter=\(h.g0TapCount) observersBefore=\(observers) observersAfter=\(h.g0ObserverCount) injectedStates=\(e.states.dropFirst(before).joined(separator:",")) injectedChanges=\(e.changes-changes)"
            }else if name=="NaturalNext"{
                await h.enqueueNext(ApoloTrack(url:b));XCTAssertEqual(h.g0Items.count,2)
                h.play()
                let finished=await wait{e.states.contains("finished")};XCTAssertTrue(finished)
                obs="changes=\(e.changes) finished=\(e.states.filter{$0=="finished"}.count) remaining=\(h.g0Items.count) timeCallbacks=\(e.times.count) states=\(e.states.joined(separator:","))"
            }else{
                await h.enqueueNext(ApoloTrack(url:b));XCTAssertEqual(h.g0Items.count,2)
                await h.seek(to:1)
                let position=h.currentTime
                XCTAssertTrue(position.isFinite)
                obs="seek=\(position) rate=\(h.g0Rate) items=\(h.g0Items.count) taps=\(h.g0TapCount) observers=\(h.g0ObserverCount)"
            }
        }
        h.stop()
        XCTAssertEqual(h.g0Items.count,0);XCTAssertEqual(h.g0TapCount,0);XCTAssertEqual(h.g0ObserverCount,0)
        XCTAssertEqual(e.states.last,"idle")
        print("G0_4B101_CONTROL scenario=\(name) metadataOff=true stopped=true empty=true")
        print("G0_4B101_OBSERVATION scenario=\(name) \(obs)")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws{
#if G0_NATIVE_LIFECYCLE
        try await run(name)
#else
        throw XCTSkip("runner-only native observation")
#endif
    }
    @MainActor func testPauseLoad() async throws {try await scenario("PauseLoad")}
    @MainActor func testStopLoad() async throws {try await scenario("StopLoad")}
    @MainActor func testReloadLoad() async throws {try await scenario("ReloadLoad")}
    @MainActor func testClearPending() async throws {try await scenario("ClearPending")}
    @MainActor func testClearRetained() async throws {try await scenario("ClearRetained")}
    @MainActor func testNaturalNext() async throws {try await scenario("NaturalNext")}
    @MainActor func testSeekPaused() async throws {try await scenario("SeekPaused")}
}
