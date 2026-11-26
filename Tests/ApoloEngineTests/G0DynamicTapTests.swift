import Foundation
import AudioToolbox
import Darwin
import CryptoKit
import XCTest
@testable import ApoloEngine

/// Sequential prepare transitions on the real tap, with a fresh tap and direct DSP
/// as controls. No AVPlayer or decoder/renderer transition is simulated as real.
final class G0DynamicTapTests:XCTestCase {
    private struct Format {
        let rate:Int
        let ch:Int
        let planar:Bool
        let integer:Bool
        init(_ rate:Int,_ ch:Int,_ planar:Bool=false,_ integer:Bool=false) {
            self.rate=rate;self.ch=ch;self.planar=planar;self.integer=integer
        }
        var label:String{"rate=\(rate) channels=\(ch) planar=\(planar) integer=\(integer)"}
        var asbd:AudioStreamBasicDescription{
            var f=AudioStreamBasicDescription()
            f.mSampleRate=Double(rate);f.mFormatID=kAudioFormatLinearPCM
            f.mFormatFlags=kAudioFormatFlagIsPacked | (integer ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat)
            if planar{f.mFormatFlags |= kAudioFormatFlagIsNonInterleaved}
            f.mFramesPerPacket=1;f.mChannelsPerFrame=UInt32(ch);f.mBitsPerChannel=32
            f.mBytesPerFrame=UInt32(4*(planar ? 1:ch));f.mBytesPerPacket=f.mBytesPerFrame
            return f
        }
    }
    private struct Output {
        let pcm:[Float]
        let processNS:UInt64
    }
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ pcm:[Float])->String{
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func signal(_ f:Format,phase:Int)->[Float]{
        let frames=f.rate/10+3
        var src=[Float]();src.reserveCapacity(frames*f.ch)
        for i in 0..<frames{
            for c in 0..<f.ch{
                if c==f.ch-1{src.append(0)}
                else if f.integer{
                    // Genuine signed Int32 PCM bit patterns, transported in
                    // Float storage without floating-point arithmetic.
                    let words:[UInt32]=[0x10000000,0xe0000000,0x01000000,0xff000000,0x00000001,0x40000000,0xc0000000]
                    src.append(Float(bitPattern:words[(i+c+phase)%words.count]))
                }else{
                    let a=i<frames/2 ? 0.96 : 0.12
                    src.append(Float(a*sin(2*Double.pi*Double(71+47*c)*Double(i)/Double(f.rate)+0.37*Double(phase+1))))
                }
            }
        }
        return src
    }
    private func settings(_ combined:Bool)->EqualizerSettings{
        combined ? EqualizerSettings(bandsDB:[6,-3,4,-6,3],preampDB:3) : .flat
    }
    private func makeTap(_ combined:Bool)->AudioTapProcessor{
        AudioTapProcessor(equalizer:settings(combined),limiterEnabled:combined,trackGainDB:combined ? 2:0)
    }
    private func direct(_ src:[Float],_ f:Format,_ combined:Bool)->[Float]{
        if f.integer{return src}
        let chain=AudioProcessingChain(sampleRate:Double(f.rate),channels:f.ch,settings:settings(combined),limiterEnabled:combined,trackGainDB:combined ? 2:0)
        var pcm=src
        pcm.withUnsafeMutableBufferPointer{chain.process(interleaved:$0.baseAddress!,frames:src.count/f.ch)}
        return pcm
    }
    private func process(_ src:[Float],_ f:Format,_ tap:AudioTapProcessor)->Output{
        let n=src.count/f.ch,planes=f.planar ? f.ch:1
        let ptrs=(0..<planes).map{_ in UnsafeMutablePointer<Float>.allocate(capacity:f.planar ? n:src.count)}
        defer{for p in ptrs{p.deinitialize(count:f.planar ? n:src.count);p.deallocate()}}
        if f.planar{for c in 0..<f.ch{for i in 0..<n{ptrs[c].advanced(by:i).initialize(to:src[i*f.ch+c])}}}
        else{for i in src.indices{ptrs[0].advanced(by:i).initialize(to:src[i])}}
        let abl=AudioBufferList.allocate(maximumBuffers:planes)
        defer{abl.unsafeMutablePointer.deallocate()}
        abl.unsafeMutablePointer.pointee.mNumberBuffers=UInt32(planes)
        var cursor=0,elapsed:UInt64=0
        let sizes=[1,7,31,256,1024]
        var index=0
        while cursor<n{
            let count=min(sizes[index%sizes.count],n-cursor)
            for p in 0..<planes{
                let base=ptrs[p].advanced(by:f.planar ? cursor:cursor*f.ch)
                abl[p]=AudioBuffer(mNumberChannels:UInt32(f.planar ? 1:f.ch),mDataByteSize:UInt32(count*4*(f.planar ? 1:f.ch)),mData:UnsafeMutableRawPointer(base))
            }
            let t=DispatchTime.now().uptimeNanoseconds
            tap.process(bufferList:abl.unsafeMutablePointer,frames:count)
            elapsed+=DispatchTime.now().uptimeNanoseconds-t
            cursor+=count;index+=1
        }
        var pcm=[Float](repeating:0,count:src.count)
        if f.planar{for c in 0..<f.ch{for i in 0..<n{pcm[i*f.ch+c]=ptrs[c][i]}}}
        else{for i in src.indices{pcm[i]=ptrs[0][i]}}
        return Output(pcm:pcm,processNS:elapsed)
    }
    private func run(_ name:String,_ formats:[Format])throws{
        XCTAssertEqual(formats.count,3)
        print("G0_4B8_PROCESS pid=\(getpid()) scenario=\(name)")
        for combined in [false,true]{
            let effect=combined ? "combined":"bypass"
            let signals=formats.enumerated().map{signal($0.element,phase:$0.offset)}
            let expected=formats.enumerated().map{direct(signals[$0.offset],$0.element,combined)}
            var hashes=[String]()
            for (phase,f) in formats.enumerated(){
                let fresh=makeTap(combined);fresh.prepare(format:f.asbd)
                let out=process(signals[phase],f,fresh).pcm
                let digest=hash(expected[phase])
                XCTAssertEqual(hash(out),digest,"fresh tap vs direct \(name) phase \(phase)")
                hashes.append(digest)
            }
            let control=makeTap(combined)
            for (phase,f) in formats.enumerated(){
                control.prepare(format:f.asbd)
                let out=process(signals[phase],f,control).pcm
                let digest=hash(out),exact=digest==hashes[phase]
                XCTAssertEqual(out.count,signals[phase].count)
                if !f.integer{
                    XCTAssertTrue(out.allSatisfy{$0.isFinite})
                    XCTAssertEqual(stride(from:f.ch-1,to:out.count,by:f.ch).reduce(0.0){max($0,abs(Double(out[$1])))},0)
                    if combined{XCTAssertLessThanOrEqual(out.reduce(0.0){max($0,abs(Double($1)))},pow(10.0,-1.0/20)+0.000001)}
                }
                XCTAssertTrue(exact,"sequential prepare vs fresh \(name) phase \(phase)")
                print("G0_4B8_CONTROL scenario=\(name) effect=\(effect) phase=\(phase) \(f.label) frames=\(out.count/f.ch) hash=\(digest) expected=\(hashes[phase]) exact=\(exact)")
            }
            var prep=Array(repeating:[UInt64](),count:3),proc=prep
            for index in -1...10{
                let tap=makeTap(combined)
                for (phase,f) in formats.enumerated(){
                    let t=DispatchTime.now().uptimeNanoseconds
                    tap.prepare(format:f.asbd)
                    let prepareNS=DispatchTime.now().uptimeNanoseconds-t
                    let r=process(signals[phase],f,tap)
                    XCTAssertEqual(hash(r.pcm),hashes[phase])
                    if index>0{prep[phase].append(prepareNS);proc[phase].append(r.processNS)}
                    print("G0_4B8_CASE scenario=\(name) effect=\(effect) phase=\(phase) index=\(index) prepareNS=\(prepareNS) processNS=\(r.processNS)")
                }
            }
            for phase in 0..<3{
                print("G0_4B8_STATS scenario=\(name) effect=\(effect) phase=\(phase) n=10 prepareP50NS=\(prep[phase].sorted()[4]) prepareP95NS=\(prep[phase].sorted()[9]) processP50NS=\(proc[phase].sorted()[4]) processP95NS=\(proc[phase].sorted()[9])")
            }
        }
        print("G0_4B8_SUMMARY controls=6 measured=60 warmups=12")
    }
    func testRate()throws{try run("rate",[Format(48000,2),Format(192000,2),Format(48000,2)])}
    func testChannels()throws{try run("channels",[Format(96000,2),Format(96000,8),Format(96000,2)])}
    func testPacking()throws{try run("packing",[Format(48000,6),Format(48000,6,true),Format(48000,6)])}
    func testInteger()throws{try run("integer",[Format(48000,2),Format(48000,2,false,true),Format(48000,2)])}
    func testMixed()throws{try run("mixed",[Format(44100,2),Format(96000,8,true),Format(44100,2)])}
    func testSamePrepare()throws{try run("samePrepare",[Format(48000,2),Format(48000,2),Format(48000,2)])}
}
