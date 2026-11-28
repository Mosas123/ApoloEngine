import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0IntegratedHiResTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_INTEGRATED_HIRES"] == "1")
    }
#if G0_INTEGRATED_HIRES
    private func fixture(_ codec:String,_ rate:Int) throws -> URL {
        let encoded=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(G0IntegratedHiResFixtureData.files[codec+String(rate)])))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+(codec=="FLAC" ? ".flac" : ".m4a"))
        try encoded.write(to:url)
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
    @MainActor private func run(_ codec:String,_ rate:Int,_ profile:String) async throws {
        let scenario=codec+String(rate)+profile
        let mode=ProcessInfo.processInfo.environment["APOLO_G0_RENDER_HIRES_MODE"] ?? ""
        try require(["original","noFlush","trim","both"].contains(mode),"invalid mode")
        try require(ProcessInfo.processInfo.environment["APOLO_G0_RENDER_HIRES_PROFILE"]==scenario,"profile mismatch")
        print("G0_4B10755_PROCESS pid=\(getpid()) scenario=\(scenario) codec=\(codec) rate=\(rate) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let e=ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        let events=Events()
        e.setDiagnosticHandler { events.record($0) }
        e.limiterEnabled=false
        let url=try fixture(codec,rate)
        defer {
            e.g0IntegratedRelease(); e.g0IntegratedRelease(); e.stop()
            for line in events.all().filter({$0.hasPrefix("g0.integrated ")}) { print("G0_4B10755_TRACE \(line)") }
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
        print("G0_4B10755_INITIAL \(initialPCM)")
        try require(initialPCM.contains("ptsTick=0 actualIndex=0 ") && initialPCM.contains("mismatch=0 ") && initialPCM.contains("preMismatch=0 ") && initialPCM.contains("deliveryMismatch=0 ") && initialPCM.contains("sourceRate=\(rate) "),"initial PCM not exact")
        let before=e.currentTime
        let advanced=await wait({e.currentTime>=before+0.15},seconds:4)
        try require(advanced,"startup clock not advancing")
        print("G0_4B10755_START epoch=\(epoch) before=\(before) after=\(e.currentTime) state=\(e.state)")
        e.pause()
        let paused=await wait{e.state == .paused}
        try require(paused,"pause missing")
        let pauseClock=e.currentTime
        try await Task.sleep(for:.milliseconds(150))
        let drift=abs(e.currentTime-pauseClock)
        try require(drift<0.05,"pause drift")
        print("G0_4B10755_PAUSE drift=\(drift)")
        let doubleSeek=profile=="Sequential" || profile=="Overlap"
        let overlap=profile=="Overlap"
        let shortTarget=Double(rate+1)/Double(rate)
        let targets=doubleSeek ? [2.0,overlap ? shortTarget : 3.0] : [profile=="SingleShort" ? shortTarget : 2.0]
        func snapshot(_ seek:Int,_ target:Double) async throws {
            let ready=await wait{records("enqueued",seek).count>=2}
            try require(ready,"two post-seek PCM enqueues missing")
            try await Task.sleep(for:.milliseconds(350))
            func parse(_ pcm:String) -> [String:String] {
                Dictionary(uniqueKeysWithValues:pcm.split(separator:" ").compactMap { token -> (String,String)? in
                    let p=token.split(separator:"=",maxSplits:1)
                    return p.count==2 ? (String(p[0]),String(p[1])):nil
                })
            }
            let pair=records("enqueued",seek)
            let first=parse(pair[0]), second=parse(pair[1])
            func field(_ f:[String:String],_ key:String) throws -> Int {try XCTUnwrap(Int(f[key] ?? ""))}
            let tick=try field(first,"ptsTick"), actual=try field(first,"actualIndex")
            let nextTick=try field(second,"ptsTick"), nextActual=try field(second,"actualIndex")
            let n=try field(first,"frames"), m=try field(second,"frames")
            let mismatch=try field(first,"mismatch"), mismatch2=try field(second,"mismatch")
            let targetTick=Int((target*Double(rate)).rounded())
            let pre=try field(first,"preMismatch")+field(second,"preMismatch")
            let delivery=try field(first,"deliveryMismatch")+field(second,"deliveryMismatch")
            let fade=Int((Double(rate)*0.003).rounded())
            let firstConsumed=try field(first,"consumed"), secondConsumed=try field(second,"consumed")
            let firstRate=try field(first,"sourceRate"), secondRate=try field(second,"sourceRate")
            try require(firstRate==rate && secondRate==rate,"source rate changed")
            try require(firstConsumed==min(n,fade) && secondConsumed==min(n+m,fade),"ramp consumption")
            let clock=e.currentTime,elapsed=e.elapsed
            let strict=abs(clock-target)<0.06
            let aligned=abs(clock-Double(tick)/Double(rate))<0.001 && abs(elapsed-clock)<0.001
            let contiguous=nextTick==tick+n && nextActual==actual+n && tick==actual && nextTick==nextActual
            let clockSampleExact=abs(clock*Double(rate)-Double(targetTick))<0.5 && abs(elapsed*Double(rate)-Double(targetTick))<0.5
            let exact=tick==targetTick && actual==targetTick && mismatch==0 && mismatch2==0 && pre==0 && delivery==0 && contiguous && aligned
            print("G0_4B10755_OBSERVATION scenario=\(scenario) mode=\(mode) seek=\(seek) target=\(targetTick) ptsTick=\(tick) actualIndex=\(actual) frames=\(n) nextTick=\(nextTick) nextActual=\(nextActual) nextFrames=\(m) mismatch=\(mismatch) nextMismatch=\(mismatch2) preMismatch=\(pre) deliveryMismatch=\(delivery) fade=\(fade) firstConsumed=\(firstConsumed) secondConsumed=\(secondConsumed) clock=\(clock) elapsed=\(elapsed) strictClock=\(strict) clockSampleExact=\(clockSampleExact) aligned=\(aligned) continuity=\(contiguous) exact=\(exact) publications=\(e.g0IntegratedPublications)")
            try require(mismatch==0 && mismatch2==0 && pre==0 && delivery==0 && n>0 && m>0 && e.loadEpoch==epoch && e.currentTrack?.url==url && e.state == .paused,"PCM integrity or session mismatch")
            try require(Double(first["rate"] ?? "")==0 && Double(second["rate"] ?? "")==0,"renderer rate not paused")
            try require(aligned && contiguous,"clock or PCM continuity mismatch")
            // Strict seek correctness is recorded separately from diagnostic completion.
        }
        await e.seek(to:targets[0])
        let firstHeld=await wait{records("entered",1).count==1}
        try require(firstHeld,"first worker not held")
        try require(e.g0IntegratedPublications==[targets[0]],"original pending publication")
        print("G0_4B10755_PENDING seek=1 clock=\(e.currentTime) elapsed=\(e.elapsed) publications=\(e.g0IntegratedPublications)")
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
            print("G0_4B10755_PENDING seek=2 clock=\(e.currentTime) elapsed=\(e.elapsed) publications=\(e.g0IntegratedPublications)")
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
        print("G0_4B10755_CONTROL scenario=\(scenario) mode=\(mode) workers=\(targets.count) metadataOff=true cleanup=true")
    }
#endif
    @MainActor private func scenario(_ codec:String,_ rate:Int,_ name:String) async throws {
#if G0_INTEGRATED_HIRES
        try await run(codec,rate,name)
#else
        throw XCTSkip("runner-only integrated oracle")
#endif
    }
    @MainActor func testFLAC96000Single2() async throws { try await scenario("FLAC",96000,"Single2") }
    @MainActor func testFLAC96000SingleShort() async throws { try await scenario("FLAC",96000,"SingleShort") }
    @MainActor func testFLAC96000Sequential() async throws { try await scenario("FLAC",96000,"Sequential") }
    @MainActor func testFLAC96000Overlap() async throws { try await scenario("FLAC",96000,"Overlap") }
    @MainActor func testFLAC192000Single2() async throws { try await scenario("FLAC",192000,"Single2") }
    @MainActor func testFLAC192000SingleShort() async throws { try await scenario("FLAC",192000,"SingleShort") }
    @MainActor func testFLAC192000Sequential() async throws { try await scenario("FLAC",192000,"Sequential") }
    @MainActor func testFLAC192000Overlap() async throws { try await scenario("FLAC",192000,"Overlap") }
    @MainActor func testALAC96000Single2() async throws { try await scenario("ALAC",96000,"Single2") }
    @MainActor func testALAC96000SingleShort() async throws { try await scenario("ALAC",96000,"SingleShort") }
    @MainActor func testALAC96000Sequential() async throws { try await scenario("ALAC",96000,"Sequential") }
    @MainActor func testALAC96000Overlap() async throws { try await scenario("ALAC",96000,"Overlap") }
    @MainActor func testALAC192000Single2() async throws { try await scenario("ALAC",192000,"Single2") }
    @MainActor func testALAC192000SingleShort() async throws { try await scenario("ALAC",192000,"SingleShort") }
    @MainActor func testALAC192000Sequential() async throws { try await scenario("ALAC",192000,"Sequential") }
    @MainActor func testALAC192000Overlap() async throws { try await scenario("ALAC",192000,"Overlap") }
}
