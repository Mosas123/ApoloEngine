import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0SeekOwnershipTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_OWNERSHIP"] == "1")
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
#if G0_SEEK_OWNERSHIP
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
            print("G0_4B1061_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B1061_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B1061_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name: String) async throws {
        let candidate = ProcessInfo.processInfo.environment["APOLO_G0_SEEK_OWNERSHIP_CANDIDATE"] == "1"
        print("G0_4B1061_PROCESS pid=\(getpid()) scenario=\(name) candidate=\(candidate)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a = try nativeFixture(seconds: name == "NaturalNext" ? 3 : 8), b = try nativeFixture(), w = try fixture(seconds: 8, marker: 500)
        defer { for u in [a,b,w] { try? FileManager.default.removeItem(at:u) } }
        let e = ApoloEngine(managesSystemMediaControls:false, managesAudioSession:false)
        let events = Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled = false
        defer { e.g0ReleaseSeekGate(); e.stop() }
        try await load(e,a,.avPlayer,events)
        let oldEpoch = e.loadEpoch
        let oldTrackGeneration = e.g0SeekTrackGeneration
        if name == "NaturalNext" {
            await e.enqueueNext(ApoloTrack(url:b))
            try require(e.nextTracks.count == 1,"successor reservation missing")
        }
        e.g0ArmSeekGate()
        let task = Task { @MainActor in await e.seek(to: 2.0) }
        let held = await wait { e.g0SeekGateEntered }
        try require(held,"native seek must return before gate")
        try require(e.g0SeekSucceeded,"actual AVQueuePlayer seek did not complete successfully")
        try require(abs(e.currentTime - 2.0) < 0.05,"actual host did not reach first seek target")
        try require(e.g0SeekPublications.isEmpty,"first seek already published")
        if name == "Stop" {
            e.stop()
            try require(e.state == .idle && e.currentTrack == nil,"stop prerequisite")
        } else if name == "Reload" {
            try await load(e,b,.avPlayer,events)
        } else if name == "Switch" {
            try await load(e,w,.libavcodec,events)
        } else if name == "NaturalNext" {
            e.play()
            let advanced = await wait { e.currentTrack?.url == b }
            try require(advanced,"natural next did not reach successor")
            e.pause()
            let paused = await wait { e.state == .paused }
            try require(paused,"successor did not pause")
            try require(e.loadEpoch == oldEpoch && e.g0SeekTrackGeneration != oldTrackGeneration,"natural transition identity prerequisite")
            let settled = await wait({abs(e.elapsed - e.currentTime) < 0.05},seconds:2)
            try require(settled,"successor elapsed did not settle")
        } else if name == "Overlap" {
            await e.seek(to: 4.0)
            try require(e.g0NativeSeekSucceeded,"second actual native seek failed")
            try require(abs(e.currentTime - 4.0) < 0.05,"host did not reach second seek target")
            try require(e.g0SeekPublications == [4.0],"second seek must publish first")
        }
        let active = e.loadEpoch
        let before = e.currentTime
        let elapsedBefore = e.elapsed
        try require(!e.g0SeekGateTimedOut,"gate timed out before command")
        e.g0ReleaseSeekGate()
        await task.value
        try require(!e.g0SeekGateTimedOut,"gate timeout")
        // Capture the actual assignment synchronously at the publication site;
        // later periodic callbacks can overwrite the public property.
        let publications = e.g0SeekPublications
        let stale = name != "Normal"
        let rejected = candidate && stale
        let expected: [TimeInterval] = name == "Overlap" ? (candidate ? [4.0] : [4.0,2.0]) : (rejected ? [] : [2.0])
        try require(publications == expected,"seek publication order")
        try require(e.g0SeekSuppressionCount == (rejected ? 1 : 0),"seek suppression count")
        let after = e.currentTime
        let difference = abs(after - 2.0)
        try require(stale ? difference > 1.0 : difference < 0.05,"host versus retired target")
        try require(abs(after - before) < 0.05,"release must not move paused host clock")
        try require((oldEpoch != active) == (name == "Stop" || name == "Reload" || name == "Switch"),"unexpected epoch")
        if name == "Stop" { try require(e.currentTrack == nil && e.state == .idle,"stop resurrected track or state") }
        if name == "Reload" || name == "NaturalNext" { try require(e.currentTrack?.url == b,"successor track changed") }
        if name == "Switch" { try require(e.currentTrack?.url == w && e.diagnostics.route == .libavcodec,"switch track changed") }
        if rejected {
            try require(abs(e.elapsed - after) < 0.05,"candidate elapsed must agree with current paused clock")
        }
        let order = publications.isEmpty ? "none" : publications.map{String(Int($0))}.joined(separator:",")
        print("G0_4B1061_CONTROL scenario=\(name) candidate=\(candidate) stalePublication=\(stale && !candidate) nativeSeekSuccess=true publicationOrder=\(order) suppressed=\(e.g0SeekSuppressionCount) metadataOff=true")
        print("G0_4B1061_OBSERVATION scenario=\(name) candidate=\(candidate) oldEpoch=\(oldEpoch) activeEpoch=\(active) oldTrackGeneration=\(oldTrackGeneration) trackGeneration=\(e.g0SeekTrackGeneration) clockBefore=\(before) clockAfter=\(after) elapsedBefore=\(elapsedBefore) elapsedAfter=\(e.elapsed) retiredTargetDifference=\(difference) elapsedMismatch=\(abs(e.elapsed-after)) state=\(e.state)")
        e.stop()
        try require(e.currentTrack == nil && e.nextTracks.isEmpty && e.state == .idle && e.elapsed == 0,"final stop cleanup")
        print("G0_4B1061_STOP scenario=\(name) empty=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_SEEK_OWNERSHIP
        try await run(name)
#else
        throw XCTSkip("runner-only async seek observation")
#endif
    }
    @MainActor func testStop() async throws { try await scenario("Stop") }
    @MainActor func testReload() async throws { try await scenario("Reload") }
    @MainActor func testSwitch() async throws { try await scenario("Switch") }
    @MainActor func testOverlap() async throws { try await scenario("Overlap") }
    @MainActor func testNaturalNext() async throws { try await scenario("NaturalNext") }
    @MainActor func testNormal() async throws { try await scenario("Normal") }
}
