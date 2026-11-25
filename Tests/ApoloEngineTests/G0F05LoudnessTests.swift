import Foundation
import XCTest
@testable import ApoloEngine

/// Independent Double direct-form reference, BS.1770-5 Annex 1 tables at
/// 48 kHz, rate adaptation based on pinned FFmpeg ebur128 coefficient design.
/// No production Biquad, weights, or gating code is used by the reference.
final class G0F05LoudnessTests: XCTestCase {
    private struct Section {
        let b0:Double,b1:Double,b2:Double,a1:Double,a2:Double
        var x1=0.0,x2=0.0,y1=0.0,y2=0.0
        mutating func step(_ x:Double)->Double{
            let y=b0*x+b1*x1+b2*x2-a1*y1-a2*y2
            x2=x1;x1=x;y2=y1;y1=y
            return y
        }
    }
    private struct Reference {
        let strict:Double,partial:Double
        let blocks:Int,absolute:Int,relative:Int
    }
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func sections(_ rate:Int)->(Section,Section){
        if rate==48000{
            return (Section(b0:1.53512485958697,b1:-2.69169618940638,b2:1.19839281085285,a1:-1.69065929318241,a2:0.73248077421585),
                    Section(b0:1,b1:-2,b2:1,a1:-1.99004745483398,a2:0.99007225036621))
        }
        let k=tan(Double.pi*1681.974450955533/Double(rate))
        let q=0.7071752369554196,h=pow(10.0,3.999843853973347/20),v=pow(h,0.4996667741545416)
        let a=1+k/q+k*k
        let shelf=Section(b0:(h+v*k/q+k*k)/a,b1:2*(k*k-h)/a,b2:(h-v*k/q+k*k)/a,a1:2*(k*k-1)/a,a2:(1-k/q+k*k)/a)
        let t=tan(Double.pi*38.13547087602444/Double(rate)),r=0.5003270373238773,d=1+t/r+t*t
        let high=Section(b0:1,b1:-2,b2:1,a1:2*(t*t-1)/d,a2:(1-t/r+t*t)/d)
        return (shelf,high)
    }
    private func gated(_ blocks:[Double])->(Double,Int,Int){
        let floor=pow(10.0,(-70+0.691)/10)
        let absolute=blocks.filter{$0>floor}
        guard !absolute.isEmpty else{return (-.infinity,0,0)}
        let threshold=absolute.reduce(0,+)/Double(absolute.count)*0.1
        let relative=absolute.filter{$0>threshold}
        guard !relative.isEmpty else{return (-.infinity,absolute.count,0)}
        return (-0.691+10*log10(relative.reduce(0,+)/Double(relative.count)),absolute.count,relative.count)
    }
    private func reference(_ pcm:[Float],rate:Int,weights:[Double])->Reference{
        let ch=weights.count,n=pcm.count/ch,hop=rate/10
        let pair=sections(rate)
        var shelves=Array(repeating:pair.0,count:ch),highs=Array(repeating:pair.1,count:ch)
        var sums=[Double](),sum=0.0,count=0
        for i in 0..<n{
            for c in 0..<ch{
                let x=shelves[c].step(Double(pcm[i*ch+c]))
                let y=highs[c].step(x)
                sum+=weights[c]*y*y
            }
            count+=1
            if count==hop{sums.append(sum/Double(hop));sum=0;count=0}
        }
        func blocks(_ h:[Double])->[Double]{
            guard h.count>=4 else{return []}
            return (0...(h.count-4)).map{(h[$0]+h[$0+1]+h[$0+2]+h[$0+3])/4}
        }
        let complete=blocks(sums),strict=gated(complete)
        // Counterfactual: same independent filter but include partial hop
        // with equal weight, and short-signal fallback, as current policy.
        if count>0{sums.append(sum/Double(count))}
        let partial:Double
        if sums.count<4{
            let mean=sums.reduce(0,+)/Double(max(1,sums.count))
            partial=mean>0 ? -0.691+10*log10(mean):-.infinity
        }else{partial=gated(blocks(sums)).0}
        return Reference(strict:strict.0,partial:partial,blocks:complete.count,absolute:strict.1,relative:strict.2)
    }
    private func delta(_ a:Double,_ b:Double)->String{
        a.isFinite && b.isFinite ? String(a-b) : (a==b ? "equalNonfinite":"nonfiniteMismatch")
    }
    func testG0F05E3Loudness()throws{
        var attempted=0,observed=0,finitePairs=0,nonfiniteMismatch=0,nan=0
        for rate in [44100,48000,96000,192000]{
            func record(_ label:String,_ layout:String,_ pcm:[Float],_ weights:[Double]){
                attempted+=1
                let ch=weights.count
                let ref=reference(pcm,rate:rate,weights:weights)
                let actual=LoudnessAnalyzer.integratedLoudness(interleaved:pcm,channels:ch,sampleRate:Double(rate))
                let gain=LoudnessAnalyzer.gain(toTarget:-14,interleaved:pcm,channels:ch,sampleRate:Double(rate))
                if actual.isFinite && ref.strict.isFinite{finitePairs+=1}
                if actual.isFinite != ref.strict.isFinite{nonfiniteMismatch+=1}
                if actual.isNaN || gain.isNaN || ref.strict.isNaN || ref.partial.isNaN{nan+=1}
                observed+=1
                print("G0_F05E3_CASE profile=\(label) rate=\(rate) layout=\(layout) channels=\(ch) frames=\(pcm.count/ch) actual=\(actual) strict=\(ref.strict) partialPolicy=\(ref.partial) deltaStrict=\(delta(actual,ref.strict)) deltaPartial=\(delta(actual,ref.partial)) policyDelta=\(delta(ref.partial,ref.strict)) blocks=\(ref.blocks) absolute=\(ref.absolute) relative=\(ref.relative) gain14=\(gain)")
            }
            let mono:[(String,Int,Double,(Int)->Double)]=[
                ("silence",rate,997,{_ in 0}),
                ("tone997",rate*2,997,{_ in 0.25}),
                ("tone60",rate*2,60,{_ in 0.25}),
                ("tone10000",rate*2,10000,{_ in 0.25}),
                ("belowGate",rate,997,{_ in 0.00001}),
                ("aboveGate",rate,997,{_ in 0.001}),
                ("shortQuiet",rate/20,997,{_ in 0.00001}),
                ("short350",rate*35/100,997,{_ in 0.25}),
                ("short399",rate*399/1000,997,{_ in 0.25}),
                ("exact400",rate*4/10,997,{_ in 0.25}),
                ("partialHot",rate+rate/1000,997,{i in i<rate ? 0.01:0.9}),
                ("partialSilent",rate+rate/20,997,{i in i<rate ? 0.25:0}),
                ("relativeGate",rate*3,997,{i in i<rate ? 0.25:0.001}),
                ("silenceThenTone",rate*3,997,{i in i<rate ? 0:0.25}),
                ("stepSixSeconds",rate*6,997,{i in [0.05,0.25,0.9,0.1,0.6,0.05][min(5,i/rate)]})
            ]
            for (label,n,hz,amplitude) in mono{
                let pcm=(0..<n).map{Float(amplitude($0)*sin(2*Double.pi*hz*Double($0)/Double(rate)+0.31))}
                record(label,"mono",pcm,[1])
            }
            // Explicit source layout weights for isolated channels, not a
            // claim that all same-count layouts are interchangeable.
            // 7.1 here uses the engine's surround weighting convention;
            // not a full Annex 3 positional conformance reference.
            let layouts:[(String,[Double])]=[
                ("stereo",[1,1]),("2.1",[1,1,0]),("3.0",[1,1,1]),
                ("quad",[1,1,1.41,1.41]),("5.0",[1,1,1,1.41,1.41]),
                ("5.1",[1,1,1,0,1.41,1.41]),("7.1",[1,1,1,0,1.41,1.41,1.41,1.41])
            ]
            for (layout,weights) in layouts{
                let ch=weights.count,n=rate*6/10
                for active in 0..<ch{
                    var pcm=[Float](repeating:0,count:n*ch)
                    for i in 0..<n{pcm[i*ch+active]=Float(0.25*sin(2*Double.pi*997*Double(i)/Double(rate)+0.31))}
                    record("isolated\(active)",layout,pcm,weights)
                }
            }
            for sign in [1.0,-1.0]{
                var pcm=[Float]()
                for i in 0..<rate{
                    let s=Float(0.25*sin(2*Double.pi*997*Double(i)/Double(rate)+0.31))
                    pcm.append(s);pcm.append(s*Float(sign))
                }
                record(sign>0 ? "correlated":"anticorrelated","stereo",pcm,[1,1])
            }
        }
        print("G0_F05E3_SUMMARY attempted=\(attempted) observed=\(observed) finitePairs=\(finitePairs) nonfiniteMismatch=\(nonfiniteMismatch) nan=\(nan)")
        XCTAssertEqual(attempted,192)
        XCTAssertEqual(observed,192)
        XCTAssertEqual(nan,0)
        // Nonconforming measurements are observations, not hidden by
        // changing production or declaring arbitrary tolerances.
    }
}
