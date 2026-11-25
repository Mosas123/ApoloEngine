import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

/// F05E.1 invokes the unchanged production DSP class, not an imitation.
final class G0F05SwiftDSPTests: XCTestCase {
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
    func testG0F05E1SwiftDSP()throws {
        let profiles:[(String,EqualizerSettings,Bool,Double)]=[
            ("bypass",.flat,false,0),
            ("gain",EqualizerSettings(preampDB:6),false,-12),
            ("eq",EqualizerSettings(bandsDB:[6,-3,4,-6,3]),false,0),
            ("limit",.flat,true,0),
            ("combined",EqualizerSettings(bandsDB:[6,-3,4,-6,3],preampDB:3),true,2)
        ]
        var attempted=0,observed=0,values=0,partitionExact=0,planarExact=0,bypassExact=0,nonfinite=0
        for rate in [44100,48000,96000,192000]{
            for ch in [1,2,6,8]{
                let n=8193
                var pcm:[Float]=[]
                for i in 0..<n{for c in 0..<ch{
                    let amplitude=i<1024 ? 0.05 : i<4096 ? 0.95 : 0.1
                    let v=Float(amplitude*sin(2*Double.pi*Double(997+c*43)*Double(i)/Double(rate)))
                    pcm.append(c==ch-1 && ch>1 ? 0 : v)
                }}
                pcm[0] = -0.0
                pcm[(n-1)*ch]=0.98
                for (label,settings,limiter,gain) in profiles{
                    attempted+=1
                    let whole=apply(pcm,rate:rate,ch:ch,settings:settings,limiter:limiter,gain:gain,mode:0)
                    let split=apply(pcm,rate:rate,ch:ch,settings:settings,limiter:limiter,gain:gain,mode:1)
                    let planar=apply(pcm,rate:rate,ch:ch,settings:settings,limiter:limiter,gain:gain,mode:2)
                    let p=exact(whole,split),q=exact(whole,planar)
                    if p{partitionExact+=1};if q{planarExact+=1}
                    let finite=whole.allSatisfy{$0.isFinite} && split.allSatisfy{$0.isFinite} && planar.allSatisfy{$0.isFinite}
                    if !finite{nonfinite+=1}
                    let bypass=label=="bypass" && exact(pcm,whole)
                    if bypass{bypassExact+=1}
                    let gainOracle=label=="gain" ? error(whole,pcm.map{$0*Float(pow(10.0,-6.0/20))}) : 0
                    let peak=whole.reduce(0.0){max($0,abs(Double($1)))}
                    let silent=ch>1 ? stride(from:ch-1,to:whole.count,by:ch).reduce(0.0){max($0,abs(Double(whole[$1])))} : 0
                    observed+=1;values+=whole.count
                    print("G0_F05E1_CASE profile=\(label) rate=\(rate) channels=\(ch) frames=\(n) partitionExact=\(p) planarExact=\(q) splitPeakError=\(error(whole,split)) planarPeakError=\(error(whole,planar)) bypassExact=\(bypass) gainOracleError=\(gainOracle) peak=\(peak) silentChannelPeak=\(silent) finite=\(finite) pcmSHA=\(hash(whole))")
                }
            }
            // Individual band center steady-state response, not a fitted
            // copy of the production coefficients.
            for (band,hz) in EqualizerSettings.bandFrequencies.enumerated(){
                for gain in [-6.0,6.0]{
                    attempted+=1
                    var bands=[Double](repeating:0,count:5);bands[band]=gain
                    let n=rate
                    let input=(0..<n).map{Float(0.2*sin(2*Double.pi*hz*Double($0)/Double(rate)))}
                    let out=apply(input,rate:rate,ch:1,settings:EqualizerSettings(bandsDB:bands),limiter:false,gain:0,mode:1)
                    let lo=n/2,hi=n
                    var x=0.0,y=0.0
                    for i in lo..<hi{x+=Double(input[i])*Double(input[i]);y+=Double(out[i])*Double(out[i])}
                    let measured=10*log10(y/x)
                    let finite=out.allSatisfy{$0.isFinite}
                    if !finite{nonfinite+=1}
                    observed+=1;values+=out.count
                    print("G0_F05E1_EQ rate=\(rate) hz=\(hz) requestedDB=\(gain) measuredDB=\(measured) errorDB=\(measured-gain) finite=\(finite) pcmSHA=\(hash(out))")
                }
            }
            // Limiter linked-channel oracle: isolated overload followed by
            // constant low signal. Observe actual release vs Double model.
            attempted+=1
            let n=rate/5,ch=2
            var pcm=[Float](repeating:0.1,count:n*ch)
            pcm[0]=1.5;pcm[1]=0.25
            pcm[(n-1)*ch] = -1.5
            let out=apply(pcm,rate:rate,ch:ch,settings:.flat,limiter:true,gain:0,mode:1)
            let ceiling=pow(10.0,-1.0/20),coef=exp(-1.0/(0.05*Double(rate)))
            var envelope=1.0,maxError=0.0
            for i in 0..<n{
                let peak=max(abs(Double(pcm[i*2])),abs(Double(pcm[i*2+1])))
                let target=peak>ceiling ? ceiling/peak : 1
                envelope=target<envelope ? target : target+(envelope-target)*coef
                for c in 0..<2{maxError=max(maxError,abs(Double(out[i*2+c])-Double(pcm[i*2+c])*envelope))}
            }
            let finite=out.allSatisfy{$0.isFinite};if !finite{nonfinite+=1}
            observed+=1;values+=out.count
            print("G0_F05E1_LIMIT rate=\(rate) frames=\(n) firstL=\(out[0]) firstR=\(out[1]) release50ms=\(out[(rate/20)*2]) lastL=\(out[(n-1)*2]) lastR=\(out[(n-1)*2+1]) oraclePeakError=\(maxError) finite=\(finite) pcmSHA=\(hash(out))")
        }
        print("G0_F05E1_SUMMARY attempted=\(attempted) observed=\(observed) outputValues=\(values) partitionExact=\(partitionExact) planarExact=\(planarExact) bypassExact=\(bypassExact) nonfinite=\(nonfinite)")
        XCTAssertEqual(attempted,124)
        XCTAssertEqual(observed,124)
        XCTAssertEqual(nonfinite,0)
        // Record fidelity discrepancies rather than hide them behind
        // arbitrary tolerances; production fixes belong to later gates.
    }
}
