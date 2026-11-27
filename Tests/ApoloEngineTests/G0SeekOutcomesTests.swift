import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0SeekOutcomesTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_OUTCOMES"] == "1")
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
#if G0_SEEK_OUTCOMES
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
            print("G0_4B107_START route=libavcodec epoch=\(epoch) firstPCM=true clockAdvanced=true state=\(state) clockBefore=\(first) clockAfter=\(second)")
            // Observe public state, do not manufacture Playing via play().
            // A missing finite Playing transition is a finding, not a startup prerequisite.
        }else{
            let playing=await wait{e.state == .playing}
            try require(playing,"native route must publish playing")
            let first=e.currentTime
            let advanced=await wait({e.currentTime >= first+0.15},seconds:4)
            try require(advanced,"native clock did not advance 150ms")
            print("G0_4B107_START route=avPlayer epoch=\(epoch) clockAdvanced=true state=\(e.state) clockBefore=\(first) clockAfter=\(e.currentTime)")
        }
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"actual route must pause")
        let before=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-before)
        try require(drift<0.05,"paused clock drift exceeded 50ms")
        print("G0_4B107_PAUSE route=\(route) epoch=\(epoch) drift=\(drift)")
    }
    @MainActor private func run(_ name:String) async throws {
        print("G0_4B107_PROCESS pid=\(getpid()) scenario=\(name)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        try require(ProcessInfo.processInfo.environment["APOLO_G0_SEEK_PROFILE"] == name,"profile environment mismatch")
        let native = name.hasPrefix("Native")
        let noItem = name == "NativeNoItem"
        let e = ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events = Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled = false
        defer { e.g0OutcomeRelease(); e.stop() }
        if !noItem {
            let url: URL
            if native { url = try nativeFixture() } else { url = try fixture(seconds:8,marker:100) }
            defer { try? FileManager.default.removeItem(at:url) }
            try await load(e,url,native ? .avPlayer : .libavcodec,events)
            // Keep the source file until all worker activity and cleanup finish.
            try await exercise(e,events,name,native)
        } else {
            try await exercise(e,events,name,native)
        }
    }
    @MainActor private func exercise(_ e:ApoloEngine,_ events:Events,_ name:String,_ native:Bool) async throws {
        let epoch = e.loadEpoch
        let before = e.currentTime
        let target = 2.0
        let noItem = name == "NativeNoItem"
        if native {
            await e.seek(to:target)
            let result = e.g0OutcomeNativeResult
            let elapsed = e.elapsed
            let clock = e.currentTime
            print("G0_4B107_OBSERVATION scenario=\(name) nativeResult=\(result) before=\(before) elapsed=\(elapsed) clock=\(clock) epoch=\(epoch) track=\(e.currentTrack != nil) publications=\(e.g0OutcomePublications)")
            try require(e.g0OutcomePublications == [target],"original engine publication missing")
            if name == "NativeNormal" {
                try require(result && abs(clock-target)<0.05,"native success positive control")
            }
            if noItem { try require(e.currentTrack == nil,"unexpected item") }
            // CancelPendingSeeks is real; completion false is observed, not assumed.
        } else {
            await e.seek(to:target)
            let held = await wait { events.all().contains{$0.hasPrefix("g0.outcome entered ")} }
            try require(held,"worker did not reach gate")
            let immediateElapsed = e.elapsed
            let immediateClock = e.currentTime
            let preCompletion = events.all().contains{$0.hasPrefix("g0.outcome result ")}
            print("G0_4B107_PENDING scenario=\(name) before=\(before) elapsed=\(immediateElapsed) clock=\(immediateClock) completion=\(preCompletion) publications=\(e.g0OutcomePublications)")
            try require(!preCompletion && e.g0OutcomePublications == [target],"worker gate/publication prerequisite")
            if name == "LibavStopQueued" { e.stop() }
            let commandEpoch=e.loadEpoch
            e.g0OutcomeRelease()
            let completed=await wait { events.all().contains{$0.hasPrefix("g0.outcome result ")} }
            try require(completed,"missing worker outcome")
            if name == "LibavStopQueued" {
                let stopped=await wait {
                    let lines=events.all()
                    guard let index=lines.firstIndex(where:{$0.hasPrefix("g0.outcome result ")}) else { return false }
                    return lines.dropFirst(index+1).contains{$0.hasPrefix("g0.outcome stopped ")}
                }
                try require(stopped,"queued stop missing")
            }
            try await Task.sleep(for:.milliseconds(350))
            let records=events.all().filter{$0.hasPrefix("g0.outcome ")}
            for record in records { print("G0_4B107_WORKER \(record)") }
            print("G0_4B107_OBSERVATION scenario=\(name) epochBefore=\(epoch) commandEpoch=\(commandEpoch) elapsed=\(e.elapsed) clock=\(e.currentTime) state=\(e.state) track=\(e.currentTrack != nil)")
            let expected = name == "LibavInjectedFailure" ? "injectedFailure" : "success"
            try require(records.contains{$0.hasPrefix("g0.outcome result outcome=\(expected) ") },"unexpected worker result")
            if name == "LibavNormal" { try require(abs(e.currentTime-target)<0.05,"libav positive clock control") }
            if name == "LibavStopQueued" { try require(e.currentTrack == nil && e.state == .idle && abs(e.currentTime)<0.05,"stop cleanup after worker") }
        }
        e.stop()
        try require(e.state == .idle && e.currentTrack == nil && e.nextTracks.isEmpty && e.elapsed == 0,"final cleanup")
        print("G0_4B107_CONTROL scenario=\(name) metadataOff=true cleanup=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_SEEK_OUTCOMES
        try await run(name)
#else
        throw XCTSkip("runner-only seek outcomes")
#endif
    }
    @MainActor func testNativeNormal() async throws { try await scenario("NativeNormal") }
    @MainActor func testNativeNoItem() async throws { try await scenario("NativeNoItem") }
    @MainActor func testNativeCancelPending() async throws { try await scenario("NativeCancelPending") }
    @MainActor func testLibavNormal() async throws { try await scenario("LibavNormal") }
    @MainActor func testLibavInjectedFailure() async throws { try await scenario("LibavInjectedFailure") }
    @MainActor func testLibavStopQueued() async throws { try await scenario("LibavStopQueued") }
}
