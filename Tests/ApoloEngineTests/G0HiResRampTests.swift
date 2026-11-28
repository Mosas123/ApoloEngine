import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0HiResRampTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_HIRES_RAMP_ORACLE"] == "1")
    }
#if G0_HIRES_RAMP_ORACLE
    private var rate=96000
    private var frames:Int {rate*8}
    // Signed 24-bit words with varying low bits, exactly representable in Float32.
    private func value(_ i:Int,_ ch:Int)->Int {
        ch==0 ? i-4194304 : ((i*17)&0xffffff)-8388608
    }
    private func pcm(_ b:CMSampleBuffer) throws -> [Float] {
        let desc=try XCTUnwrap(CMSampleBufferGetFormatDescription(b))
        let asbd=try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(desc)).pointee
        try require(asbd.mSampleRate==Double(rate) && asbd.mChannelsPerFrame==2 && asbd.mBitsPerChannel==32 && asbd.mFormatID==kAudioFormatLinearPCM && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,"output sample rate, channel count or Float32 format")
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
        let rounded=Int(p.rounded())
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(b),CMTime(value:Int64(rounded),timescale:Int32(rate)))==0 else{return nil}
        return rounded
    }
    // Independent scalar Float32 oracle: do not call SeekTransientRamp.apply here.
    private func expected(_ x:Float,_ offset:Int,_ fade:Int)->Float {
        offset<fade ? x * (Float(offset+1)/Float(fade)) : x
    }
    private func inspect(_ d:AudioDecoder,_ reference:[Float],_ target:Int,_ ordinal:Int,_ mode:String) throws {
        try d.seek(to:Double(target)/Double(rate))
        let first=try XCTUnwrap(d.readNextBuffer())
        let second=try XCTUnwrap(d.readNextBuffer())
        let a=try pcm(first), b=try pcm(second)
        let p=try XCTUnwrap(tick(first)), q=try XCTUnwrap(tick(second))
        let records=d.g0RampRecords
        try require(records.count==2,"two pre/post ramp records")
        let n=a.count/2,m=b.count/2
        let fade=Int((Double(rate)*0.003).rounded())
        try require(SeekTransientRamp.frameCount(sampleRate:Int32(rate))==fade,"fade length")
        let i=try XCTUnwrap(index(records[0].pre,0))
        let j=try XCTUnwrap(index(records[1].pre,0))
        var preMismatch=0,postMismatch=0,deliveryMismatch=0,shiftDetected=0,restartDetected=0
        var consumed=0
        for (k,rec) in records.enumerated() {
            let count=k==0 ? n:m
            let actual=k==0 ? i:j
            let delivered=k==0 ? a:b
            let pts=k==0 ? p:q
            try require(rec.pre.count==count*2 && rec.post.count==count*2 && rec.ticks==Int64(pts),"record shape/PTS")
            try require(rec.fade==fade && rec.before==min(fade,consumed) && rec.after==min(fade,consumed+count),"ramp consumed counter")
            try require(actual>=0 && actual+count<frames,"reference range with negative control")
            for f in 0..<count {
                for ch in 0..<2 {
                    let k=f*2+ch
                    let x=reference[(actual+f)*2+ch]
                    let want=expected(x,consumed+f,fade)
                    if rec.pre[k].bitPattern != x.bitPattern {preMismatch+=1}
                    if rec.post[k].bitPattern != want.bitPattern {postMismatch+=1}
                    if delivered[k].bitPattern != rec.post[k].bitPattern {deliveryMismatch+=1}
                    if rec.pre[k].bitPattern != reference[(actual+f+1)*2+ch].bitPattern {shiftDetected+=1}
                    if consumed>0 && rec.post[k].bitPattern != expected(x,f,fade).bitPattern {restartDetected+=1}
                }
            }
            consumed+=count
        }
        // Intentional one-ULP corruption: verify the equality predicate rejects it.
        let correct=expected(reference[i*2],0,fade)
        let ulpDetected=correct.nextUp.bitPattern != correct.bitPattern
        let contiguous=j==i+n && q==p+n
        let aligned=p==i && q==j
        let exact=preMismatch==0 && postMismatch==0 && deliveryMismatch==0 && contiguous && aligned && i==target && p==target
        print("G0_4B10754_OBSERVATION ordinal=\(ordinal) target=\(target) ptsTick=\(p) actualIndex=\(i) nextTick=\(q) nextIndex=\(j) frames=\(n) nextFrames=\(m) fade=\(fade) firstConsumed=\(records[0].after) secondConsumed=\(records[1].after) preMismatch=\(preMismatch) postMismatch=\(postMismatch) deliveryMismatch=\(deliveryMismatch) compared=\((n+m)*2) shiftDetected=\(shiftDetected) restartDetected=\(restartDetected) ulpDetected=\(ulpDetected) continuity=\(contiguous) aligned=\(aligned) exact=\(exact)")
        try require(preMismatch==0 && postMismatch==0 && deliveryMismatch==0 && contiguous && aligned,"ramp/PCM/PTS integrity")
        try require(shiftDetected>0 && ulpDetected && restartDetected>0,"negative controls must detect shifted content, restarted ramp and one ULP")
        // Target exactness is observational; preserve original seconds-to-ticks rounding.
    }
    private func run(_ codec:String,_ sampleRate:Int,_ profile:String) throws {
        rate=sampleRate
        let scenario=codec+String(rate)+profile
        let env=ProcessInfo.processInfo.environment
        let mode=env["APOLO_G0_RAMP_MODE"] ?? ""
        try require(["original","noFlush","trim","both"].contains(mode),"mode")
        try require(env["APOLO_G0_RAMP_PROFILE"]==scenario,"profile")
        print("G0_4B10754_PROCESS pid=\(getpid()) scenario=\(scenario) codec=\(codec) rate=\(rate) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let encoded=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(G0HiResRampFixtureData.files[codec+String(rate)])))
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
        print("G0_4B10754_LINEAR codec=\(codec) rate=\(rate) frames=\(reference.count/2) buffers=\(boundaries.count) pcmMismatch=\(mismatch) ptsMismatch=\(ptsMismatch) firstBlock=\(boundaries.count>1 ? boundaries[1] : -1)")
        try require(mismatch==0 && ptsMismatch==0,"linear PCM or PTS mismatch")
        let boundary=try XCTUnwrap(boundaries.min(by:{abs($0-rate*2)<abs($1-rate*2)}))
        let d=profile=="AfterEOF" ? linearDecoder : configured()
        defer{if profile != "AfterEOF" {d.close()}}
        if profile != "AfterEOF" {
            try d.open(url:url,httpHeaders:[:])
            let initial=try XCTUnwrap(d.readNextBuffer())
            let initialPCM=try pcm(initial)
            try require(initialPCM.elementsEqual(reference.prefix(initialPCM.count)) && tick(initial)==0,"fresh initial PCM/PTS mismatch")
            print("G0_4B10754_INITIAL frames=\(initialPCM.count/2)")
        } else {print("G0_4B10754_EOF frames=\(frames)")}
        let targets:[Int]
        switch profile {
        case "RampEdges":
            let fade=Int((Double(rate)*0.003).rounded())
            targets=[boundary-(fade-1),boundary-fade,boundary-(fade+1)]
        case "Repeated":targets=[rate*2,rate*3,rate+1]
        default: XCTFail("unknown profile");return
        }
        for (i,target) in targets.enumerated(){try inspect(d,reference,target,i+1,mode)}
        d.close()
        if profile != "AfterEOF" {linearDecoder.close()}
        print("G0_4B10754_CONTROL scenario=\(scenario) mode=\(mode) observations=\(targets.count) metadataOff=true cleanup=true")
    }
#endif
    private func scenario(_ codec:String,_ rate:Int,_ profile:String) throws {
#if G0_HIRES_RAMP_ORACLE
        try run(codec,rate,profile)
#else
        throw XCTSkip("runner-only lossless seek oracle")
#endif
    }
    func testFLAC96000RampEdges() throws {try scenario("FLAC",96000,"RampEdges")}
    func testFLAC96000Repeated() throws {try scenario("FLAC",96000,"Repeated")}
    func testFLAC192000RampEdges() throws {try scenario("FLAC",192000,"RampEdges")}
    func testFLAC192000Repeated() throws {try scenario("FLAC",192000,"Repeated")}
    func testALAC96000RampEdges() throws {try scenario("ALAC",96000,"RampEdges")}
    func testALAC96000Repeated() throws {try scenario("ALAC",96000,"Repeated")}
    func testALAC192000RampEdges() throws {try scenario("ALAC",192000,"RampEdges")}
    func testALAC192000Repeated() throws {try scenario("ALAC",192000,"Repeated")}
}
