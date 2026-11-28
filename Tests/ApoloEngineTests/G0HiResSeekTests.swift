import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0HiResSeekTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_HIRES_ORACLE"] == "1")
    }
#if G0_HIRES_ORACLE
    private var rate=96000
    private var frames:Int {rate*8}
    // Signed 24-bit words with varying low bits, exactly representable in Float32.
    private func value(_ i:Int,_ ch:Int)->Int {
        ch==0 ? i-4194304 : ((i*17)&0xffffff)-8388608
    }
    private func pcm(_ b:CMSampleBuffer) throws -> [Float] {
        let desc=try XCTUnwrap(CMSampleBufferGetFormatDescription(b))
        let asbd=try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(desc)).pointee
        try require(asbd.mSampleRate==Double(rate) && asbd.mChannelsPerFrame==2 && asbd.mBitsPerChannel==32,"output sample rate, channel count or PCM width")
        let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(b))
        let n=CMSampleBufferGetNumSamples(b)*2
        guard n>0, CMBlockBufferGetDataLength(block)==n*4 else { throw NSError(domain:"G0LosslessPCM",code:1) }
        var values=[Float](repeating:0,count:n)
        let status=values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
        XCTAssertEqual(status,kCMBlockBufferNoErr)
        return values
    }
    private func index(_ v:[Float],_ offset:Int)->Int? {
        guard offset>=0,offset*2+1<v.count else{return nil}
        let l=v[offset*2]*8388608, r=v[offset*2+1]*8388608
        guard l.isFinite,r.isFinite,l==l.rounded(),r==r.rounded(),abs(l)<=8388608,abs(r)<=8388608 else{return nil}
        let i=Int(l)+4194304
        guard (0..<frames).contains(i),Int(r)==value(i,1) else{return nil}
        return i
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
        let first=index(a,ramp).map{$0-ramp}
        let rampSpansFirst=n<=ramp
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
        print("G0_4B10753_OBSERVATION ordinal=\(ordinal) target=\(target) status=\(status) ptsTick=\(field(p)) actualIndex=\(field(first)) ptsError=\(field(ptsError)) sampleError=\(field(contentError)) ptsContentError=\(field(ptsContent)) frames=\(n) nextFrames=\(m) nextIndex=\(field(second)) nextTick=\(field(q)) rampExcluded=\(min(ramp,n+m)) rampSpansFirst=\(rampSpansFirst) compared=\(compared) mismatch=\(mismatch) continuity=\(field(continuity)) ptsContinuity=\(field(ptsContinuity)) exact=\(exact)")
    }
    private func run(_ codec:String,_ sampleRate:Int,_ profile:String) throws {
        rate=sampleRate
        let scenario=codec+String(rate)+profile
        let env=ProcessInfo.processInfo.environment
        let mode=env["APOLO_G0_HIRES_MODE"] ?? ""
        try require(["original","noFlush","trim","both"].contains(mode),"mode")
        try require(env["APOLO_G0_HIRES_PROFILE"]==scenario,"profile")
        print("G0_4B10753_PROCESS pid=\(getpid()) scenario=\(scenario) codec=\(codec) rate=\(rate) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let encoded=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(G0HiResFixtureData.files[codec+String(rate)])))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+(codec=="FLAC" ? ".flac" : ".m4a"))
        try encoded.write(to:url)
        defer{try? FileManager.default.removeItem(at:url)}
        let linearDecoder=configured()
        defer{linearDecoder.close()}
        try linearDecoder.open(url:url,httpHeaders:[:])
        var reference:[Float]=[], boundaries:[Int]=[]
        var ptsMismatch=0
        while let buf=try linearDecoder.readNextBuffer() {
            let offset=reference.count/2
            boundaries.append(offset)
            if tick(buf) != offset {ptsMismatch+=1}
            reference += try pcm(buf)
        }
        try require(reference.count==frames*2,"linear frame count")
        var mismatch=0
        for i in 0..<frames {
            if reference[i*2] != Float(value(i,0))/8388608 || reference[i*2+1] != Float(value(i,1))/8388608 {mismatch+=1}
        }
        print("G0_4B10753_LINEAR codec=\(codec) rate=\(rate) frames=\(reference.count/2) buffers=\(boundaries.count) pcmMismatch=\(mismatch) ptsMismatch=\(ptsMismatch) firstBlock=\(boundaries.count>1 ? boundaries[1] : -1)")
        try require(mismatch==0 && ptsMismatch==0,"linear PCM or PTS mismatch")
        let boundary=try XCTUnwrap(boundaries.min(by:{abs($0-rate*2)<abs($1-rate*2)}))
        let d=profile=="AfterEOF" ? linearDecoder : configured()
        defer{if profile != "AfterEOF" {d.close()}}
        if profile != "AfterEOF" {
            try d.open(url:url,httpHeaders:[:])
            let initial=try XCTUnwrap(d.readNextBuffer())
            let initialPCM=try pcm(initial)
            try require(initialPCM.elementsEqual(reference.prefix(initialPCM.count)) && tick(initial)==0,"fresh initial PCM/PTS mismatch")
            print("G0_4B10753_INITIAL frames=\(initialPCM.count/2)")
        } else {print("G0_4B10753_EOF frames=\(frames)")}
        let targets:[Int]
        switch profile {
        case "Boundary":targets=[boundary,boundary+1]
        case "Repeated":targets=[rate*2,rate*3,rate+1]
        case "AfterEOF":targets=[rate*3]
        default: XCTFail("unknown profile");return
        }
        for (i,target) in targets.enumerated(){try inspect(d,reference,target,i+1)}
        d.close()
        if profile != "AfterEOF" {linearDecoder.close()}
        print("G0_4B10753_CONTROL scenario=\(scenario) mode=\(mode) observations=\(targets.count) metadataOff=true cleanup=true")
    }
#endif
    private func scenario(_ codec:String,_ rate:Int,_ profile:String) throws {
#if G0_HIRES_ORACLE
        try run(codec,rate,profile)
#else
        throw XCTSkip("runner-only lossless seek oracle")
#endif
    }
    func testFLAC96000Boundary() throws {try scenario("FLAC",96000,"Boundary")}
    func testFLAC96000Repeated() throws {try scenario("FLAC",96000,"Repeated")}
    func testFLAC96000AfterEOF() throws {try scenario("FLAC",96000,"AfterEOF")}
    func testFLAC192000Boundary() throws {try scenario("FLAC",192000,"Boundary")}
    func testFLAC192000Repeated() throws {try scenario("FLAC",192000,"Repeated")}
    func testFLAC192000AfterEOF() throws {try scenario("FLAC",192000,"AfterEOF")}
    func testALAC96000Boundary() throws {try scenario("ALAC",96000,"Boundary")}
    func testALAC96000Repeated() throws {try scenario("ALAC",96000,"Repeated")}
    func testALAC96000AfterEOF() throws {try scenario("ALAC",96000,"AfterEOF")}
    func testALAC192000Boundary() throws {try scenario("ALAC",192000,"Boundary")}
    func testALAC192000Repeated() throws {try scenario("ALAC",192000,"Repeated")}
    func testALAC192000AfterEOF() throws {try scenario("ALAC",192000,"AfterEOF")}
}
