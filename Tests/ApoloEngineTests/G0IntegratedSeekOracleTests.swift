import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0IntegratedSeekOracleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_INTEGRATED_ORACLE"] == "1")
    }
#if G0_INTEGRATED_ORACLE
    private let rate=48000
    private let frames=384000
    // Two signed 16-bit words encode a unique index; exact Float32 conversion.
    private func value(_ i:Int,_ ch:Int)->Int16 {
        ch==0 ? Int16((i & 32767)-16384) : Int16((i >> 15)*1024-8192)
    }
    private func fixture() throws -> URL {
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func integer<T:FixedWidthInteger>(_ x:T){var v=x.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");integer(UInt32(36+frames*4));ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2))
        integer(UInt32(rate));integer(UInt32(rate*4));integer(UInt16(4));integer(UInt16(16));ascii("data");integer(UInt32(frames*4))
        for i in 0..<frames {integer(value(i,0));integer(value(i,1))}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try data.write(to:url);return url
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
    @MainActor private func run(_ profile:String) async throws {
        let mode=ProcessInfo.processInfo.environment["APOLO_G0_INTEGRATED_MODE"] ?? ""
        try require(["original","noFlush"].contains(mode),"invalid mode")
        try require(ProcessInfo.processInfo.environment["APOLO_G0_INTEGRATED_PROFILE"]==profile,"profile mismatch")
        print("G0_4B1074_PROCESS pid=\(getpid()) scenario=\(profile) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let e=ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events=Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled=false
        let url=try fixture()
        defer {
            e.g0IntegratedRelease(); e.g0IntegratedRelease(); e.stop()
            for line in events.all().filter({$0.hasPrefix("g0.integrated ")}) { print("G0_4B1074_TRACE \(line)") }
            try? FileManager.default.removeItem(at:url)
        }
        try await e.load(url:url)
        let epoch=e.loadEpoch
        try require(e.diagnostics.route == .libavcodec && e.currentTrack?.url==url,"actual libav route")
        func records(_ kind:String,_ seek:Int)->[String] {
            events.all().filter{$0.hasPrefix("g0.integrated \(kind) seek=\(seek) ")}
        }
        let initial=await wait{records("enqueued",0).count>=1}
        try require(initial,"initial enqueue missing")
        let initialPCM=try XCTUnwrap(records("enqueued",0).first)
        print("G0_4B1074_INITIAL \(initialPCM)")
        try require(initialPCM.contains("ptsTick=0 actualIndex=0 ") && initialPCM.contains("mismatch=0 "),"initial PCM not exact")
        let before=e.currentTime
        let advanced=await wait({e.currentTime>=before+0.15},seconds:4)
        try require(advanced,"startup clock not advancing")
        print("G0_4B1074_START epoch=\(epoch) before=\(before) after=\(e.currentTime) state=\(e.state)")
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"pause missing")
        let pauseClock=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-pauseClock)
        try require(drift<0.05,"pause drift")
        print("G0_4B1074_PAUSE drift=\(drift)")
        let doubleSeek=profile=="Sequential" || profile=="Overlap"
        let overlap=profile=="Overlap"
        let targets=doubleSeek ? [2.0,3.0] : [profile=="Single3" ? 3.0 : 2.0]
        func snapshot(_ seek:Int,_ target:Double) async throws {
            let ready=await wait{records("enqueued",seek).count>=1}
            try require(ready,"post-seek PCM enqueue missing")
            try await Task.sleep(for:.milliseconds(350))
            let pcm=try XCTUnwrap(records("enqueued",seek).first)
            let fields=Dictionary(uniqueKeysWithValues:pcm.split(separator:" ").compactMap { token -> (String,String)? in
                let p=token.split(separator:"=",maxSplits:1)
                return p.count==2 ? (String(p[0]),String(p[1])):nil
            })
            let tick=try XCTUnwrap(Int(fields["ptsTick"] ?? ""))
            let actual=try XCTUnwrap(Int(fields["actualIndex"] ?? ""))
            let mismatch=try XCTUnwrap(Int(fields["mismatch"] ?? ""))
            let targetTick=Int((target*48000).rounded())
            let clock=e.currentTime,elapsed=e.elapsed
            let strict=abs(clock-target)<0.06
            print("G0_4B1074_OBSERVATION scenario=\(profile) mode=\(mode) seek=\(seek) target=\(targetTick) ptsTick=\(tick) actualIndex=\(actual) mismatch=\(mismatch) clock=\(clock) elapsed=\(elapsed) strictClock=\(strict) publications=\(e.g0IntegratedPublications)")
            try require(mismatch==0 && e.loadEpoch==epoch && e.currentTrack?.url==url && e.state == .paused,"PCM integrity or session mismatch")
            try require(abs(clock-Double(tick)/48000)<0.001 && abs(elapsed-clock)<0.001,"clock not aligned to enqueued PTS")
            if mode=="noFlush" {
                try require(tick==targetTick && actual==targetTick && strict,"NoFlush seek not exact")
            } else {
                let expected=((targetTick+4095)/4096)*4096
                try require(tick==expected && actual==targetTick+expected,"original causal reproduction differs")
            }
        }
        await e.seek(to:targets[0])
        let firstHeld=await wait{records("entered",1).count==1}
        try require(firstHeld,"first worker not held")
        try require(e.g0IntegratedPublications==[targets[0]],"original pending publication")
        print("G0_4B1074_PENDING seek=1 clock=\(e.currentTime) elapsed=\(e.elapsed) publications=\(e.g0IntegratedPublications)")
        if overlap { await e.seek(to:targets[1]) }
        e.g0IntegratedRelease()
        let firstDone=await wait{records("result",1).count==1}
        try require(firstDone,"first worker result missing")
        if !overlap { try await snapshot(1,targets[0]) }
        if doubleSeek {
            if !overlap { await e.seek(to:targets[1]) }
            let secondHeld=await wait{records("entered",2).count==1}
            try require(secondHeld,"second worker not held")
            try require(e.g0IntegratedPublications==targets,"original two publications")
            print("G0_4B1074_PENDING seek=2 clock=\(e.currentTime) elapsed=\(e.elapsed) publications=\(e.g0IntegratedPublications)")
            e.g0IntegratedRelease()
            let done=await wait{records("result",2).count==1}
            try require(done,"second worker result missing")
            try await snapshot(2,targets[1])
        }
        for i in 1...targets.count {
            let result=try XCTUnwrap(records("result",i).first)
            try require(result.contains("success=true"),"worker failure")
        }
        e.stop()
        try require(e.state == .idle && e.currentTrack==nil && e.nextTracks.isEmpty && e.elapsed==0,"cleanup")
        print("G0_4B1074_CONTROL scenario=\(profile) mode=\(mode) workers=\(targets.count) metadataOff=true cleanup=true")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws {
#if G0_INTEGRATED_ORACLE
        try await run(name)
#else
        throw XCTSkip("runner-only integrated oracle")
#endif
    }
    @MainActor func testSingle2() async throws { try await scenario("Single2") }
    @MainActor func testSingle3() async throws { try await scenario("Single3") }
    @MainActor func testSequential() async throws { try await scenario("Sequential") }
    @MainActor func testOverlap() async throws { try await scenario("Overlap") }
}
