import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import ApoloEngine

final class G0MP3PrerollTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_MP3_PREROLL_ORACLE"] == "1")
    }
#if G0_MP3_PREROLL_ORACLE
    private let rate=48000
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
    private struct Match {
        let index:Int
        let score:Double
        let runnerUp:Double
        var confident:Bool {score >= 0.8 && score-runnerUp >= 0.02}
    }
    // Search independent of PTS/target. Stereo sparse normalized correlation,
    // followed by a dense score at the best candidate and distant alternative.
    private func match(_ query:[Float],_ reference:[Float])->Match? {
        let n=query.count/2
        let width=min(256,n)
        guard width>=64,reference.count/2>=width else{return nil}
        let offset=n-width
        func score(_ start:Int,_ stride:Int)->Double {
            var dot=0.0,aa=0.0,bb=0.0
            for f in Swift.stride(from:0,to:width,by:stride) {
                for ch in 0..<2 {
                    let a=Double(query[(offset+f)*2+ch]),b=Double(reference[(start+f)*2+ch])
                    dot+=a*b;aa+=a*a;bb+=b*b
                }
            }
            return aa>1e-12 && bb>1e-12 ? dot/sqrt(aa*bb) : -2
        }
        var best = -2.0, pos = 0
        let limit=reference.count/2-width
        for i in 0...limit {
            let s=score(i,8)
            if s>best {best=s;pos=i}
        }
        var denseBest = -2.0, densePos=pos
        for i in max(0,pos-8)...min(limit,pos+8) {
            let s=score(i,1)
            if s>denseBest {denseBest=s;densePos=i}
        }
        var alt = -2.0, altPos:Int?=nil
        for i in 0...limit where abs(i-densePos)>8 {
            let s=score(i,8)
            if s>alt {alt=s;altPos=i}
        }
        let altDense=altPos.map{score($0,1)} ?? -2
        // The margin is a heuristic, not a proof of globally unique content.
        return Match(index:densePos-offset,score:denseBest,runnerUp:altDense)
    }
    private func compare(_ values:[Float],_ ref:[Float],_ index:Int)->(Int,Double,Double) {
        guard index>=0,index<=ref.count/2-values.count/2 else{return (-1,-1,-1)}
        var diff=0,square=0.0,peak=0.0
        for i in values.indices {
            let r=ref[index*2+i]
            if values[i].bitPattern != r.bitPattern {diff+=1}
            let d=abs(Double(values[i])-Double(r));square+=d*d;peak=max(peak,d)
        }
        return (diff,sqrt(square/Double(values.count)),peak)
    }
    private func inspect(_ d:AudioDecoder,_ reference:[Float],_ timeline:[Int],_ target:Int,_ ordinal:Int) throws {
        let start=DispatchTime.now().uptimeNanoseconds
        do {try d.seek(to:Double(target)/Double(rate))}
        catch {print("G0_4B10761_OBSERVATION ordinal=\(ordinal) target=\(target) status=seekError");return}
        let seekNanos=DispatchTime.now().uptimeNanoseconds-start
        var firstNanos:UInt64=0
        var buffers:[[Float]]=[],pts:[Int]=[]
        var status="ok"
        for _ in 0..<8 {
            do {
                guard let b=try d.readNextBuffer() else {status="eof";break}
                if buffers.isEmpty {firstNanos=DispatchTime.now().uptimeNanoseconds-start}
                let x=try pcm(b)
                try require(x.allSatisfy{$0.isFinite},"nonfinite decoded PCM")
                buffers.append(x);pts.append(try XCTUnwrap(tick(b)))
            } catch {status="readError";break}
        }
        let readNanos=DispatchTime.now().uptimeNanoseconds-start
        let recs=d.g0RampRecords
        var rampMismatch=0,deliveryMismatch=0,compared=0,counterMismatch=0,continuity=0,consumed=0
        let fade=Int((Double(rate)*0.003).rounded())
        for k in buffers.indices {
            if k>0 {continuity+=abs(pts[k]-pts[k-1]-buffers[k-1].count/2)}
            guard k<recs.count else{continue}
            let r=recs[k],x=buffers[k],n=x.count/2
            try require(r.ticks==Int64(pts[k]) && r.pre.count==x.count && r.post.count==x.count,"capture correspondence")
            if r.fade != fade || r.before != min(consumed,fade) || r.after != min(consumed+n,fade) {counterMismatch+=1}
            for f in 0..<n {
                let gain=consumed+f<fade ? Float(consumed+f+1)/Float(fade):1
                for ch in 0..<2 {
                    let i=f*2+ch
                    let expected=consumed+f<fade ? r.pre[i]*gain:r.pre[i]
                    if expected.bitPattern != r.post[i].bitPattern {rampMismatch+=1}
                    if x[i].bitPattern != r.post[i].bitPattern {deliveryMismatch+=1}
                }
            }
            consumed+=n;compared+=x.count
        }
        try require(rampMismatch==0 && deliveryMismatch==0 && counterMismatch==0,"ramp/delivery invariant")
        // Independently locate first and last captured buffers; then inspect
        // every captured sample at its actual PTS and at the inferred anchor.
        var anchors:[Int:Match]=[:]
        let indices=Array(Set([0,min(buffers.count,recs.count)-1])).sorted()
        for k in indices where k>=0 && k<buffers.count && k<recs.count {
            if let m=match(recs[k].pre,reference) {anchors[k]=m}
        }
        let lastK=min(buffers.count,recs.count)-1
        func valid(_ m:Match?,_ k:Int)->Bool {
            guard let m,k>=0,k<recs.count,m.confident,m.index>=0,m.index<=timeline.count-recs[k].pre.count/2 else{return false}
            return true
        }
        let firstOK=valid(anchors[0],0),lastOK=valid(anchors[lastK],lastK)
        var offsets:[Int]=[],total=0
        for x in buffers {offsets.append(total);total+=x.count/2}
        let base=firstOK ? anchors[0]!.index : lastOK ? anchors[lastK]!.index-offsets[lastK] : -1
        let contentContinuous=firstOK && lastOK && anchors[lastK]!.index==base+offsets[lastK]
        var ptsExactBuffers=0,anchoredExactBuffers=0,allZeroBuffers=0,ptsCompared=0,ptsMismatch=0,anchoredCompared=0,anchoredMismatch=0
        var firstExact=false
        let tickToIndex=Dictionary(uniqueKeysWithValues:timeline.enumerated().map{($0.element,$0.offset)})
        for k in buffers.indices where k<recs.count {
            let r=recs[k],n=r.pre.count/2
            let energy=r.pre.reduce(0.0){$0+Double($1)*Double($1)}
            let zeros=r.pre.filter{$0==0}.count
            if zeros==r.pre.count {allZeroBuffers+=1}
            let pidx=tickToIndex[pts[k]] ?? -1
            let aidx=base>=0 ? base+offsets[k] : -1
            let ptsSpanContinuous=pidx>=0 && n<=timeline.count-pidx && timeline[pidx+n-1]==pts[k]+n-1
            let p=ptsSpanContinuous ? compare(r.pre,reference,pidx):(-1,-1.0,-1.0)
            let a=compare(r.pre,reference,aidx)
            if p.0>=0 {ptsCompared+=r.pre.count;ptsMismatch+=p.0}
            if a.0>=0 {anchoredCompared+=r.pre.count;anchoredMismatch+=a.0}
            if p.0==0 {ptsExactBuffers+=1}
            if a.0==0 {anchoredExactBuffers+=1}
            if k==0 {firstExact=p.0==0}
            let anchor=anchors[k]
            print("G0_4B10761_BUFFER ordinal=\(ordinal) buffer=\(k+1) pts=\(pts[k]) frames=\(n) energy=\(energy) zeros=\(zeros) rmsSignal=\(sqrt(energy/Double(r.pre.count))) ptsIndex=\(pidx) ptsSpanContinuous=\(ptsSpanContinuous) ptsMismatch=\(p.0) ptsRMS=\(p.1) ptsPeak=\(p.2) anchorIndex=\(aidx) anchorMismatch=\(a.0) anchorRMS=\(a.1) anchorPeak=\(a.2) matchIndex=\(anchor?.index ?? -1) score=\(anchor?.score ?? -2) confident=\(valid(anchor,k))")
        }
        let firstPTS=pts.first ?? Int.min
        let firstContent=firstOK ? timeline[anchors[0]!.index] : Int.min
        let lastContent=lastOK ? timeline[anchors[lastK]!.index] : Int.min
        // Index relative to first audible decoded frame is separate from raw PTS.
        let normalizedIndex=firstOK ? anchors[0]!.index : -1
        let firstTickIndex=tickToIndex[firstPTS] ?? -1
        let complete=buffers.count==8 && recs.count==8
        print("G0_4B10761_OBSERVATION ordinal=\(ordinal) target=\(target) status=\(status) buffers=\(buffers.count) captures=\(min(buffers.count,recs.count)) frames=\(total) firstPTS=\(firstPTS) firstContentTick=\(firstContent) lastContentTick=\(lastContent) firstConfidence=\(firstOK) lastConfidence=\(lastOK) contentContinuous=\(contentContinuous) ptsContinuityError=\(continuity) firstRefIndex=\(normalizedIndex) firstTickIndex=\(firstTickIndex) firstExact=\(firstExact) ptsExactBuffers=\(ptsExactBuffers) anchoredExactBuffers=\(anchoredExactBuffers) allZeroBuffers=\(allZeroBuffers) ptsCompared=\(ptsCompared) ptsMismatch=\(ptsMismatch) anchoredCompared=\(anchoredCompared) anchoredMismatch=\(anchoredMismatch) rampMismatch=\(rampMismatch) deliveryMismatch=\(deliveryMismatch) compared=\(compared) complete=\(complete) seekNanos=\(seekNanos) firstNanos=\(firstNanos) readNanos=\(readNanos) packets=\(d.g0WorkPackets) decodedFrames=\(d.g0WorkFrames) discardedFrames=\(d.g0WorkDiscarded)")
    }
    private func run(_ codec:String,_ profile:String) throws {
        let scenario=codec+profile
        let env=ProcessInfo.processInfo.environment
        let mode=env["APOLO_G0_MP3_MODE"] ?? ""
        try require(["original","noFlush","pre24","pre96","pre240","flush96"].contains(mode) && env["APOLO_G0_MP3_PROFILE"]==scenario,"profile/mode")
        print("G0_4B10761_PROCESS pid=\(getpid()) scenario=\(scenario) codec=\(codec) mode=\(mode)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let encoded=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(G0MP3PrerollFixtureData.files[codec])))
        let ext=".mp3"
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+ext)
        try encoded.write(to:url)
        defer{try? FileManager.default.removeItem(at:url)}
        let linear=configured()
        defer{linear.close()}
        try linear.open(url:url,httpHeaders:[:])
        var reference:[Float]=[],timeline:[Int]=[]
        var blocks=0,ptsGaps=0
        var firstGap=0,firstBlock=0
        while let b=try linear.readNextBuffer() {
            let x=try pcm(b),p=try XCTUnwrap(tick(b))
            try require(x.allSatisfy{$0.isFinite},"linear nonfinite PCM")
            if blocks==0 {firstBlock=x.count/2}
            if let last=timeline.last, p != last+1 {ptsGaps+=1;if ptsGaps==1 {firstGap=p-last-1}}
            try require(timeline.last.map{p>$0} ?? true,"linear overlapping PTS")
            reference+=x
            timeline+=Array(p..<(p+x.count/2))
            blocks+=1
        }
        try require(reference.count/2>=rate*7 && reference.count/2<=rate*9,"linear reference length outside diagnostic bounds")
        let controlIndex=rate*2+137
        let control=Array(reference[(controlIndex*2)..<((controlIndex+256)*2)])
        let controlMatch=try XCTUnwrap(match(control,reference))
        try require(controlMatch.confident && controlMatch.index==controlIndex,"positive independent alignment control")
        let shifted=compare(control,reference,controlIndex+1)
        try require(shifted.0>0 && shifted.1>0,"shift negative control")
        print("G0_4B10761_LINEAR frames=\(reference.count/2) buffers=\(blocks) firstPTS=\(timeline.first!) lastPTS=\(timeline.last!) ptsGaps=\(ptsGaps) firstBlock=\(firstBlock) firstGap=\(firstGap) controlIndex=\(controlIndex) found=\(controlMatch.index) score=\(controlMatch.score) margin=\(controlMatch.score-controlMatch.runnerUp) shiftMismatch=\(shifted.0)")
        let d=profile=="AfterEOF" ? linear:configured()
        defer{if profile != "AfterEOF"{d.close()}}
        if profile != "AfterEOF" {
            try d.open(url:url,httpHeaders:[:])
            let b=try XCTUnwrap(d.readNextBuffer()),x=try pcm(b)
            try require(x.elementsEqual(reference.prefix(x.count)) && tick(b)==timeline.first,"fresh initial reference mismatch")
            print("G0_4B10761_INITIAL frames=\(x.count/2) pts=\(timeline.first!)")
        } else {print("G0_4B10761_EOF frames=\(reference.count/2)")}
        let targets:[Int]
        switch profile {
        case "NearStart":targets=[720]
        case "Repeated":targets=[rate*2,rate*3,rate+1]
        case "AfterEOF":targets=[rate*3]
        case "Tail":targets=[rate*7+rate*3/4]
        default:XCTFail("unknown profile");return
        }
        for (i,target) in targets.enumerated(){try inspect(d,reference,timeline,target,i+1)}
        print("G0_4B10761_CONTROL scenario=\(scenario) mode=\(mode) observations=\(targets.count) metadataOff=true")
    }
#endif
    private func scenario(_ codec:String,_ profile:String) throws {
#if G0_MP3_PREROLL_ORACLE
        try run(codec,profile)
#else
        throw XCTSkip("runner-only lossy seek oracle")
#endif
    }
    func testMP3NearStart() throws {try scenario("MP3","NearStart")}
    func testMP3Repeated() throws {try scenario("MP3","Repeated")}
    func testMP3AfterEOF() throws {try scenario("MP3","AfterEOF")}
    func testMP3Tail() throws {try scenario("MP3","Tail")}
}
