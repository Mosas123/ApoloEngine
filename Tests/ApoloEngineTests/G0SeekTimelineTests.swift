import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0SeekTimelineTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_TIMELINE"] == "1")
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
#if G0_SEEK_TIMELINE
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
            print("G0_4B1072_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B1072_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B1072_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func sample(_ e:ApoloEngine,_ name:String,_ phase:String) -> (Double,Double) {
        let clock=e.currentTime
        let elapsed=e.elapsed
        print("G0_4B1072_SAMPLE scenario=\(name) phase=\(phase) uptime=\(ProcessInfo.processInfo.systemUptime) clock=\(clock) elapsed=\(elapsed) epoch=\(e.loadEpoch) state=\(e.state) publications=\(e.g0OutcomePublications) rejected=\(e.g0OutcomeRejected)")
        return (clock,elapsed)
    }
    @MainActor private func window(_ e:ApoloEngine,_ name:String,_ phase:String) async throws -> (Double,Double) {
        let delays=[0,10,40,50,150,100]
        var total=0
        var snapshot=(0.0,0.0)
        for delay in delays {
            if delay>0 { try await Task.sleep(for:.milliseconds(delay)) }
            total += delay
            snapshot=sample(e,name,"\(phase)-\(total)ms")
        }
        return snapshot
    }
    @MainActor private func run(_ name:String) async throws {
        let candidate=ProcessInfo.processInfo.environment["APOLO_G0_SEEK_POLICY_CANDIDATE"] == "1"
        print("G0_4B1072_PROCESS pid=\(getpid()) scenario=\(name) candidate=\(candidate)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        try require(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_PROFILE"] == name,"profile environment mismatch")
        let native=name.hasPrefix("Native")
        let e=ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events=Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled=false
        let url:URL
        if native { url=try nativeFixture() } else { url=try fixture(seconds:8,marker:100) }
        defer {
            e.g0OutcomeRelease(); e.g0OutcomeRelease(); e.stop()
            for line in events.all().filter({$0.hasPrefix("g0.timeline ") || $0.hasPrefix("g0.outcome ") || $0.hasPrefix("renderer.firstPCM ") || $0.hasPrefix("renderer.autoFlush ") || $0.hasPrefix("renderer.routeRecovery ") || $0.hasPrefix("renderer.decoderEOF ")}) {
                print("G0_4B1072_TRACE \(line)")
            }
            try? FileManager.default.removeItem(at:url)
        }
        try await load(e,url,native ? .avPlayer : .libavcodec,events)
        let before=sample(e,name,"before")
        let overlap=name=="LibavOverlap"
        let sequential=name=="LibavSequential"
        let doubleSeek=overlap || sequential
        var result:Bool?=nil
        var firstFinal=before
        if native {
            await e.seek(to:2)
            result=e.g0OutcomeNativeResult
            print("G0_4B1072_NATIVE scenario=\(name) result=\(result!)")
        } else {
            let first=Task { @MainActor in await e.seek(to:2) }
            let held=await wait { events.all().filter{$0.hasPrefix("g0.outcome entered ")}.count==1 }
            try require(held,"first worker not held")
            if !candidate { await first.value }
            _=sample(e,name,"firstHeld")
            try require(e.g0OutcomePublications == (candidate ? [] : [2]),"first pending publication")
            var second:Task<Void,Never>?
            if overlap {
                second=Task { @MainActor in await e.seek(to:3) }
                let submitted=await wait { e.g0OutcomeRequest==2 }
                try require(submitted,"second request not submitted")
                if !candidate { await second?.value }
            }
            e.g0OutcomeRelease()
            let firstDone=await wait { events.all().filter{$0.hasPrefix("g0.outcome result ")}.count==1 }
            try require(firstDone,"first worker outcome missing")
            await first.value
            if sequential {
                firstFinal=try await window(e,name,"firstSettled")
                second=Task { @MainActor in await e.seek(to:3) }
                let submitted=await wait { e.g0OutcomeRequest==2 }
                try require(submitted,"sequential request not submitted")
                if !candidate { await second?.value }
            }
            if doubleSeek {
                let secondHeld=await wait { events.all().filter{$0.hasPrefix("g0.outcome entered ")}.count==2 }
                try require(secondHeld,"second worker not held")
                _=sample(e,name,"secondHeld")
                let p=e.g0OutcomePublications
                let expectedCount=candidate ? (sequential ? 1 : 0) : 2
                try require(p.count==expectedCount,"second pending explicit publication")
                e.g0OutcomeRelease()
                let done=await wait { events.all().filter{$0.hasPrefix("g0.outcome result ")}.count==2 }
                try require(done,"second worker outcome missing")
                await second?.value
            }
        }
        let final=try await window(e,name,"final")
        let target=doubleSeek ? 3.0 : 2.0
        let clockAccurate=abs(final.0-target)<0.06
        let cancelStill=abs(final.0-before.0)<0.05
        let publications=e.g0OutcomePublications
        let rejected=e.g0OutcomeRejected
        let records=events.all()
        let successes=records.filter{$0.hasPrefix("g0.outcome result outcome=success ")}.count
        let expectedCount = native ? (candidate && result == false ? 0 : 1) : (doubleSeek && !(candidate && overlap) ? 2 : 1)
        let expectedRejected = candidate && (overlap || (native && result == false)) ? 1 : 0
        let strictClock = name=="NativeCancelPending" ? (result==false ? cancelStill : clockAccurate) : clockAccurate
        print("G0_4B1072_OBSERVATION scenario=\(name) candidate=\(candidate) before=\(before.0) firstFinal=\(firstFinal.0) finalClock=\(final.0) finalElapsed=\(final.1) target=\(target) accurate=\(clockAccurate) cancelStill=\(cancelStill) strictClock=\(strictClock) nativeResult=\(String(describing:result)) publications=\(publications) rejected=\(rejected) workerSuccess=\(successes)")
        // Diagnostic completion is distinct from the original strict clock result.
        // Never change its tolerance; preserve every failure in strictClock.
        try require(publications.count==expectedCount && rejected==expectedRejected,"explicit publication/rejection accounting")
        try require(final.0.isFinite && final.1.isFinite,"nonfinite clock")
        if native {
            if name=="NativeNormal" { try require(result==true && abs(final.0-target)<0.05,"native positive control") }
            if !candidate { try require(publications==[2],"original native publication") }
        } else {
            try require(successes==(doubleSeek ? 2 : 1),"actual worker success prerequisite")
            if name=="LibavNormal" { try require(clockAccurate,"single libav positive control") }
            if !candidate { try require(publications==(doubleSeek ? [2,3] : [2]),"original libav publication") }
        }
        e.stop()
        try require(e.state == .idle && e.currentTrack == nil && e.nextTracks.isEmpty && e.elapsed==0,"final cleanup")
        print("G0_4B1072_CONTROL scenario=\(name) candidate=\(candidate) strictClock=\(strictClock) metadataOff=true cleanup=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_SEEK_TIMELINE
        try await run(name)
#else
        throw XCTSkip("runner-only seek timeline observation")
#endif
    }
    @MainActor func testNativeNormal() async throws { try await scenario("NativeNormal") }
    @MainActor func testNativeCancelPending() async throws { try await scenario("NativeCancelPending") }
    @MainActor func testLibavNormal() async throws { try await scenario("LibavNormal") }
    @MainActor func testLibavOverlap() async throws { try await scenario("LibavOverlap") }
    @MainActor func testLibavSequential() async throws { try await scenario("LibavSequential") }
}
