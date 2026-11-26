import Foundation
import AudioToolbox
import Darwin
import CryptoKit
import XCTest
@testable import ApoloEngine

/// Measure actual AudioTapProcessor.prepare/process on synthetic owned AudioBufferLists.
/// Direct chain comparator uses same input, block boundaries and descriptor setup.
/// No MTAudioProcessingTap callback, AVPlayer render thread or device power claims.
final class G0TapCostTests: XCTestCase {
    private enum LabError: Error { case cpu }
    private struct Result {
        let pcm:[Float]
        let elapsed:UInt64
        let cpu:Int64
        let initNS:UInt64
        let maxCallNS:UInt64
        let overBudget:Int
        let calls:Int
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func cpu() throws -> Int64 {
        var u=rusage()
        guard getrusage(RUSAGE_SELF,&u)==0 else{throw LabError.cpu}
        return Int64(u.ru_utime.tv_sec)*1000000+Int64(u.ru_utime.tv_usec)+Int64(u.ru_stime.tv_sec)*1000000+Int64(u.ru_stime.tv_usec)
    }
    private func hash(_ pcm:[Float])->String {
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func format(_ rate:Int,_ ch:Int,_ planar:Bool)->AudioStreamBasicDescription {
        var f=AudioStreamBasicDescription()
        f.mSampleRate=Double(rate);f.mFormatID=kAudioFormatLinearPCM
        f.mFormatFlags=kAudioFormatFlagIsPacked | kAudioFormatFlagIsFloat
        if planar{f.mFormatFlags |= kAudioFormatFlagIsNonInterleaved}
        f.mFramesPerPacket=1;f.mChannelsPerFrame=UInt32(ch);f.mBitsPerChannel=32
        f.mBytesPerFrame=UInt32(4*(planar ? 1:ch));f.mBytesPerPacket=f.mBytesPerFrame
        return f
    }
    private func runPath(_ src:[Float],rate:Int,ch:Int,block:Int,planar:Bool,isTap:Bool,combined:Bool)throws->Result {
        let frames=src.count/ch, planes=planar ? ch : 1
        let pointers=(0..<planes).map{_ in UnsafeMutablePointer<Float>.allocate(capacity:planar ? frames : src.count)}
        defer{for p in pointers{p.deinitialize(count:planar ? frames:src.count);p.deallocate()}}
        if planar {
            for c in 0..<ch{for i in 0..<frames{pointers[c].advanced(by:i).initialize(to:src[i*ch+c])}}
        }else{for i in src.indices{pointers[0].advanced(by:i).initialize(to:src[i])}}
        let abl=AudioBufferList.allocate(maximumBuffers:planes)
        defer{abl.unsafeMutablePointer.deallocate()}
        abl.unsafeMutablePointer.pointee.mNumberBuffers=UInt32(planes)
        var current=pointers
        let settings=combined ? EqualizerSettings(bandsDB:[6,-3,4,-6,3],preampDB:3) : .flat
        let gain:Double=combined ? 2:0
        let initStart=DispatchTime.now().uptimeNanoseconds
        var tap:AudioTapProcessor?
        var direct:AudioProcessingChain?
        if isTap {
            let t=AudioTapProcessor(equalizer:settings,limiterEnabled:combined,trackGainDB:gain)
            t.prepare(format:format(rate,ch,planar))
            tap=t
        }else{direct=AudioProcessingChain(sampleRate:Double(rate),channels:ch,settings:settings,limiterEnabled:combined,trackGainDB:gain)}
        let initNS=DispatchTime.now().uptimeNanoseconds-initStart
        var cursor=0,calls=0,over=0
        var maxCall:UInt64=0
        let c0=try cpu(),t0=DispatchTime.now().uptimeNanoseconds
        while cursor<frames {
            let n=min(block,frames-cursor)
            for p in 0..<planes{
                current[p]=pointers[p].advanced(by:planar ? cursor:cursor*ch)
                abl[p]=AudioBuffer(mNumberChannels:UInt32(planar ? 1:ch),mDataByteSize:UInt32(n*4*(planar ? 1:ch)),mData:UnsafeMutableRawPointer(current[p]))
            }
            let begin=DispatchTime.now().uptimeNanoseconds
            if let tap=tap{tap.process(bufferList:abl.unsafeMutablePointer,frames:n)}
            else if let direct=direct{
                if planar{direct.process(planar:current,frames:n)}
                else{direct.process(interleaved:current[0],frames:n)}
            }
            let call=DispatchTime.now().uptimeNanoseconds-begin
            maxCall=max(maxCall,call)
            if Double(call)>Double(n)*1e9/Double(rate){over+=1}
            cursor+=n;calls+=1
        }
        let elapsed=DispatchTime.now().uptimeNanoseconds-t0,c1=try cpu()
        var result=[Float](repeating:0,count:src.count)
        if planar{for i in 0..<frames{for c in 0..<ch{result[i*ch+c]=pointers[c][i]}}}
        else{for i in src.indices{result[i]=pointers[0][i]}}
        return Result(pcm:result,elapsed:elapsed,cpu:c1-c0,initNS:initNS,maxCallNS:maxCall,overBudget:over,calls:calls)
    }
    private func run(_ rate:Int,_ ch:Int)throws {
        var input=[Float]();input.reserveCapacity(rate*ch)
        for f in 0..<rate{
            for c in 0..<ch{
                let a=f<rate/4 ? 0.05 : f<rate/2 ? 0.95:0.1
                input.append(c==ch-1 ? 0:Float(a*sin(2*Double.pi*Double(997+c*43)*Double(f)/Double(rate))))
            }
        }
        input[0] = -0.0;input[(rate-1)*ch]=0.98
        print("G0_4B7_PROCESS pid=\(getpid()) rate=\(rate) channels=\(ch)")
        for combined in [false,true] {
            let effect=combined ? "combined":"bypass"
            let oracle=try runPath(input,rate:rate,ch:ch,block:rate,planar:false,isTap:false,combined:combined).pcm
            let expected=hash(oracle)
            if !combined{XCTAssertEqual(expected,hash(input))}
            for planar in [false,true]{
                for block in [256,1024,4096]{
                    for isTap in [false,true]{
                        let route=isTap ? "tap":"direct"
                        let label="rate=\(rate) channels=\(ch) effect=\(effect) planar=\(planar) block=\(block) route=\(route)"
                        let control=try runPath(input,rate:rate,ch:ch,block:block,planar:planar,isTap:isTap,combined:combined)
                        let digest=hash(control.pcm)
                        XCTAssertEqual(digest,expected)
                        XCTAssertTrue(control.pcm.allSatisfy{$0.isFinite})
                        let silent=stride(from:ch-1,to:control.pcm.count,by:ch).reduce(0.0){max($0,abs(Double(control.pcm[$1])))}
                        XCTAssertEqual(silent,0)
                        let peak=control.pcm.reduce(0.0){max($0,abs(Double($1)))}
                        if combined{XCTAssertLessThanOrEqual(peak,pow(10.0,-1.0/20)+0.000001)}
                        print("G0_4B7_CONTROL \(label) hash=\(digest) silent=\(silent) peak=\(peak) calls=\(control.calls)")
                        var times=[UInt64](),cpus=[Int64](),inits=[UInt64](),maxCall:UInt64=0
                        var over=0
                        for index in -1...10{
                            let r=try runPath(input,rate:rate,ch:ch,block:block,planar:planar,isTap:isTap,combined:combined)
                            XCTAssertEqual(hash(r.pcm),expected)
                            XCTAssertEqual(r.calls,control.calls)
                            if index>0{times.append(r.elapsed);cpus.append(r.cpu);inits.append(r.initNS);maxCall=max(maxCall,r.maxCallNS);over+=r.overBudget}
                            print("G0_4B7_CASE \(label) index=\(index) elapsedNS=\(r.elapsed) cpuUS=\(r.cpu) initNS=\(r.initNS) maxCallNS=\(r.maxCallNS) overBudget=\(r.overBudget)")
                        }
                        print("G0_4B7_STATS \(label) n=10 p50NS=\(times.sorted()[4]) p95NS=\(times.sorted()[9]) cpuP50US=\(cpus.sorted()[4]) initP50NS=\(inits.sorted()[4]) worstCallNS=\(maxCall) overBudget=\(over)")
                    }
                }
            }
        }
        print("G0_4B7_SUMMARY controls=24 measured=240 warmups=48")
    }
    func test48Stereo()throws{try run(48000,2)}
    func test96Stereo()throws{try run(96000,2)}
    func test192Stereo()throws{try run(192000,2)}
    func test48Surround()throws{try run(48000,6)}
    func test96Surround()throws{try run(96000,8)}
}
