import AVFoundation
import Foundation
import XCTest
@testable import ApoloEngine

final class G0NativeRetirementTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_NATIVE_RETIREMENT"] == "1")
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
#if G0_NATIVE_RETIREMENT
    @MainActor private final class Events {
        var states=[String](),changes=0,times=[Double]()
        func bind(_ h:AVPlayerHost){
            h.onState={ [weak self] s in self?.states.append(String(describing:s));print("G0_4B102_EVENT state=\(s)") }
            h.onTrackChange={ [weak self] in self?.changes += 1;print("G0_4B102_EVENT trackChange") }
            h.onTime={ [weak self] t in self?.times.append(t) }
        }
    }
    @MainActor private func wait(_ condition:()->Bool, seconds:Double=12) async -> Bool{
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while !condition() && ProcessInfo.processInfo.systemUptime<deadline {try? await Task.sleep(for:.milliseconds(10))}
        return condition()
    }
    @MainActor private func run(_ name:String) async throws {
        let candidate=ProcessInfo.processInfo.environment["APOLO_G0_RETIRE_CANDIDATE"]=="1"
        print("G0_4B102_PROCESS pid=\(getpid()) scenario=\(name) candidate=\(candidate)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a=try fixture(seconds:name=="NaturalNext" ? 0.75:4,marker:1000)
        let b=try fixture(seconds:name=="NaturalNext" ? 1.25:5,marker:500)
        defer{try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let h=AVPlayerHost(),e=Events()
        e.bind(h);h.configure(equalizer:.flat,limiterEnabled:false,trackGainDB:0)
        defer{h.g0ReleaseGate();h.stop()}
        await h.load(url:a,httpHeaders:[:]);h.pause()
        XCTAssertEqual(h.g0Items.count,1)
        let old=h.loadGeneration,current=try XCTUnwrap(h.g0Items.first)
        var detail="",observation=""
        if name=="ClearPending"{
            h.g0ArmGate("next")
            let task=Task{@MainActor in await h.enqueueNext(ApoloTrack(url:b))}
            let reached=await wait{h.g0GateEntered};XCTAssertTrue(reached)
            h.clearUpcoming();XCTAssertEqual(h.g0Items.count,1)
            h.g0ReleaseGate();await task.value
            XCTAssertEqual(h.loadGeneration,old)
            XCTAssertEqual(h.g0Items.count,candidate ? 1:2)
            XCTAssertEqual(h.g0TapCount,candidate ? 1:2)
            XCTAssertEqual(h.g0ObserverCount,candidate ? 2:4)
            detail="items=\(h.g0Items.count) taps=\(h.g0TapCount) observers=\(h.g0ObserverCount)"
            // Both modes still accept a legitimate enqueue after clear.
            h.clearUpcoming()
            await h.enqueueNext(ApoloTrack(url:b))
            XCTAssertEqual(h.g0Items.count,2)
            XCTAssertTrue(h.g0Items.first === current)
            observation="freshEnqueue=true"
        }else if name=="RepeatedClear"{
            var retained=[AVPlayerItem]()
            var taps=[Int](),observers=[Int]()
            for _ in 0..<12{
                await h.enqueueNext(ApoloTrack(url:b))
                XCTAssertEqual(h.g0Items.count,2)
                retained.append(try XCTUnwrap(h.g0Items.last))
                h.clearUpcoming()
                XCTAssertEqual(h.g0Items.count,1);XCTAssertTrue(h.g0Items.first === current)
                taps.append(h.g0TapCount);observers.append(h.g0ObserverCount)
            }
            let before=e.states.count,changes=e.changes
            for removed in retained{
                NotificationCenter.default.post(name:AVPlayerItem.failedToPlayToEndTimeNotification,object:removed)
                NotificationCenter.default.post(name:AVPlayerItem.didPlayToEndTimeNotification,object:removed)
            }
            let failures=e.states.dropFirst(before).filter{$0.hasPrefix("failed")}.count
            let delta=e.changes-changes
            XCTAssertEqual(taps,(1...12).map{candidate ? 1:$0+1})
            XCTAssertEqual(observers,(1...12).map{candidate ? 2:($0+1)*2})
            XCTAssertEqual(delta,candidate ? 0:12)
            // publish deduplicates consecutive equal failed states.
            XCTAssertEqual(failures,candidate ? 0:1)
            detail="cycles=12 taps=\(taps.last!) observers=\(observers.last!) failed=\(failures) changes=\(delta)"
            observation="tapSeries=\(taps) observerSeries=\(observers) injected=24"
        }else{
            await h.enqueueNext(ApoloTrack(url:b));XCTAssertEqual(h.g0Items.count,2)
            h.play()
            let done=await wait{e.states.contains("finished")};XCTAssertTrue(done)
            XCTAssertEqual(e.changes,1);XCTAssertEqual(e.states.filter{$0=="finished"}.count,1)
            XCTAssertEqual(h.g0TapCount,candidate ? 0:2)
            XCTAssertEqual(h.g0ObserverCount,candidate ? 0:4)
            detail="changes=1 finished=1 taps=\(h.g0TapCount) observers=\(h.g0ObserverCount)"
            observation="remaining=\(h.g0Items.count) timeCallbacks=\(e.times.count)"
        }
        h.stop()
        XCTAssertEqual(h.g0Items.count,0);XCTAssertEqual(h.g0TapCount,0);XCTAssertEqual(h.g0ObserverCount,0)
        XCTAssertEqual(e.states.last,"idle")
        print("G0_4B102_CONTROL scenario=\(name) candidate=\(candidate) \(detail) stopped=true metadataOff=true")
        print("G0_4B102_OBSERVATION scenario=\(name) candidate=\(candidate) \(observation)")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws{
#if G0_NATIVE_RETIREMENT
        try await run(name)
#else
        throw XCTSkip("runner-only native retirement")
#endif
    }
    @MainActor func testClearPending() async throws {try await scenario("ClearPending")}
    @MainActor func testRepeatedClear() async throws {try await scenario("RepeatedClear")}
    @MainActor func testNaturalNext() async throws {try await scenario("NaturalNext")}
}
