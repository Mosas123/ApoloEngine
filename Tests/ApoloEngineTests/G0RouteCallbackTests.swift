import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import ApoloEngine

final class G0RouteCallbackTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_ROUTE_CALLBACK"] == "1")
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
#if G0_ROUTE_CALLBACK
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
    @MainActor private func load(_ e:ApoloEngine,_ url:URL,_ route:AudioRoute) async throws{
        try await e.load(url:url)
        let playing=await wait{e.state == .playing}
        XCTAssertTrue(playing,"actual route must play")
        XCTAssertEqual(e.diagnostics.route,route)
        XCTAssertEqual(e.currentTrack?.url,url)
        e.pause()
        let paused=await wait{e.state == .paused}
        XCTAssertTrue(paused)
    }
    @MainActor private func run(_ name:String) async throws{
        print("G0_4B103_PROCESS pid=\(getpid()) scenario=\(name)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let a=try nativeFixture(),b=try fixture(seconds:8,marker:500),c=try fixture(seconds:8,marker:250)
        defer{for u in [a,b,c]{try? FileManager.default.removeItem(at:u)}}
        let e=ApoloEngine(managesSystemMediaControls:false,managesAudioSession:false)
        e.limiterEnabled=false
        defer{e.stop()}
        var expected="";var observed=""
        if name=="NativeToLibav"{
            try await load(e,a,.avPlayer)
            try await load(e,b,.libavcodec)
            await e.enqueueNext(ApoloTrack(url:c))
            XCTAssertEqual(e.nextTracks.count,1)
            let trace=e.g0NativeCallbacks()
            trace.0?(.failed("g0 retired native"))
            let failed=e.state == .failed("g0 retired native")
            trace.1?(9876.25)
            let time=e.elapsed == 9876.25
            trace.2?()
            let changed=e.currentTrack?.url==c
            XCTAssertFalse(failed);XCTAssertTrue(time);XCTAssertTrue(changed)
            expected="stateAccepted=false timeAccepted=true trackAccepted=true"
            observed="upcoming=\(e.nextTracks.count) epoch=\(e.loadEpoch)"
        }else if name=="NativeAfterStop"{
            try await load(e,a,.avPlayer)
            let trace=e.g0NativeCallbacks()
            e.stop()
            trace.0?(.failed("g0 retired native"));trace.1?(9876.25);trace.2?()
            let failed=e.state == .failed("g0 retired native"),time=e.elapsed==9876.25
            XCTAssertTrue(failed);XCTAssertTrue(time);XCTAssertNil(e.currentTrack)
            expected="stateAccepted=true timeAccepted=true trackAccepted=false"
            observed="epoch=\(e.loadEpoch) stoppedQueueEmpty=true"
        }else if name=="NativeReload"{
            try await load(e,a,.avPlayer)
            let trace=e.g0NativeCallbacks()
            // Native callbacks carry no generation; saved closure is deliberately injected.
            try await load(e,a,.avPlayer)
            trace.0?(.failed("g0 retired native"));trace.1?(9876.25)
            XCTAssertEqual(e.state,.failed("g0 retired native"));XCTAssertEqual(e.elapsed,9876.25)
            expected="stateAccepted=true timeAccepted=true trackTested=false"
            observed="epoch=\(e.loadEpoch) generationless=true"
        }else{
            try await load(e,b,.libavcodec)
            let old=e.loadEpoch
            if name=="LibavToNative"{try await load(e,a,.avPlayer)}
            else{try await load(e,c,.libavcodec)}
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
        print("G0_4B103_CONTROL scenario=\(name) \(expected) actualRoutes=true stopped=true metadataOff=true")
        print("G0_4B103_OBSERVATION scenario=\(name) \(observed)")
    }
#endif
    @MainActor private func scenario(_ name:String) async throws{
#if G0_ROUTE_CALLBACK
        try await run(name)
#else
        throw XCTSkip("runner-only route callback observation")
#endif
    }
    @MainActor func testNativeToLibav() async throws{try await scenario("NativeToLibav")}
    @MainActor func testNativeAfterStop() async throws{try await scenario("NativeAfterStop")}
    @MainActor func testNativeReload() async throws{try await scenario("NativeReload")}
    @MainActor func testLibavToNative() async throws{try await scenario("LibavToNative")}
    @MainActor func testLibavReload() async throws{try await scenario("LibavReload")}
}
