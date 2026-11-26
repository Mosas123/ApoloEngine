import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import ApoloEngine

/// Timing isolates the unchanged Swift playback DSP; no renderer or decoder timing.
final class G0DSPCostTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func hash(_ pcm:[Float])->String {
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func exact(_ a:[Float],_ b:[Float])->Bool{
        a.count==b.count && zip(a,b).allSatisfy{$0.0.bitPattern==$0.1.bitPattern}
    }
    private func error(_ a:[Float],_ b:[Float])->Double{
        zip(a,b).reduce(0.0){max($0,abs(Double($1.0)-Double($1.1)))}
    }
    private func apply(_ input:[Float],rate:Int,ch:Int,settings:EqualizerSettings,
                       limiter:Bool,gain:Double,mode:Int)->[Float] {
        let chain=AudioProcessingChain(sampleRate:Double(rate),channels:ch,settings:settings,limiterEnabled:limiter,trackGainDB:gain)
        let n=input.count/ch
        let sizes=[1,7,31,127,509,1024,3,257]
        var pcm=input,cursor=0,index=0
        while cursor<n{
            let count=mode==0 ? n : min(sizes[index%sizes.count],n-cursor)
            if mode==2{
                let ptrs=(0..<ch).map{_ in UnsafeMutablePointer<Float>.allocate(capacity:count)}
                for c in 0..<ch{for i in 0..<count{ptrs[c].advanced(by:i).initialize(to:pcm[(cursor+i)*ch+c])}}
                chain.process(planar:ptrs,frames:count)
                for c in 0..<ch{
                    for i in 0..<count{pcm[(cursor+i)*ch+c]=ptrs[c][i]}
                    ptrs[c].deinitialize(count:count);ptrs[c].deallocate()
                }
            }else{
                pcm.withUnsafeMutableBufferPointer{chain.process(interleaved:$0.baseAddress!.advanced(by:cursor*ch),frames:count)}
            }
            cursor+=count;index+=1
        }
        return pcm
    }
    private func cpu()throws->Int64 {
        var u=rusage()
        guard getrusage(RUSAGE_SELF,&u)==0 else{throw NSError(domain:"G0DSP",code:1)}
        return Int64(u.ru_utime.tv_sec)*1000000+Int64(u.ru_utime.tv_usec)+Int64(u.ru_stime.tv_sec)*1000000+Int64(u.ru_stime.tv_usec)
    }
    // Independent Double direct-form I reference (not production transposed DF-II).
    private func oracle(_ pcm:[Float],rate:Int,ch:Int,settings:EqualizerSettings,limiter:Bool,gain:Double)->[Double] {
        let coefficients=zip(EqualizerSettings.bandFrequencies,settings.bandsDB).filter{$0.1 != 0}.map{hz,db -> [Double] in
            let a=pow(10,db/40),w=2*Double.pi*hz/Double(rate),alpha=sin(w)/2,den=1+alpha/a
            return [(1+alpha*a)/den,-2*cos(w)/den,(1-alpha*a)/den,-2*cos(w)/den,(1-alpha/a)/den]
        }
        var state=Array(repeating:Array(repeating:[0.0,0.0,0.0,0.0],count:coefficients.count),count:ch)
        let multiplier=pow(10,(settings.preampDB+gain)/20),ceiling=pow(10.0,-1.0/20),release=exp(-1/(0.05*Double(rate)))
        var envelope=1.0,out=[Double](repeating:0,count:pcm.count)
        for i in 0..<(pcm.count/ch) {
            var peak=0.0
            for c in 0..<ch {
                var x=Double(pcm[i*ch+c])*multiplier
                for j in coefficients.indices {
                    let b=coefficients[j],s=state[c][j]
                    let y=b[0]*x+b[1]*s[0]+b[2]*s[1]-b[3]*s[2]-b[4]*s[3]
                    state[c][j]=[x,s[0],y,s[2]];x=y
                }
                out[i*ch+c]=x;peak=max(peak,abs(x))
            }
            if limiter {
                let target=peak>ceiling ? ceiling/peak:1
                envelope=target<envelope ? target:target+(envelope-target)*release
                for c in 0..<ch{out[i*ch+c]*=envelope}
            }
        }
        return out
    }
    private func run(_ rate:Int,_ ch:Int)throws {
        let profiles:[(String,EqualizerSettings,Bool,Double)]=[
            ("bypass",.flat,false,0),("gain",EqualizerSettings(preampDB:6),false,-12),
            ("eq",EqualizerSettings(bandsDB:[6,-3,4,-6,3]),false,0),
            ("limit",.flat,true,0),("combined",EqualizerSettings(bandsDB:[6,-3,4,-6,3],preampDB:3),true,2)]
        let n=rate
        var input=[Float]();input.reserveCapacity(n*ch)
        for i in 0..<n {
            for c in 0..<ch {
                let amplitude=i<n/4 ? 0.05:i<n/2 ? 0.95:0.1
                let v=Float(amplitude*sin(2*Double.pi*Double(997+c*43)*Double(i)/Double(rate)))
                input.append(c==ch-1 ? 0:v)
            }
        }
        input[0] = -0.0;input[(n-1)*ch]=0.98
        print("G0_4B5_PROCESS pid=\(getpid()) rate=\(rate) channels=\(ch)")
        for (name,settings,limiter,gain) in profiles {
            let whole=apply(input,rate:rate,ch:ch,settings:settings,limiter:limiter,gain:gain,mode:0)
            let split=apply(input,rate:rate,ch:ch,settings:settings,limiter:limiter,gain:gain,mode:1)
            XCTAssertTrue(exact(whole,split));XCTAssertTrue(whole.allSatisfy{$0.isFinite})
            if name=="bypass"{XCTAssertTrue(exact(whole,input))}
            if name=="gain"{XCTAssertTrue(exact(whole,input.map{$0*Float(pow(10.0,-6.0/20))}))}
            let independent=oracle(input,rate:rate,ch:ch,settings:settings,limiter:limiter,gain:gain)
            var maxError=0.0,sum=0.0,peak=0.0
            for (a,b) in zip(whole,independent){let e=abs(Double(a)-b);maxError=max(maxError,e);sum+=e*e;peak=max(peak,abs(Double(a)))}
            let silent=stride(from:ch-1,to:whole.count,by:ch).reduce(0.0){max($0,abs(Double(whole[$1])))}
            XCTAssertEqual(silent,0)
            if limiter{XCTAssertLessThanOrEqual(peak,pow(10.0,-1.0/20)+0.000001)}
            let digest=hash(whole)
            print("G0_4B5_CONTROL profile=\(name) rate=\(rate) channels=\(ch) frames=\(n) hash=\(digest) maxError=\(maxError) rmsError=\(sqrt(sum/Double(whole.count))) peak=\(peak) silent=\(silent)")
            for block in [256,1024,4096] {
                var elapsed=[UInt64](),cpus=[Int64](),initTimes=[UInt64]()
                for index in -1...10 {
                    // Input copy, allocation, coefficient construction, hash outside timed DSP.
                    var pcm=input.map{$0}
                    let i0=DispatchTime.now().uptimeNanoseconds
                    let chain=AudioProcessingChain(sampleRate:Double(rate),channels:ch,settings:settings,limiterEnabled:limiter,trackGainDB:gain)
                    let initNS=DispatchTime.now().uptimeNanoseconds-i0
                    var cursor=0
                    let cpu0=try cpu(),t0=DispatchTime.now().uptimeNanoseconds
                    pcm.withUnsafeMutableBufferPointer{p in
                        while cursor<n {
                            let count=min(block,n-cursor)
                            chain.process(interleaved:p.baseAddress!.advanced(by:cursor*ch),frames:count)
                            cursor+=count
                        }
                    }
                    let ns=DispatchTime.now().uptimeNanoseconds-t0,cpu1=try cpu()
                    XCTAssertTrue(exact(pcm,whole))
                    if index>0{elapsed.append(ns);cpus.append(cpu1-cpu0);initTimes.append(initNS)}
                    print("G0_4B5_CASE profile=\(name) rate=\(rate) channels=\(ch) block=\(block) index=\(index) elapsedNS=\(ns) cpuUS=\(cpu1-cpu0) initNS=\(initNS)")
                }
                let t=elapsed.sorted(),c=cpus.sorted(),i=initTimes.sorted()
                print("G0_4B5_STATS profile=\(name) rate=\(rate) channels=\(ch) block=\(block) n=10 p50NS=\(t[4]) p95NS=\(t[9]) cpuP50US=\(c[4]) initP50NS=\(i[4])")
            }
        }
        print("G0_4B5_SUMMARY rate=\(rate) channels=\(ch) controls=5 measured=150 warmups=30")
    }
    func test48Stereo()throws{try run(48000,2)}
    func test96Stereo()throws{try run(96000,2)}
    func test192Stereo()throws{try run(192000,2)}
    func test48Surround()throws{try run(48000,6)}
    func test96Surround()throws{try run(96000,8)}
}
