import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import ApoloEngine

final class G0MP3RawTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_MP3_RAW_ORACLE"] == "1")
    }
#if G0_MP3_RAW_ORACLE
    private var rate=48000
    private var channels=2
    private func pcm(_ b:CMSampleBuffer) throws -> [Float] {
        let desc=try XCTUnwrap(CMSampleBufferGetFormatDescription(b))
        let asbd=try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(desc)).pointee
        try require(asbd.mSampleRate==Double(rate) && asbd.mChannelsPerFrame==UInt32(channels) && asbd.mBitsPerChannel==32 && asbd.mFormatID==kAudioFormatLinearPCM && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,"output sample rate, channel count or Float32 format")
        let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(b))
        let n=CMSampleBufferGetNumSamples(b)*channels
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
    private func inspect(_ d:AudioDecoder,_ ref:[Float],_ target:Int,_ ordinal:Int,_ certifiedMap:Bool,_ fromStart:Bool,_ tagged:Bool) throws {
        let before=d.g0TimelineUnsupported
        let start=DispatchTime.now().uptimeNanoseconds
        do {if fromStart {try d.g0ArmFromStart(target:Int64(target))} else {try d.seek(to:Double(target)/Double(rate))}}
        catch {print("G0_4B10764_OBSERVATION ordinal=\(ordinal) target=\(target) status=seekError exact=false");return}
        var frames=0,compared=0,mismatch=0,ptsErrors=0,rampMismatch=0,deliveryMismatch=0,counterMismatch=0,buffers=0
        var firstPTS:Int?=nil,lastEnd:Int?=nil,firstNanos:UInt64=0
        var status="ok"
        let fade=Int((Double(rate)*0.003).rounded())
        for k in 0..<8 {
            let b:CMSampleBuffer
            do {guard let x=try d.readNextBuffer() else {status="eof";break};b=x}
            catch {status="readError";break}
            if k==0 {firstNanos=DispatchTime.now().uptimeNanoseconds-start}
            let x=try pcm(b),p=try XCTUnwrap(tick(b)),n=x.count/channels
            try require(x.allSatisfy{$0.isFinite},"nonfinite PCM")
            if firstPTS==nil {firstPTS=p}
            if let lastEnd, lastEnd != p {ptsErrors+=1}
            lastEnd=p+n
            if k<d.g0RampRecords.count {
                let r=d.g0RampRecords[k]
                try require(r.pre.count==x.count && r.post.count==x.count && r.ticks==Int64(p),"capture correspondence")
                if r.fade != fade || r.before != min(frames,fade) || r.after != min(frames+n,fade) {counterMismatch+=1}
                if target+frames+n<=ref.count/channels {
                    for i in x.indices {
                        if r.pre[i].bitPattern != ref[(target+frames)*channels+i].bitPattern {mismatch+=1}
                    }
                    compared+=x.count
                }
                for f in 0..<n {
                    let gain=frames+f<fade ? Float(frames+f+1)/Float(fade):1
                    for c in 0..<channels {
                        let i=f*channels+c
                        let expected=frames+f<fade ? r.pre[i]*gain:r.pre[i]
                        if expected.bitPattern != r.post[i].bitPattern {rampMismatch+=1}
                        if x[i].bitPattern != r.post[i].bitPattern {deliveryMismatch+=1}
                    }
                }
            }
            frames+=n;buffers+=1
        }
        let unsupported=d.g0TimelineUnsupported-before
        let cursorAligned=lastEnd.map{Int64($0)==d.g0TimelineCursor} ?? false
        let fullCapture=d.g0RampRecords.count==buffers
        let exact=certifiedMap && (tagged ? d.g0TimelineEligible:d.g0RawEligible) && unsupported==0 && status != "readError" && buffers>0 && fullCapture && firstPTS==target && ptsErrors==0 && compared==frames*channels && mismatch==0 && cursorAligned
        let endExact=exact && status=="eof" && target+frames==ref.count/channels
        try require(rampMismatch==0 && deliveryMismatch==0 && counterMismatch==0,"ramp/PCM delivery")
        print("G0_4B10764_OBSERVATION ordinal=\(ordinal) target=\(target) status=\(status) buffers=\(buffers) captures=\(d.g0RampRecords.count) frames=\(frames) firstPTS=\(firstPTS ?? Int.min) compared=\(compared) mismatch=\(mismatch) ptsErrors=\(ptsErrors) rampMismatch=\(rampMismatch) deliveryMismatch=\(deliveryMismatch) unsupported=\(unsupported) eligible=\(d.g0TimelineEligible) rawEligible=\(d.g0RawEligible) coordinate=\(tagged ? "audible":"decoded") cursorAligned=\(cursorAligned) exact=\(exact) endExact=\(endExact) firstNanos=\(firstNanos) packets=\(d.g0WorkPackets) discarded=\(d.g0WorkDiscarded)")
    }
    private func run(_ key:String,_ profile:String) throws {
        let scenario=key+profile
        let env=ProcessInfo.processInfo.environment
        let mode=env["APOLO_G0_MP3_RAW_MODE"] ?? ""
        try require(["control","both","rawTrim","fromStart"].contains(mode) && env["APOLO_G0_MP3_RAW_PROFILE"]==scenario,"profile/mode")
        let meta=try XCTUnwrap(G0MP3RawFixtureData.meta[key])
        rate=meta[0];channels=meta[1]
        let hostFrames=meta[2],skip=meta[3],padding=meta[4],nominal=meta[5]
        let tagged=skip>0 && padding>=0
        print("G0_4B10764_PROCESS pid=\(getpid()) scenario=\(scenario) fixture=\(key) mode=\(mode) rate=\(rate) channels=\(channels) tagged=\(tagged)")
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let data=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(G0MP3RawFixtureData.files[key])))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp3")
        try data.write(to:url)
        defer{try? FileManager.default.removeItem(at:url)}
        let linear=configured()
        defer{linear.close()}
        try linear.open(url:url,httpHeaders:[:])
        var ref:[Float]=[],timeline:[Int]=[],blocks=0,firstBlock=0,gaps=0
        while let b=try linear.readNextBuffer() {
            let x=try pcm(b),p=try XCTUnwrap(tick(b))
            try require(x.allSatisfy{$0.isFinite},"nonfinite linear PCM")
            if blocks==0 {firstBlock=x.count/channels}
            if let last=timeline.last,p != last+1 {gaps+=1}
            ref+=x;timeline+=Array(p..<(p+x.count/channels));blocks+=1
        }
        let eligible=linear.g0TimelineEligible
        let normalized=mode=="both" && eligible
        let expectedPartial=nominal-skip
        let metadataMatches=tagged && eligible && linear.g0TimelineOffset==Int64(skip) && linear.g0NominalSamples==Int64(nominal) && firstBlock==expectedPartial && timeline.count==hostFrames
        let mapExact=metadataMatches && timeline.enumerated().allSatisfy{ i,p in p==i+(normalized || i<firstBlock ? 0:skip) }
        let rawMap = !tagged && linear.g0RawEligible && skip==0 && padding == -1 && timeline.count==hostFrames && firstBlock==nominal && timeline.enumerated().allSatisfy { $0.offset == $0.element }
        let certifiedMap=(normalized && mapExact || rawMap) && linear.g0TimelineUnsupported==0
        try require(tagged ? eligible && normalized && mapExact : !eligible && rawMap,"independent timeline control")
        try require(timeline.count>=rate*7 && timeline.count<=rate*9,"reference length")
        let hash=ref.withUnsafeBytes{SHA256.hash(data:Data($0)).map{String(format:"%02x",$0)}.joined()}
        let anchor=rate*2+137
        let neg=(0..<(256*channels)).filter{ref[anchor*channels+$0].bitPattern != ref[(anchor+1)*channels+$0].bitPattern}.count
        try require(neg>0,"shifted negative control")
        print("G0_4B10764_LINEAR frames=\(timeline.count) hostFrames=\(hostFrames) buffers=\(blocks) firstPTS=\(timeline.first!) lastPTS=\(timeline.last!) firstBlock=\(firstBlock) gaps=\(gaps) skip=\(skip) padding=\(padding) nominal=\(nominal) runtimeNominal=\(linear.g0NominalSamples) runtimeOffset=\(linear.g0TimelineOffset) eligible=\(eligible) normalized=\(normalized) mapExact=\(mapExact) rawMap=\(rawMap) rawEligible=\(linear.g0RawEligible) certifiedMap=\(certifiedMap) unsupported=\(linear.g0TimelineUnsupported) pcmSHA256=\(hash) shiftMismatch=\(neg)")
        let d=profile=="AfterEOF" ? linear:configured()
        defer{if profile != "AfterEOF" {d.close()}}
        if profile != "AfterEOF" && mode != "fromStart" {
            try d.open(url:url,httpHeaders:[:])
            let b=try XCTUnwrap(d.readNextBuffer()),x=try pcm(b)
            try require(x.elementsEqual(ref.prefix(x.count)) && tick(b)==timeline.first && d.g0TimelineEligible==eligible && d.g0RawEligible==linear.g0RawEligible,"fresh reference")
        }
        let targets:[Int]
        let boundary=firstBlock+nominal
        switch profile {
        case "Edges":targets=[0,firstBlock-1,firstBlock,firstBlock+1,boundary-1,boundary,boundary+1]
        case "RepeatedTail":targets=[rate*2,rate*3,rate+1,rate*7+rate*3/4,timeline.count-1]
        case "AfterEOF":targets=[rate*3]
        default:throw NSError(domain:"G0MP3Raw",code:2)
        }
        for (i,target) in targets.enumerated() {
            if mode=="fromStart" {
                let fresh=configured()
                defer{fresh.close()}
                let openStart=DispatchTime.now().uptimeNanoseconds
                try fresh.open(url:url,httpHeaders:[:])
                print("G0_4B10764_FRESH ordinal=\(i+1) openNanos=\(DispatchTime.now().uptimeNanoseconds-openStart)")
                try inspect(fresh,ref,target,i+1,certifiedMap,true,tagged)
            } else {try inspect(d,ref,target,i+1,certifiedMap,false,tagged)}
        }
        print("G0_4B10764_CONTROL scenario=\(scenario) mode=\(mode) observations=\(targets.count) metadataOff=true")
    }
#endif
    private func scenario(_ key:String,_ profile:String) throws {
#if G0_MP3_RAW_ORACLE
        try run(key,profile)
#else
        throw XCTSkip("runner-only MP3 generalization")
#endif
    }
    func testC48StereoEdges() throws {try scenario("C48Stereo","Edges")}
    func testC48StereoRepeatedTail() throws {try scenario("C48Stereo","RepeatedTail")}
    func testC48StereoAfterEOF() throws {try scenario("C48Stereo","AfterEOF")}
    func testV48MonoEdges() throws {try scenario("V48Mono","Edges")}
    func testV48MonoRepeatedTail() throws {try scenario("V48Mono","RepeatedTail")}
    func testV48MonoAfterEOF() throws {try scenario("V48Mono","AfterEOF")}
    func testC44MonoEdges() throws {try scenario("C44Mono","Edges")}
    func testC44MonoRepeatedTail() throws {try scenario("C44Mono","RepeatedTail")}
    func testC44MonoAfterEOF() throws {try scenario("C44Mono","AfterEOF")}
    func testV44StereoEdges() throws {try scenario("V44Stereo","Edges")}
    func testV44StereoRepeatedTail() throws {try scenario("V44Stereo","RepeatedTail")}
    func testV44StereoAfterEOF() throws {try scenario("V44Stereo","AfterEOF")}
    func testU48StereoEdges() throws {try scenario("U48Stereo","Edges")}
    func testU48StereoRepeatedTail() throws {try scenario("U48Stereo","RepeatedTail")}
    func testU48StereoAfterEOF() throws {try scenario("U48Stereo","AfterEOF")}
    func testU44MonoEdges() throws {try scenario("U44Mono","Edges")}
    func testU44MonoRepeatedTail() throws {try scenario("U44Mono","RepeatedTail")}
    func testU44MonoAfterEOF() throws {try scenario("U44Mono","AfterEOF")}
}
