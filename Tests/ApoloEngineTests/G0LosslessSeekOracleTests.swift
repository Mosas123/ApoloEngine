import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0LosslessSeekOracleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LOSSLESS_ORACLE"] == "1")
    }
#if G0_LOSSLESS_ORACLE
    private let rate=48000
    private let frames=384000
    // Two signed 16-bit words encode a unique index; exact Float32 conversion.
    private func value(_ i:Int,_ ch:Int)->Int16 {
        ch==0 ? Int16((i & 32767)-16384) : Int16((i >> 15)*1024-8192)
    }
    private func pcm(_ b:CMSampleBuffer) throws -> [Float] {
        let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(b))
        let n=CMSampleBufferGetNumSamples(b)*2
        guard n>0, CMBlockBufferGetDataLength(block)==n*4 else { throw NSError(domain:"G0LosslessPCM",code:1) }
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
    private func require(_ condition:Bool,_ message:String) throws {
        guard condition else { XCTFail(message); throw NSError(domain:"G0Lossless",code:1) }
    }
    private func configured() -> AudioDecoder {
        let d=AudioDecoder()
        d.limiterEnabled=false
        d.processingSettings = .flat
        return d
    }
    private func tick(_ b:CMSampleBuffer)->Int? {
        let p=CMSampleBufferGetPresentationTimeStamp(b).seconds*Double(rate)
        guard p.isFinite, abs(p)<Double(Int32.max) else {return nil}
        return Int(p.rounded())
    }
    private func inspect(_ d:AudioDecoder,_ reference:[Float],_ target:Int,_ ordinal:Int) throws {
        var a:[Float]=[], b:[Float]=[]
        var p:Int?=nil, q:Int?=nil
        var status="ok"
        do {
            try d.seek(to:Double(target)/Double(rate))
        } catch {
            status="seekError"
        }
        if status=="ok" {
            do {
                if let x=try d.readNextBuffer() { a=try pcm(x);p=tick(x) }
                if a.isEmpty { status="firstEOF" }
                else if let x=try d.readNextBuffer() { b=try pcm(x);q=tick(x) }
                else { status="secondEOF" }
            } catch { status="readError" }
        }
        let n=a.count/2, m=b.count/2
        let ramp=SeekTransientRamp.frameCount(sampleRate:Int32(rate))
        let joined=a+b
        let first=index(joined,ramp).map{$0-ramp}
        let secondOffset=max(0,ramp-n)
        let second=index(b,secondOffset).map{$0-secondOffset}
        var mismatch=0, compared=0
        for j in ramp..<(max(ramp,n+m)) {
            let expected:Int?
            if j<n {expected=first.map{$0+j}}
            else {expected=second.map{$0+j-n}}
            if let i=expected, i>=0, i<frames {
                if joined[j*2] != reference[i*2] || joined[j*2+1] != reference[i*2+1] {mismatch+=1}
            } else {mismatch+=1}
            compared+=1
        }
        let contentError=first.map{$0-target}
        let ptsError=p.map{$0-target}
        let ptsContent=p.flatMap{pt in first.map{pt-$0}}
        let continuity=first.flatMap{i in second.map{$0-i-n}}
        let ptsContinuity=p.flatMap{i in q.map{$0-i-n}}
        let exact=status=="ok" && first==target && p==target && compared>0 && mismatch==0 && continuity==0 && ptsContinuity==0
        func field(_ x:Int?)->String {x.map{String($0)} ?? "nil"}
        print("G0_4B1075_OBSERVATION ordinal=\(ordinal) target=\(target) status=\(status) ptsTick=\(field(p)) actualIndex=\(field(first)) ptsError=\(field(ptsError)) sampleError=\(field(contentError)) ptsContentError=\(field(ptsContent)) frames=\(n) nextFrames=\(m) nextIndex=\(field(second)) nextTick=\(field(q)) rampExcluded=\(min(ramp,n+m)) compared=\(compared) mismatch=\(mismatch) continuity=\(field(continuity)) ptsContinuity=\(field(ptsContinuity)) exact=\(exact)")
    }
    private func run(_ codec:String,_ profile:String) throws {
        let env=ProcessInfo.processInfo.environment
        let mode=env["APOLO_G0_LOSSLESS_MODE"] ?? ""
        try require(["original","noFlush"].contains(mode),"mode")
        try require(env["APOLO_G0_LOSSLESS_PROFILE"]==codec+profile,"profile")
        print("G0_4B1075_PROCESS pid=\(getpid()) scenario=\(codec+profile) codec=\(codec) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let encoded=try XCTUnwrap(Data(base64Encoded:codec=="FLAC" ? G0LosslessFixtureData.flac : G0LosslessFixtureData.alac))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+(codec=="FLAC" ? ".flac" : ".m4a"))
        try encoded.write(to:url)
        defer{try? FileManager.default.removeItem(at:url)}
        let d=configured()
        defer{d.close()}
        try d.open(url:url,httpHeaders:[:])
        var reference:[Float]=[], boundaries:[Int]=[]
        var ptsMismatch=0
        while let buf=try d.readNextBuffer() {
            let offset=reference.count/2
            boundaries.append(offset)
            if tick(buf) != offset {ptsMismatch+=1}
            reference += try pcm(buf)
        }
        try require(reference.count==frames*2,"linear frame count")
        var mismatch=0
        for i in 0..<frames {
            if reference[i*2] != Float(value(i,0))/32768 || reference[i*2+1] != Float(value(i,1))/32768 {mismatch+=1}
        }
        print("G0_4B1075_LINEAR codec=\(codec) frames=\(reference.count/2) buffers=\(boundaries.count) pcmMismatch=\(mismatch) ptsMismatch=\(ptsMismatch) firstBlock=\(boundaries.count>1 ? boundaries[1] : -1)")
        try require(mismatch==0,"linear lossless PCM mismatch")
        let boundary=try XCTUnwrap(boundaries.min(by:{abs($0-96000)<abs($1-96000)}))
        if profile != "AfterEOF" {
            d.close()
            try d.open(url:url,httpHeaders:[:])
            let initial=try XCTUnwrap(d.readNextBuffer())
            let initialPCM=try pcm(initial)
            try require(initialPCM.elementsEqual(reference.prefix(initialPCM.count)),"fresh initial PCM mismatch")
            print("G0_4B1075_INITIAL frames=\(initialPCM.count/2)")
        } else {print("G0_4B1075_EOF frames=\(frames)")}
        let targets:[Int]
        switch profile {
        case "Single2":targets=[96000]
        case "Single3":targets=[144000]
        case "Boundary":targets=[boundary,boundary+1]
        case "Repeated":targets=[96000,144000,48001]
        case "AfterEOF":targets=[144000]
        default: XCTFail("unknown profile");return
        }
        for (i,target) in targets.enumerated(){try inspect(d,reference,target,i+1)}
        d.close()
        print("G0_4B1075_CONTROL scenario=\(codec+profile) mode=\(mode) observations=\(targets.count) metadataOff=true cleanup=true")
    }
#endif
    private func scenario(_ codec:String,_ profile:String) throws {
#if G0_LOSSLESS_ORACLE
        try run(codec,profile)
#else
        throw XCTSkip("runner-only lossless seek oracle")
#endif
    }
    func testFLACSingle2() throws {try scenario("FLAC","Single2")}
    func testFLACSingle3() throws {try scenario("FLAC","Single3")}
    func testFLACBoundary() throws {try scenario("FLAC","Boundary")}
    func testFLACRepeated() throws {try scenario("FLAC","Repeated")}
    func testFLACAfterEOF() throws {try scenario("FLAC","AfterEOF")}
    func testALACSingle2() throws {try scenario("ALAC","Single2")}
    func testALACSingle3() throws {try scenario("ALAC","Single3")}
    func testALACBoundary() throws {try scenario("ALAC","Boundary")}
    func testALACRepeated() throws {try scenario("ALAC","Repeated")}
    func testALACAfterEOF() throws {try scenario("ALAC","AfterEOF")}
}
