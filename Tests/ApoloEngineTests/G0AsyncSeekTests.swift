import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0AsyncSeekTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_ASYNC_SEEK"] == "1")
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
#if G0_ASYNC_SEEK
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
            print("G0_4B106_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B106_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B106_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name: String) async throws {
        print("G0_4B106_PROCESS pid=\(getpid()) scenario=\(name)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a = try nativeFixture(), b = try nativeFixture(), w = try fixture(seconds: 8, marker: 500)
        defer { for u in [a,b,w] { try? FileManager.default.removeItem(at:u) } }
        let e = ApoloEngine(managesSystemMediaControls:false, managesAudioSession:false)
        let events = Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled = false
        defer { e.g0ReleaseSeekGate(); e.stop() }
        try await load(e,a,.avPlayer,events)
        let oldEpoch = e.loadEpoch
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
        try require(publications == (name == "Overlap" ? [4.0,2.0]:[2.0]),"original publication order")
        let after = e.currentTime
        let difference = abs(after - 2.0)
        let stale = name != "Normal"
        try require(stale ? difference > 1.0 : difference < 0.05,"host/publication relationship")
        try require((oldEpoch != active) == (name == "Stop" || name == "Reload" || name == "Switch"),"unexpected epoch")
        if name == "Stop" { try require(e.currentTrack == nil,"stop resurrected track") }
        if name == "Reload" { try require(e.currentTrack?.url == b,"reload track changed") }
        if name == "Switch" { try require(e.currentTrack?.url == w && e.diagnostics.route == .libavcodec,"switch track changed") }
        print("G0_4B106_CONTROL scenario=\(name) stalePublication=\(stale) nativeSeekSuccess=true publicationOrder=\(publications.map{String(Int($0))}.joined(separator:",")) metadataOff=true")
        print("G0_4B106_OBSERVATION scenario=\(name) oldEpoch=\(oldEpoch) activeEpoch=\(active) clockBefore=\(before) clockAfter=\(after) elapsedBefore=\(elapsedBefore) elapsedAfter=\(e.elapsed) published=\(publications.last!) mismatch=\(difference) state=\(e.state)")
        e.stop()
        try require(e.currentTrack == nil && e.nextTracks.isEmpty && e.state == .idle && e.elapsed == 0,"final stop cleanup")
        print("G0_4B106_STOP scenario=\(name) empty=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_ASYNC_SEEK
        try await run(name)
#else
        throw XCTSkip("runner-only async seek observation")
#endif
    }
    @MainActor func testStop() async throws { try await scenario("Stop") }
    @MainActor func testReload() async throws { try await scenario("Reload") }
    @MainActor func testSwitch() async throws { try await scenario("Switch") }
    @MainActor func testOverlap() async throws { try await scenario("Overlap") }
    @MainActor func testNormal() async throws { try await scenario("Normal") }
}
