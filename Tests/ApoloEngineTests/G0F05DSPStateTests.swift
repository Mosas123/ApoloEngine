import Foundation
import AudioToolbox
import CryptoKit
import XCTest
@testable import ApoloEngine

/// Tests actual DSP update and tap processor methods with owned synthetic buffers.
/// Does not create a physical AVPlayer render callback.
final class G0F05DSPStateTests: XCTestCase {
    private struct Config {
        var eq:EqualizerSettings = .flat
        var limiter=false
        var gain=0.0
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func hash(_ pcm:[Float])->String {
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func exact(_ a:[Float],_ b:[Float])->Bool {
        a.count==b.count && zip(a,b).allSatisfy{$0.0.bitPattern==$0.1.bitPattern}
    }
    private func error(_ a:[Float],_ b:[Float])->Double {
        zip(a,b).reduce(0.0){max($0,abs(Double($1.0)-Double($1.1)))}
    }
    private func chain(_ c:Config,rate:Int,ch:Int)->AudioProcessingChain {
        AudioProcessingChain(sampleRate:Double(rate),channels:ch,settings:c.eq,limiterEnabled:c.limiter,trackGainDB:c.gain)
    }
    private func apply(_ input:[Float],_ chain:AudioProcessingChain,ch:Int)->[Float] {
        var pcm=input
        pcm.withUnsafeMutableBufferPointer{chain.process(interleaved:$0.baseAddress!,frames:pcmFrameCount(input,ch))}
        return pcm
    }
    private func pcmFrameCount(_ input:[Float],_ ch:Int)->Int{input.count/ch}
    private func format(rate:Int,ch:Int,planar:Bool,isFloat:Bool=true)->AudioStreamBasicDescription {
        var f=AudioStreamBasicDescription()
        f.mSampleRate=Double(rate);f.mFormatID=kAudioFormatLinearPCM
        f.mFormatFlags=kAudioFormatFlagIsPacked | (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
        if planar{f.mFormatFlags |= kAudioFormatFlagIsNonInterleaved}
        f.mFramesPerPacket=1;f.mChannelsPerFrame=UInt32(ch);f.mBitsPerChannel=32
        f.mBytesPerFrame=UInt32(4*(planar ? 1:ch));f.mBytesPerPacket=f.mBytesPerFrame
        return f
    }
    private func tap(_ c:Config,rate:Int,ch:Int,planar:Bool,isFloat:Bool=true)->AudioTapProcessor {
        let t=AudioTapProcessor(equalizer:c.eq,limiterEnabled:c.limiter,trackGainDB:c.gain)
        t.prepare(format:format(rate:rate,ch:ch,planar:planar,isFloat:isFloat))
        return t
    }
    private func applyTap(_ input:[Float],_ tap:AudioTapProcessor,ch:Int,planar:Bool)->[Float] {
        var pcm=input
        let frames=input.count/ch
        if !planar{
            pcm.withUnsafeMutableBufferPointer{p in
                var list=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:UInt32(ch),mDataByteSize:UInt32(input.count*4),mData:UnsafeMutableRawPointer(p.baseAddress!)))
                tap.process(bufferList:&list,frames:frames)
            }
        }else{
            let list=AudioBufferList.allocate(maximumBuffers:ch)
            defer{list.unsafeMutablePointer.deallocate()}
            list.unsafeMutablePointer.pointee.mNumberBuffers=UInt32(ch)
            let pointers=(0..<ch).map{_ in UnsafeMutablePointer<Float>.allocate(capacity:frames)}
            for c in 0..<ch{
                for i in 0..<frames{pointers[c].advanced(by:i).initialize(to:input[i*ch+c])}
                list[c]=AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(frames*4),mData:UnsafeMutableRawPointer(pointers[c]))
            }
            tap.process(bufferList:list.unsafeMutablePointer,frames:frames)
            for c in 0..<ch{
                for i in 0..<frames{pcm[i*ch+c]=pointers[c][i]}
                pointers[c].deinitialize(count:frames);pointers[c].deallocate()
            }
        }
        return pcm
    }
    func testG0F05E2StateAndTap()throws {
        let eqA=Config(eq:EqualizerSettings(bandsDB:[6,0,3,0,0]))
        let eqB=Config(eq:EqualizerSettings(bandsDB:[-6,0,3,0,0]))
        let limit=Config(limiter:true)
        let flat=Config()
        let gain=Config(gain:6)
        let cases:[(String,Config,Config,Config)]=[
            ("sameEQ",eqA,eqA,eqA),
            ("changeEQ",eqA,eqB,eqB),
            ("removeRestoreEQ",eqA,flat,eqA),
            ("sameLimiter",limit,limit,limit),
            ("toggleLimiter",limit,flat,limit),
            ("gainStep",flat,gain,flat)
        ]
        var attempted=0,observed=0,nonfinite=0,initialExact=0,resetExact=0,rampExact=0,unchangedExact=0,nonFloatExact=0
        for rate in [44100,48000,96000,192000]{
            for ch in [1,2,6,8]{
                let n=rate/10+3
                for (label,a,b,c) in cases{
                    attempted+=1
                    let direct=chain(a,rate:rate,ch:ch)
                    let inter=tap(a,rate:rate,ch:ch,planar:false)
                    let planar=tap(a,rate:rate,ch:ch,planar:true)
                    var phase=[Float](),next=[Float](),last=[Float]()
                    for i in 0..<n{
                        for k in 0..<ch{
                            func sample(_ t:Int)->Float{
                                if label.contains("Limiter"){return t<n ? (k==0 ? 1.5:0.25):0.1}
                                if label=="gainStep"{return 0.2}
                                return Float(0.2*sin(2*Double.pi*Double(60+k*17)*Double(t)/Double(rate)+0.7))
                            }
                            phase.append(sample(i));next.append(sample(n+i));last.append(sample(2*n+i))
                        }
                    }
                    let da=apply(phase,direct,ch:ch),ia=applyTap(phase,inter,ch:ch,planar:false),pa=applyTap(phase,planar,ch:ch,planar:true)
                    let initOK=exact(da,ia)&&exact(da,pa)
                    if initOK{initialExact+=1}
                    // A separate unchanged-state control isolates same-setting updates.
                    let steady=chain(a,rate:rate,ch:ch)
                    _=apply(phase,steady,ch:ch)
                    let steadyB=apply(next,steady,ch:ch)
                    direct.update(settings:b.eq,limiterEnabled:b.limiter,trackGainDB:b.gain)
                    inter.update(equalizer:b.eq,limiterEnabled:b.limiter,trackGainDB:b.gain)
                    planar.update(equalizer:b.eq,limiterEnabled:b.limiter,trackGainDB:b.gain)
                    let db=apply(next,direct,ch:ch),ib=applyTap(next,inter,ch:ch,planar:false),pb=applyTap(next,planar,ch:ch,planar:true)
                    let freshB=apply(next,chain(b,rate:rate,ch:ch),ch:ch)
                    direct.update(settings:c.eq,limiterEnabled:c.limiter,trackGainDB:c.gain)
                    inter.update(equalizer:c.eq,limiterEnabled:c.limiter,trackGainDB:c.gain)
                    planar.update(equalizer:c.eq,limiterEnabled:c.limiter,trackGainDB:c.gain)
                    let dc=apply(last,direct,ch:ch),ic=applyTap(last,inter,ch:ch,planar:false),pc=applyTap(last,planar,ch:ch,planar:true)
                    let freshC=apply(last,chain(c,rate:rate,ch:ch),ch:ch)
                    let resets=exact(ib,freshB)&&exact(pb,freshB)&&exact(ic,freshC)&&exact(pc,freshC)
                    if resets{resetExact+=1}
                    if (label=="sameEQ"||label=="sameLimiter") && exact(db,steadyB){unchangedExact+=1}
                    let finite=[da,ia,pa,db,ib,pb,dc,ic,pc].allSatisfy{$0.allSatisfy{$0.isFinite}}
                    if !finite{nonfinite+=1}
                    observed+=1
                    print("G0_F05E2_UPDATE profile=\(label) rate=\(rate) channels=\(ch) frames=\(n) initialExact=\(initOK) tapResetExact=\(resets) directVsUnchangedB=\(error(db,steadyB)) directVsTapB=\(error(db,ib)) directVsTapC=\(error(dc,ic)) tapPlanarB=\(exact(ib,pb)) tapPlanarC=\(exact(ic,pc)) directJumpB=\(Double(db[0])-Double(da[da.count-ch])) tapJumpB=\(Double(ib[0])-Double(ia[ia.count-ch])) directFirstB=\(db[0]) tapFirstB=\(ib[0]) directFirstC=\(dc[0]) tapFirstC=\(ic[0]) finite=\(finite) directSHA=\(hash(db+dc)) tapSHA=\(hash(ib+ic))")
                }
                // Real seek-ramp helper: verify arbitrary partition, each
                // channel, exact endpoints, and no changes after fade.
                attempted+=1
                let fade=SeekTransientRamp.frameCount(sampleRate:Int32(rate))
                let frames=fade+17
                let src=(0..<(frames*ch)).map{Float(($0%13)+1)/16}
                var whole=src,split=src,consumed=0,splitConsumed=0
                whole.withUnsafeMutableBufferPointer{
                    SeekTransientRamp.apply(interleaved:$0.baseAddress!,frames:frames,channels:ch,fadeFrames:fade,consumedFrames:&consumed)
                }
                let sizes=[1,7,31,127,509]
                var cursor=0,index=0
                while cursor<frames{
                    let count=min(sizes[index%sizes.count],frames-cursor)
                    split.withUnsafeMutableBufferPointer{
                        SeekTransientRamp.apply(interleaved:$0.baseAddress!.advanced(by:cursor*ch),frames:count,channels:ch,fadeFrames:fade,consumedFrames:&splitConsumed)
                    }
                    cursor+=count;index+=1
                }
                let expected=src.enumerated().map{(i,v) in v*Float(min(i/ch+1,fade))/Float(fade)}
                // Oracle uses same mathematical gain with Float multiplication
                // grouped as production; separate endpoint and frame count.
                let rounded=src.enumerated().map{(i,v) in v*(Float(min(i/ch+1,fade))/Float(fade))}
                let ok=exact(whole,split)&&exact(whole,rounded)&&consumed==fade&&splitConsumed==fade
                if ok{rampExact+=1}
                observed+=1
                print("G0_F05E2_RAMP rate=\(rate) channels=\(ch) fadeFrames=\(fade) consumed=\(consumed) splitConsumed=\(splitConsumed) exact=\(ok) firstGain=\(whole[0]/src[0]) lastGain=\(whole[(fade-1)*ch]/src[(fade-1)*ch]) alternateArithmeticError=\(error(whole,expected)) pcmSHA=\(hash(whole))")
                // Non-Float ASBD should bypass, not reinterpret integer PCM.
                attempted+=1
                let t=tap(gain,rate:rate,ch:ch,planar:false,isFloat:false)
                let nonFloat=applyTap(src,t,ch:ch,planar:false)
                let okNF=exact(src,nonFloat)
                if okNF{nonFloatExact+=1}
                observed+=1
                print("G0_F05E2_NONFLOAT rate=\(rate) channels=\(ch) exact=\(okNF) pcmSHA=\(hash(nonFloat))")
            }
        }
        print("G0_F05E2_SUMMARY attempted=\(attempted) observed=\(observed) initialExact=\(initialExact) resetExact=\(resetExact) unchangedExact=\(unchangedExact) rampExact=\(rampExact) nonFloatExact=\(nonFloatExact) nonfinite=\(nonfinite)")
        XCTAssertEqual(attempted,128)
        XCTAssertEqual(observed,128)
        XCTAssertEqual(nonfinite,0)
    }
}
