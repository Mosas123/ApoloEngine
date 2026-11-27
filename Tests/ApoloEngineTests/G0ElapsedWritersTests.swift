import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0ElapsedWritersTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_ELAPSED_WRITERS"] == "1")
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
#if G0_ELAPSED_WRITERS
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
            print("G0_4B1062_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B1062_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B1062_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name: String) async throws {
        let seek = ProcessInfo.processInfo.environment["APOLO_G0_SEEK_OWNERSHIP_CANDIDATE"] == "1"
        let callbacks = ProcessInfo.processInfo.environment["APOLO_G0_NATIVE_GENERATION_CANDIDATE"] == "1"
        print("G0_4B1062_PROCESS pid=\(getpid()) scenario=\(name) seek=\(seek) callbacks=\(callbacks)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a = try nativeFixture()
        defer { try? FileManager.default.removeItem(at:a) }
        let e = ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events = Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled = false
        defer { e.g0ReleaseSeekGate(); e.stop() }
        try await load(e,a,.avPlayer,events)
        let epoch = e.loadEpoch
        let oldTick = e.g0NativeTick()
        let oldTime = e.g0SavedTime()
        try require(oldTick != nil && oldTime != nil,"installed native callbacks missing")
        e.g0ArmSeekGate()
        let task = Task { @MainActor in await e.seek(to: 2.0) }
        let held = await wait { e.g0SeekGateEntered }
        try require(held && e.g0SeekSucceeded && abs(e.currentTime-2.0)<0.05,"actual native seek prerequisite")
        try require(e.g0SeekPublications.isEmpty,"premature seek publication")
        e.g0Mark("beforeCommand")
        if name != "Normal" { e.stop() }
        e.g0Mark("afterCommand")
        let commandElapsed = e.elapsed
        let commandClock = e.currentTime
        // First preserve natural delivery, separately from intentional injections.
        e.g0ReleaseSeekGate()
        await task.value
        e.g0Mark("afterRelease")
        let releaseElapsed = e.elapsed
        let releaseClock = e.currentTime
        try await Task.sleep(for:.milliseconds(350))
        e.g0Mark("afterNaturalWindow")
        let naturalElapsed = e.elapsed
        let naturalClock = e.currentTime
        let naturalWrites = e.g0Trace.filter{$0.contains("writer=nativeTime") && ($0.contains("phase=afterCommand") || $0.contains("phase=afterRelease"))}
        var injectedTickAccepted = false
        var injectedTimeAccepted = false
        if name == "InjectedStop" {
            e.g0Mark("injectTick")
            oldTick?(CMTime(seconds:7654.25,preferredTimescale:600))
            injectedTickAccepted = abs(e.elapsed-7654.25)<0.001
            e.g0Mark("injectTime")
            oldTime?(9876.25)
            injectedTimeAccepted = abs(e.elapsed-9876.25)<0.001
        }
        let order = e.g0SeekPublications.isEmpty ? "none" : e.g0SeekPublications.map{String(Int($0))}.joined(separator:",")
        let invariant = name == "Normal" ? abs(e.elapsed-e.currentTime)<0.05 : e.state == .idle && e.currentTrack == nil && abs(e.elapsed)<0.05 && abs(e.currentTime)<0.05
        print("G0_4B1062_CONTROL scenario=\(name) seek=\(seek) callbacks=\(callbacks) publicationOrder=\(order) suppressed=\(e.g0SeekSuppressionCount) tickAccepted=\(injectedTickAccepted) timeAccepted=\(injectedTimeAccepted) metadataOff=true")
        print("G0_4B1062_OBSERVATION scenario=\(name) seek=\(seek) callbacks=\(callbacks) epochBefore=\(epoch) epochAfter=\(e.loadEpoch) commandElapsed=\(commandElapsed) commandClock=\(commandClock) releaseElapsed=\(releaseElapsed) releaseClock=\(releaseClock) naturalElapsed=\(naturalElapsed) naturalClock=\(naturalClock) finalElapsed=\(e.elapsed) finalClock=\(e.currentTime) invariant=\(invariant) naturalPostCommandWrites=\(naturalWrites.count)")
        for line in e.g0Trace { print("G0_4B1062_TRACE \(line)") }
        try require(!e.g0SeekGateTimedOut,"gate timeout")
        try require(e.g0SeekPublications == (seek && name != "Normal" ? [] : [2.0]),"publication order")
        try require(e.g0SeekSuppressionCount == (seek && name != "Normal" ? 1 : 0),"suppression count")
        if name == "InjectedStop" {
            try require(injectedTickAccepted == !callbacks && injectedTimeAccepted == !callbacks,"saved callback protection")
        }
        // Preserve strict invariant in the combined candidate and normal controls.
        // Other modes are causal observations, not approval of their idle state.
        if name == "Normal" || (seek && callbacks) { try require(invariant,"strict elapsed/clock invariant") }
        e.stop()
        e.g0Mark("finalStop")
        try require(e.state == .idle && e.currentTrack == nil && e.nextTracks.isEmpty && e.elapsed == 0,"final stop cleanup")
        print("G0_4B1062_STOP scenario=\(name) empty=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_ELAPSED_WRITERS
        try await run(name)
#else
        throw XCTSkip("runner-only elapsed writer observation")
#endif
    }
    @MainActor func testStop() async throws { try await scenario("Stop") }
    @MainActor func testInjectedStop() async throws { try await scenario("InjectedStop") }
    @MainActor func testNormal() async throws { try await scenario("Normal") }
}
