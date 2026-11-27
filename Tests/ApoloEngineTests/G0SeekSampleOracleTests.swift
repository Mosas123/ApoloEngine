import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0SeekSampleOracleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_SAMPLE_ORACLE"] == "1")
    }
#if G0_SAMPLE_ORACLE
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
    private func pcm(_ b:CMSampleBuffer) throws -> [Float] {
        let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(b))
        let n=CMSampleBufferGetNumSamples(b)*2
        var values=[Float](repeating:0,count:n)
        let status=values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
        XCTAssertEqual(status,kCMBlockBufferNoErr)
        return values
    }
    private func index(_ v:[Float],_ offset:Int)->Int? {
        guard offset*2+1<v.count else{return nil}
        let l=v[offset*2]*32768
        let r=v[offset*2+1]*32768
        guard l.isFinite,r.isFinite,l==l.rounded(),r==r.rounded(),abs(l)<=32768,abs(r)<=32768 else{return nil}
        let lo=Int(l)+16384,hi=Int(r)+8192
        guard (0..<32768).contains(lo),hi>=0,hi%1024==0 else{return nil}
        let i=(hi/1024)*32768+lo
        return (0..<frames).contains(i) ? i:nil
    }
    private func inspect(_ decoder:AudioDecoder,_ target:Int,_ label:String) throws {
        let b=try XCTUnwrap(decoder.readNextBuffer(),"seek returned nil")
        let v=try pcm(b)
        let n=v.count/2
        let ramp=SeekTransientRamp.frameCount(sampleRate:Int32(rate))
        XCTAssertGreaterThan(n,ramp+1)
        let anchor=try XCTUnwrap(index(v,ramp),"cannot identify first post-ramp sample")
        let actual=anchor-ramp
        let pts=CMSampleBufferGetPresentationTimeStamp(b).seconds
        let tick=Int((pts*Double(rate)).rounded())
        var mismatches=0
        for j in ramp..<n {
            let i=actual+j
            if i<0 || i>=frames || v[j*2] != Float(value(i,0))/32768 || v[j*2+1] != Float(value(i,1))/32768 {mismatches+=1}
        }
        let next=try XCTUnwrap(decoder.readNextBuffer())
        let nextV=try pcm(next)
        let nextIndex=try XCTUnwrap(index(nextV,0))
        let nextTick=Int((CMSampleBufferGetPresentationTimeStamp(next).seconds*Double(rate)).rounded())
        let nextN=nextV.count/2
        var nextMismatch=0
        for j in 0..<nextN {
            let i=nextIndex+j
            if i>=frames || nextV[j*2] != Float(value(i,0))/32768 || nextV[j*2+1] != Float(value(i,1))/32768 {nextMismatch+=1}
        }
        print("G0_4B1073_OBSERVATION label=\(label) target=\(target) ptsTick=\(tick) actualIndex=\(actual) ptsError=\(tick-target) sampleError=\(actual-target) ptsContentError=\(tick-actual) frames=\(n) rampExcluded=\(ramp) firstMismatch=\(mismatches) nextIndex=\(nextIndex) nextTick=\(nextTick) nextFrames=\(nextN) nextMismatch=\(nextMismatch) continuity=\(nextIndex-actual-n) ptsContinuity=\(nextTick-tick-n)")
        XCTAssertEqual(mismatches,0)
        XCTAssertEqual(nextMismatch,0)
    }
    private func run(_ profile:String) throws {
        let env=ProcessInfo.processInfo.environment
        let mode=env["APOLO_G0_SAMPLE_MODE"] ?? ""
        XCTAssertTrue(["original","noFlush","trim","both"].contains(mode))
        XCTAssertEqual(env["APOLO_G0_SAMPLE_PROFILE"],profile)
        print("G0_4B1073_PROCESS pid=\(getpid()) scenario=\(profile) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let url=try fixture()
        defer{try? FileManager.default.removeItem(at:url)}
        let d=AudioDecoder()
        d.limiterEnabled=false
        d.processingSettings = .flat
        defer{d.close()}
        try d.open(url:url,httpHeaders:[:])
        let initial=try XCTUnwrap(d.readNextBuffer())
        let initialPCM=try pcm(initial)
        let initialN=initialPCM.count/2
        XCTAssertEqual(index(initialPCM,0),0)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(initial).seconds,0)
        for j in 0..<initialN {
            XCTAssertEqual(initialPCM[j*2],Float(value(j,0))/32768)
            XCTAssertEqual(initialPCM[j*2+1],Float(value(j,1))/32768)
        }
        print("G0_4B1073_INITIAL frames=\(initialN) exact=true")
        if profile=="AfterEOF" {
            var count=initialN
            while let b=try d.readNextBuffer(){count += CMSampleBufferGetNumSamples(b)}
            XCTAssertEqual(count,frames)
            print("G0_4B1073_EOF frames=\(count)")
        }
        let targets:[Int]
        switch profile {
        case "Single2": targets=[96000]
        case "Single3": targets=[144000]
        case "Boundary": targets=[98304]
        case "Repeated": targets=[96000,144000,48001]
        case "AfterEOF": targets=[144000]
        default: XCTFail("unknown profile");return
        }
        for (i,target) in targets.enumerated(){
            print("G0_4B1073_SEEK ordinal=\(i+1) target=\(target)")
            try d.seek(to:Double(target)/Double(rate))
            try inspect(d,target,"\(profile)-\(i+1)")
        }
        d.close()
        print("G0_4B1073_CONTROL scenario=\(profile) mode=\(mode) observations=\(targets.count) metadataOff=true cleanup=true")
    }
#endif
    private func scenario(_ name:String) throws {
#if G0_SAMPLE_ORACLE
        try run(name)
#else
        throw XCTSkip("runner-only sample oracle")
#endif
    }
    func testSingle2() throws { try scenario("Single2") }
    func testSingle3() throws { try scenario("Single3") }
    func testBoundary() throws { try scenario("Boundary") }
    func testRepeated() throws { try scenario("Repeated") }
    func testAfterEOF() throws { try scenario("AfterEOF") }
}
