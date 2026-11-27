import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0SeekPolicyTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_POLICY"] == "1")
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
#if G0_SEEK_POLICY
    private func nativeFixture(seconds: Int = 8) throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".m4a")
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let settings:[String:Any]=[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000]
        let file=try AVAudioFile(forWriting:url,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for ch in 0..<2 {for i in 0..<48000{buffer.floatChannelData![ch][i]=Float(i%97-48)/512}}
        for _ in 0..<seconds {try file.write(from:buffer)}
        return url
    }
    @MainActor private func wait(_ condition:()->Bool,seconds:Double=12) async -> Bool{
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while !condition() && ProcessInfo.processInfo.systemUptime<deadline{try? await Task.sleep(for:.milliseconds(10))}
        return condition()
    }
    private final class Events: @unchecked Sendable {
        private let lock=NSLock()
        private var lines=[String]()
        func record(_ line:String){lock.lock();lines.append(line);lock.unlock()}
        func all()->[String]{lock.lock();defer{lock.unlock()};return lines}
    }
    @MainActor private func require(_ condition:Bool,_ message:String) throws{
        guard condition else {
            XCTFail(message)
            throw NSError(domain:"G0Prerequisite",code:1,userInfo:[NSLocalizedDescriptionKey:message])
        }
    }
    @MainActor private func load(_ e:ApoloEngine,_ url:URL,_ route:AudioRoute,_ events:Events) async throws{
        try await e.load(url:url)
        let epoch=e.loadEpoch
        try require(e.diagnostics.route==route,"actual route mismatch")
        try require(e.currentTrack?.url==url,"actual track mismatch")
        if route == .libavcodec {
            let marker="g0.rendererEnqueued epoch=\(epoch) "
            let enqueued=await wait{events.all().contains{$0.hasPrefix(marker)}}
            try require(enqueued,"no first renderer enqueue for active epoch")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"renderer clock did not advance 150ms")
            let second=e.currentTime
            let state=e.state
            print("G0_4B1071_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B1071_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B1071_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name:String) async throws {
        let candidate = ProcessInfo.processInfo.environment["APOLO_G0_SEEK_POLICY_CANDIDATE"] == "1"
        print("G0_4B1071_PROCESS pid=\(getpid()) scenario=\(name) candidate=\(candidate)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        try require(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_PROFILE"] == name,"profile environment mismatch")
        let native = name.hasPrefix("Native")
        let e = ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events = Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled = false
        defer { e.g0OutcomeRelease(); e.g0OutcomeRelease(); e.g0NativeRelease = true; e.stop() }
        if name != "NativeNoItem" {
            let url: URL
            if native { url = try nativeFixture() } else { url = try fixture(seconds:8,marker:100) }
            defer { try? FileManager.default.removeItem(at:url) }
            try await load(e,url,native ? .avPlayer : .libavcodec,events)
            try await exercise(e,events,name,candidate)
        } else {
            try await exercise(e,events,name,candidate)
        }
    }
    @MainActor private func exercise(_ e:ApoloEngine,_ events:Events,_ name:String,_ candidate:Bool) async throws {
        let epoch=e.loadEpoch
        let before=e.currentTime
        let beforeElapsed=e.elapsed
        let target=2.0
        let native=name.hasPrefix("Native")
        let overlap=name.hasSuffix("Overlap")
        let stop=name=="LibavStopQueued"
        let failure=name=="LibavInjectedFailure"
        var expected=[Double]()
        if native {
            if overlap {
                let first=Task { @MainActor in await e.seek(to:target) }
                let held=await wait { e.g0NativeHeld }
                try require(held && e.g0NativeFirstResult && abs(e.currentTime-target)<0.05,"actual first native completion prerequisite")
                await e.seek(to:3)
                try require(e.g0OutcomeNativeResult && abs(e.currentTime-3)<0.05,"actual second native completion prerequisite")
                e.g0NativeRelease=true
                await first.value
                try require(!e.g0NativeTimedOut,"native gate timeout")
                expected=candidate ? [3] : [3,2]
            } else {
                await e.seek(to:target)
                let result=e.g0OutcomeNativeResult
                print("G0_4B1071_NATIVE scenario=\(name) result=\(result) before=\(before) clock=\(e.currentTime)")
                if name=="NativeNormal" {
                    try require(result && abs(e.currentTime-target)<0.05,"native positive control")
                    expected=[2]
                } else {
                    try require(!result && abs(e.currentTime-before)<0.05,"negative native completion prerequisite")
                    expected=candidate ? [] : [2]
                }
            }
        } else {
            let first=Task { @MainActor in await e.seek(to:target) }
            let held=await wait { events.all().filter{$0.hasPrefix("g0.outcome entered ")}.count==1 }
            try require(held,"first worker not held")
            if !candidate { await first.value }
            let pending=e.g0OutcomePublications
            let preCompleted=events.all().contains{$0.hasPrefix("g0.outcome result ")}
            print("G0_4B1071_PENDING scenario=\(name) phase=first elapsed=\(e.elapsed) clock=\(e.currentTime) completion=\(preCompleted) publications=\(pending)")
            try require(!preCompleted && pending == (candidate ? [] : [2]),"first pending publication")
            var second: Task<Void,Never>?
            if overlap {
                second=Task { @MainActor in await e.seek(to:3) }
                let submitted=await wait { e.g0OutcomeRequest==2 }
                try require(submitted,"second request not submitted")
                if !candidate { await second?.value }
            }
            if stop { e.stop() }
            e.g0OutcomeRelease()
            if overlap {
                let entered=await wait { events.all().filter{$0.hasPrefix("g0.outcome entered ")}.count==2 }
                try require(entered,"second worker not held")
                await first.value
                let p=e.g0OutcomePublications
                print("G0_4B1071_PENDING scenario=\(name) phase=second elapsed=\(e.elapsed) clock=\(e.currentTime) publications=\(p)")
                try require(p == (candidate ? [] : [2,3]),"superseded first result publication")
                e.g0OutcomeRelease()
                await second?.value
            } else {
                await first.value
            }
            let count=overlap ? 2 : 1
            let completed=await wait { events.all().filter{$0.hasPrefix("g0.outcome result ")}.count==count }
            try require(completed,"worker result missing")
            if stop {
                let stopped=await wait {
                    let lines=events.all()
                    guard let index=lines.firstIndex(where:{$0.hasPrefix("g0.outcome result ")}) else{return false}
                    return lines.dropFirst(index+1).contains{$0.hasPrefix("g0.outcome stopped ")}
                }
                try require(stopped,"queued stop missing")
            }
            try await Task.sleep(for:.milliseconds(350))
            let records=events.all().filter{$0.hasPrefix("g0.outcome ")}
            for record in records { print("G0_4B1071_WORKER \(record)") }
            let outcome=failure ? "injectedFailure" : "success"
            try require(records.filter{$0.hasPrefix("g0.outcome result outcome=\(outcome) ")}.count==count,"unexpected worker result")
            expected=candidate ? (stop || failure ? [] : [overlap ? 3 : 2]) : (overlap ? [2,3] : [2])
            if !stop && !failure {
                try require(abs(e.currentTime-(overlap ? 3 : 2))<0.06,"libav positive clock control")
            }
        }
        let publications=e.g0OutcomePublications
        let finalElapsed=e.elapsed
        let clock=e.currentTime
        print("G0_4B1071_OBSERVATION scenario=\(name) candidate=\(candidate) epochBefore=\(epoch) epochAfter=\(e.loadEpoch) before=\(before) beforeElapsed=\(beforeElapsed) elapsed=\(finalElapsed) clock=\(clock) state=\(e.state) track=\(e.currentTrack != nil) publications=\(publications) rejected=\(e.g0OutcomeRejected)")
        try require(publications.count==expected.count && zip(publications,expected).allSatisfy{abs($0.0-$0.1)<0.06},"publication policy mismatch")
        if stop { try require(e.currentTrack==nil && e.state == .idle && abs(clock)<0.05 && abs(finalElapsed)<0.05,"stop invariant") }
        if candidate && expected.isEmpty && !stop {
            try require(abs(finalElapsed-beforeElapsed)<0.30 && abs(clock-before)<0.05,"negative seek moved public clock")
        }
        if candidate && !expected.isEmpty {
            try require(abs(finalElapsed-clock)<0.06,"candidate success clock mismatch")
        }
        let expectedRejected=candidate && (overlap || stop || failure || name=="NativeNoItem" || name=="NativeCancelPending") ? 1 : 0
        try require(e.g0OutcomeRejected==expectedRejected,"rejection accounting")
        e.stop()
        try require(e.state == .idle && e.currentTrack == nil && e.nextTracks.isEmpty && e.elapsed == 0,"final cleanup")
        print("G0_4B1071_CONTROL scenario=\(name) candidate=\(candidate) count=\(publications.count) rejected=\(e.g0OutcomeRejected) metadataOff=true cleanup=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_SEEK_POLICY
        try await run(name)
#else
        throw XCTSkip("runner-only seek policy")
#endif
    }
    @MainActor func testNativeNormal() async throws { try await scenario("NativeNormal") }
    @MainActor func testNativeNoItem() async throws { try await scenario("NativeNoItem") }
    @MainActor func testNativeCancelPending() async throws { try await scenario("NativeCancelPending") }
    @MainActor func testNativeOverlap() async throws { try await scenario("NativeOverlap") }
    @MainActor func testLibavNormal() async throws { try await scenario("LibavNormal") }
    @MainActor func testLibavInjectedFailure() async throws { try await scenario("LibavInjectedFailure") }
    @MainActor func testLibavStopQueued() async throws { try await scenario("LibavStopQueued") }
    @MainActor func testLibavOverlap() async throws { try await scenario("LibavOverlap") }
}
