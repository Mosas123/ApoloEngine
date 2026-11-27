import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0QueueReservationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_QUEUE_RESERVATION"] == "1")
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
#if G0_QUEUE_RESERVATION
    private func nativeFixture() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".m4a")
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let settings:[String:Any]=[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000]
        let file=try AVAudioFile(forWriting:url,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for ch in 0..<2 {for i in 0..<48000{buffer.floatChannelData![ch][i]=Float(i%97-48)/512}}
        for _ in 0..<8 {try file.write(from:buffer)}
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
            print("G0_4B1051_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B1051_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B1051_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name:String) async throws{
        let candidate=ProcessInfo.processInfo.environment["APOLO_G0_QUEUE_RESERVATION_CANDIDATE"]=="1"
        print("G0_4B1051_PROCESS pid=\(getpid()) scenario=\(name) candidate=\(candidate)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a=try nativeFixture(),b=try nativeFixture(),c=try nativeFixture(),w=try fixture(seconds:8,marker:500),z=try fixture(seconds:8,marker:250)
        defer{for u in [a,b,c,w,z]{try? FileManager.default.removeItem(at:u)}}
        let e=ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events=Events();e.setDiagnosticHandler{events.record($0)}
        e.limiterEnabled=false
        defer{e.g0ReleaseQueueGate();e.stop()}
        let initialLibav=name=="ClearLibav" || name=="SwitchToNative" || name=="StopLibav"
        try await load(e,initialLibav ? w:a,initialLibav ? .libavcodec:.avPlayer,events)
        let target=initialLibav ? z:b
        let old=e.loadEpoch
        let reservation=ApoloTrack(url:target)
        e.g0ArmQueueGate()
        let task=Task{@MainActor in await e.enqueueNext(reservation)}
        let held=await wait{e.g0QueueGateEntered}
        try require(held,"enqueue must reach post-probe gate")
        try require(e.g0QueueProbeSucceeded,"local probe must succeed before suspension")
        try require(e.nextTracks.count==1 && e.nextTracks.first?.url==target,"engine upcoming reservation missing")
        let beforeNative=e.g0NativeURLs().contains(target)
        let beforeLibav=await e.g0DecoderNext()
        try require(!beforeNative && beforeLibav != target,"target already dispatched")
        if name=="ClearNative" || name=="ClearLibav" || name=="ClearReenqueue"{
            e.clearQueue()
            try require(e.nextTracks.isEmpty,"clear must empty engine queue")
            if name=="ClearReenqueue"{
                await e.enqueueNext(reservation)
                try require(e.nextTracks.count==1 && e.g0NativeURLs().filter{$0==target}.count==1,"fresh reservation must dispatch once before stale release")
            }
        }else if name=="StopNative" || name=="StopLibav"{
            e.stop()
            try require(e.currentTrack==nil && e.nextTracks.isEmpty,"stop must empty engine queue")
        }else if name=="ReloadNative"{
            try await load(e,c,.avPlayer,events)
        }else if name=="SwitchToLibav"{
            try await load(e,w,.libavcodec,events)
        }else if name=="SwitchToNative"{
            try await load(e,c,.avPlayer,events)
        }
        let epoch=e.loadEpoch
        e.g0ReleaseQueueGate()
        await task.value
        let nativeCount=e.g0NativeURLs().filter{$0==target}.count
        let decoder=await e.g0DecoderNext()==target
        let engineCount=e.nextTracks.filter{$0.url==target}.count
        let cleared=name=="ClearNative" || name=="ClearLibav" || name=="StopNative" || name=="StopLibav"
        let stopped=name=="StopNative" || name=="StopLibav"
        let toDecoder=name=="ClearLibav" || name=="SwitchToLibav"
        let expectedDispatch = !(candidate && cleared)
        let expectedNative=expectedDispatch && !toDecoder ? (name=="ClearReenqueue" && !candidate ? 2:1):0
        try require(nativeCount==expectedNative,"native target multiplicity mismatch")
        try require(decoder == (expectedDispatch && toDecoder),"decoder target assignment mismatch")
        try require(engineCount == (cleared ? 0:1),"engine target multiplicity mismatch")
        try require((old==epoch)==(name=="ClearNative" || name=="ClearLibav" || name=="Normal" || name=="ClearReenqueue"),"unexpected epoch")
        if stopped && candidate {
            try require(e.state == .idle && e.currentTrack==nil && e.g0NativeURLs().isEmpty,"stop must stay idle and empty")
        }
        let suppressed=e.g0QueueSuppressionCount
        try require(suppressed == (candidate && (cleared || name=="ClearReenqueue") ? 1:0),"suppression count mismatch")
        print("G0_4B1051_CONTROL scenario=\(name) candidate=\(candidate) engineCount=\(engineCount) nativeCount=\(nativeCount) decoderContains=\(decoder) suppressed=\(suppressed) probe=true metadataOff=true")
        print("G0_4B1051_OBSERVATION scenario=\(name) candidate=\(candidate) oldEpoch=\(old) epoch=\(epoch) state=\(e.state) current=\(e.currentTrack != nil) nativeTotal=\(e.g0NativeURLs().count)")
        e.stop()
        let finalDecoder=await e.g0DecoderNext()
        try require(e.currentTrack==nil && e.nextTracks.isEmpty && e.g0NativeURLs().isEmpty && finalDecoder==nil,"final stop cleanup")
        print("G0_4B1051_STOP scenario=\(name) empty=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws{
#if G0_QUEUE_RESERVATION
        try await run(name)
#else
        throw XCTSkip("runner-only async queue observation")
#endif
    }
    @MainActor func testClearNative() async throws{try await scenario("ClearNative")}
    @MainActor func testClearLibav() async throws{try await scenario("ClearLibav")}
    @MainActor func testStopNative() async throws{try await scenario("StopNative")}
    @MainActor func testReloadNative() async throws{try await scenario("ReloadNative")}
    @MainActor func testSwitchToLibav() async throws{try await scenario("SwitchToLibav")}
    @MainActor func testSwitchToNative() async throws{try await scenario("SwitchToNative")}
    @MainActor func testClearReenqueue() async throws{try await scenario("ClearReenqueue")}
    @MainActor func testStopLibav() async throws{try await scenario("StopLibav")}
    @MainActor func testNormal() async throws{try await scenario("Normal")}
}
