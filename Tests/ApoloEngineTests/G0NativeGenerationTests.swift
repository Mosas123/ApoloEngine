import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0NativeGenerationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_NATIVE_GENERATION"] == "1")
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
#if G0_NATIVE_GENERATION
    private func nativeFixture(seconds:Int=8) throws -> URL {
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
            print("G0_4B104_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B104_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B104_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name:String) async throws{
        let candidate=ProcessInfo.processInfo.environment["APOLO_G0_NATIVE_GENERATION_CANDIDATE"]=="1"
        print("G0_4B104_PROCESS pid=\(getpid()) scenario=\(name) candidate=\(candidate)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a=try nativeFixture(),b=try fixture(seconds:8,marker:500),c=try fixture(seconds:8,marker:250)
        defer{for u in [a,b,c]{try? FileManager.default.removeItem(at:u)}}
        let e=ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events=Events()
        e.setDiagnosticHandler{events.record($0)}
        e.limiterEnabled=false
        defer{e.stop()}
        var expected="";var observed=""
        if name=="NativeToLibav" || name=="NativeAfterStop" || name=="NativeReload"{
            try await load(e,a,.avPlayer,events)
            let trace=e.g0NativeCallbacks()
            let tick=try XCTUnwrap(e.g0NativeTick())
            if name=="NativeToLibav"{
                try await load(e,b,.libavcodec,events)
                await e.enqueueNext(ApoloTrack(url:c))
                try require(e.nextTracks.count==1,"upcoming fixture missing")
            }else if name=="NativeAfterStop"{e.stop()}
            else{try await load(e,a,.avPlayer,events)}
            // Invoke the saved periodic observer closure registered by the host.
            tick(CMTime(seconds:7654.25,preferredTimescale:600))
            let tickAccepted=e.elapsed==7654.25
            trace.0?(.failed("g0 retired native"))
            let failed=e.state == .failed("g0 retired native")
            trace.1?(9876.25)
            let time=e.elapsed==9876.25
            trace.2?()
            let changed=e.currentTrack?.url==c
            try require(tickAccepted == !candidate,"retired tick acceptance")
            try require(failed == (!candidate && name != "NativeToLibav"),"retired state acceptance")
            try require(time == !candidate,"retired time acceptance")
            try require(changed == (!candidate && name=="NativeToLibav"),"retired track acceptance")
            if name=="NativeAfterStop"{try require(e.currentTrack==nil,"stop queue resurrected")}
            if name=="NativeReload"{
                let current=e.g0NativeCallbacks()
                current.0?(.failed("g0 current native"))
                try require(e.state == .failed("g0 current native"),"current state rejected")
                current.1?(123.25)
                try require(e.elapsed==123.25,"current time rejected")
                observed="currentStateAndTime=true"
            }else{observed="upcoming=\(e.nextTracks.count) epoch=\(e.loadEpoch)"}
            expected="stateAccepted=\(failed) timeAccepted=\(time) trackAccepted=\(changed) tickAccepted=\(tickAccepted)"
        }else if name=="NaturalNativeNext"{
            let shortA=try nativeFixture(seconds:1),shortB=try nativeFixture(seconds:2)
            defer{try? FileManager.default.removeItem(at:shortA);try? FileManager.default.removeItem(at:shortB)}
            try await load(e,shortA,.avPlayer,events)
            await e.enqueueNext(ApoloTrack(url:shortB))
            try require(e.nextTracks.count==1,"missing native successor")
            e.play()
            let advanced=await wait{e.currentTrack?.url==shortB}
            try require(advanced,"legitimate natural transition missing")
            let finished=await wait{e.state == .finished}
            try require(finished,"legitimate finished missing")
            expected="naturalTrack=true finished=true"
            observed="upcoming=\(e.nextTracks.count)"
        }else{
            try await load(e,b,.libavcodec,events)
            let old=e.loadEpoch
            if name=="LibavToNative"{try await load(e,a,.avPlayer,events)}
            else{try await load(e,c,.libavcodec,events)}
            let active=e.loadEpoch
            XCTAssertNotEqual(old,active)
            let callbackEpoch=name=="LibavToNative" ? active:old
            // Current epoch/wrong route OR retired epoch/current route.
            e.g0InjectDecoder(.failed("g0 retired decoder"),9876.25,ApoloTrack(url:b),callbackEpoch)
            try await Task.sleep(for:.milliseconds(200))
            XCTAssertNotEqual(e.state,.failed("g0 retired decoder"))
            XCTAssertNotEqual(e.elapsed,9876.25)
            XCTAssertEqual(e.currentTrack?.url,name=="LibavToNative" ? a:c)
            expected="stateAccepted=false timeAccepted=false trackAccepted=false"
            observed="epoch=\(active) callbackEpoch=\(callbackEpoch)"
            if name=="LibavReload"{
                e.g0InjectDecoder(.failed("g0 current decoder"),9876.25,ApoloTrack(url:b),active)
                let accepted=await wait{e.currentTrack?.url==b}
                XCTAssertTrue(accepted)
                // Observe the current callback positive control without assuming
                // timing of subsequent actual renderer callbacks.
                observed+=" currentTrackAccepted=true"
            }
        }
        e.stop();XCTAssertEqual(e.state,.idle);XCTAssertNil(e.currentTrack)
        print("G0_4B104_CONTROL scenario=\(name) candidate=\(candidate) \(expected) rendererPrerequisites=true stopped=true metadataOff=true")
        print("G0_4B104_OBSERVATION scenario=\(name) candidate=\(candidate) \(observed)")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws{
#if G0_NATIVE_GENERATION
        try await run(name)
#else
        throw XCTSkip("runner-only route callback observation")
#endif
    }
    @MainActor func testNativeToLibav() async throws{try await scenario("NativeToLibav")}
    @MainActor func testNativeAfterStop() async throws{try await scenario("NativeAfterStop")}
    @MainActor func testNativeReload() async throws{try await scenario("NativeReload")}
    @MainActor func testLibavToNative() async throws{try await scenario("LibavToNative")}
    @MainActor func testNaturalNativeNext() async throws{try await scenario("NaturalNativeNext")}
    @MainActor func testLibavReload() async throws{try await scenario("LibavReload")}
}
