import AetherLibavfilter
import AetherLibavutil
import Foundation
import CryptoKit
import Darwin
import XCTest

/// Linked filter observations, not the engine's independent Swift DSP.
final class G0F05SpectrumTests: XCTestCase {
    private enum LabError: Error { case graph, frame, bound }
    private struct Run {
        var pcm:[Float]=[]
        var first:Int64?
        var end:Int64=0
        var gaps:[Int64]=[]
        var firstOutputAfterInput=0
        var beforeEOF=0
        var buffers=0
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func hash(_ pcm:[Float])->String {
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func run(_ pcm:[Float],rate:Int32,name:String,args:String)throws->Run {
        var owner=avfilter_graph_alloc(), fi=av_frame_alloc(), fo=av_frame_alloc()
        defer{av_frame_free(&fi);av_frame_free(&fo);avfilter_graph_free(&owner)}
        guard let g=owner,let input=fi,let output=fo else{throw LabError.graph}
        g.pointee.nb_threads=1
        func node(_ filter:String,_ name:String,_ options:String?)throws->UnsafeMutablePointer<AVFilterContext>{
            var ptr:UnsafeMutablePointer<AVFilterContext>?
            guard let f=filter.withCString({avfilter_get_by_name($0)}) else{throw LabError.graph}
            let rc:Int32
            if let options {
                rc=options.withCString { a in name.withCString { n in avfilter_graph_create_filter(&ptr,f,n,a,nil,g) } }
            } else {
                rc=name.withCString { avfilter_graph_create_filter(&ptr,f,$0,nil,nil,g) }
            }
            guard rc>=0,let p=ptr else{print("G0_F05B_SETUP filter=\(filter) rc=\(rc)");throw LabError.graph}
            return p
        }
        let src=try node("abuffer","src","time_base=1/\(rate):sample_rate=\(rate):sample_fmt=flt:channel_layout=mono")
        let effect=try node(name,"effect",args)
        let pin=try node("aformat","pin","sample_fmts=flt:sample_rates=\(rate):channel_layouts=mono")
        let sink=try node("abuffersink","sink",nil)
        guard avfilter_link(src,0,effect,0)>=0,avfilter_link(effect,0,pin,0)>=0,
              avfilter_link(pin,0,sink,0)>=0,avfilter_graph_config(g,nil)>=0 else{throw LabError.graph}
        let tb=av_buffersink_get_time_base(sink)
        guard tb.num==1,tb.den==rate else{throw LabError.graph}
        let eof:Int32 = -541_478_725, again = -Int32(EAGAIN)
        let origin:Int64=12345
        var r=Run(), cursor=0
        func drain()throws->Int32 {
            for _ in 0..<512 {
                let rc=av_buffersink_get_frame(sink,output)
                if rc==eof || rc==again{return rc}
                guard rc>=0 else{throw LabError.frame}
                defer{av_frame_unref(output)}
                let f=output.pointee,n=Int(f.nb_samples)
                guard n>0,n<=262144,r.pcm.count+n<=pcm.count+262144,
                      f.format==AV_SAMPLE_FMT_FLT.rawValue,f.sample_rate==rate,
                      f.ch_layout.nb_channels==1,f.pts != Int64.min,
                      let planes=f.extended_data,let data=planes[0] else{throw LabError.bound}
                if r.first==nil{r.first=f.pts;r.firstOutputAfterInput=cursor}
                else if f.pts != r.end{r.gaps.append(f.pts-r.end)}
                r.end=f.pts+Int64(n);r.buffers+=1
                for i in 0..<n {
                    let v=UnsafeRawPointer(data).loadUnaligned(fromByteOffset:i*4,as:Float.self)
                    guard v.isFinite else{throw LabError.frame}
                    r.pcm.append(v)
                }
            }
            throw LabError.bound
        }
        let sizes=[1,7,31,127,509,1024,257]
        var index=0
        while cursor<pcm.count {
            let n=min(sizes[index%sizes.count],pcm.count-cursor)
            input.pointee.nb_samples=Int32(n);input.pointee.format=AV_SAMPLE_FMT_FLT.rawValue
            input.pointee.sample_rate=rate;input.pointee.pts=origin+Int64(cursor)
            av_channel_layout_default(&input.pointee.ch_layout,1)
            guard av_frame_get_buffer(input,0)>=0,let planes=input.pointee.extended_data,let data=planes[0] else{throw LabError.frame}
            for i in 0..<n{UnsafeMutableRawPointer(data).storeBytes(of:pcm[cursor+i],toByteOffset:i*4,as:Float.self)}
            guard av_buffersrc_add_frame_flags(src,input,0)>=0 else{throw LabError.frame}
            av_frame_unref(input);cursor+=n;index+=1
            _=try drain()
        }
        r.beforeEOF=r.pcm.count
        guard av_buffersrc_add_frame_flags(src,nil,0)>=0,try drain()==eof,try drain()==eof,
              !r.pcm.isEmpty else{throw LabError.graph}
        return r
    }
    private func db(_ x:Double)->Double{20*log10(max(x,1e-15))}
    func testG0F05BFrequencyResponse()throws {
        // Superequalizer gain is linear; firequalizer gain expression is dB.
        let profiles:[(String,String,String,Bool)] = [
            ("eq0","equalizer","f=1000:t=q:w=1:g=0",true),
            ("eq6","equalizer","f=1000:t=q:w=1:g=6",false),
            ("eqMinus6","equalizer","f=1000:t=q:w=1:g=-6",false),
            ("bass0","bass","f=200:g=0",true),
            ("bass6","bass","f=200:g=6",false),
            ("treble0","treble","f=4000:g=0",true),
            ("treble6","treble","f=4000:g=6",false),
            ("highpass","highpass","f=1000:t=q:w=0.7071067811865476",false),
            ("lowpass","lowpass","f=1000:t=q:w=0.7071067811865476",false),
            ("super0","superequalizer","9b=1",true),
            ("super2","superequalizer","9b=2",false),
            ("fire0","firequalizer","gain=0:delay=0.01",true),
            ("fire6","firequalizer","gain=6:delay=0.01",false),
            ("fireZeroPhase","firequalizer","gain=0:delay=0.01:zero_phase=1",true)
        ]
        var attempted=0, observed=0, errors=0, outputValues=0, neutralExact=0
        for rate:Int32 in [44100,48000,96000,192000] {
            // 1 second permits the FIR graph to settle; central 400ms is
            // coherent for all integer multiples of 25 Hz below.
            let n=Int(rate)
            for (label,name,args,neutral) in profiles {
                for hz in [100,200,1000,4000,10000,18000] {
                    attempted+=1
                    do {
                        let pcm=(0..<n).map{Float(0.25*sin(2*Double.pi*Double(hz)*Double($0)/Double(rate)))}
                        let r=try run(pcm,rate:rate,name:name,args:args)
                        let lo=n*3/10,hi=n*7/10
                        guard r.pcm.count>=hi else{throw LabError.bound}
                        var s=0.0,c=0.0,rms=0.0
                        let omega=2*Double.pi*Double(hz)/Double(rate)
                        for i in lo..<hi{
                            let v=Double(r.pcm[i]);s+=v*sin(omega*Double(i));c+=v*cos(omega*Double(i));rms+=v*v
                        }
                        let scale=2.0/Double(hi-lo)
                        s*=scale;c*=scale
                        var residual=0.0
                        for i in lo..<hi{
                            let err=Double(r.pcm[i])-s*sin(omega*Double(i))-c*cos(omega*Double(i))
                            residual+=err*err
                        }
                        let exact=r.pcm.count==pcm.count && zip(r.pcm,pcm).allSatisfy{$0.0.bitPattern==$0.1.bitPattern}
                        if neutral && exact{neutralExact+=1}
                        observed+=1;outputValues+=r.pcm.count
                        print("G0_F05B_CASE profile=\(label) rate=\(rate) hz=\(hz) neutral=\(neutral) input=\(n) output=\(r.pcm.count) firstPTS=\(r.first ?? -1) endPTS=\(r.end) gaps=\(r.gaps) firstOutputAfterInput=\(r.firstOutputAfterInput) eofFrames=\(r.pcm.count-r.beforeEOF) buffers=\(r.buffers) gainDB=\(db(hypot(s,c)/0.25)) rmsDB=\(db(sqrt(rms/Double(hi-lo))/(0.25/sqrt(2.0)))) residualDB=\(db(sqrt(residual/Double(hi-lo))/(0.25/sqrt(2.0)))) phaseRad=\(atan2(c,s)) neutralBitwise=\(neutral && exact) pcmSHA256=\(hash(r.pcm))")
                    }catch{errors+=1;print("G0_F05B_ERROR profile=\(label) rate=\(rate) hz=\(hz) error=\(error)")}
                }
                // Separate impulse records expose signal delay independently
                // of buffering and PTS; no phase unwrapping assumptions.
                attempted+=1
                do{
                    var impulse=[Float](repeating:0,count:n)
                    let pos=n/4;impulse[pos]=0.25
                    let r=try run(impulse,rate:rate,name:name,args:args)
                    guard let peak=r.pcm.indices.max(by:{abs(r.pcm[$0])<abs(r.pcm[$1])}) else{throw LabError.bound}
                    observed+=1;outputValues+=r.pcm.count
                    print("G0_F05B_IMPULSE profile=\(label) rate=\(rate) inputIndex=\(pos) peakIndex=\(peak) peakLag=\(peak-pos) peak=\(r.pcm[peak]) firstPTS=\(r.first ?? -1) endPTS=\(r.end) output=\(r.pcm.count) firstOutputAfterInput=\(r.firstOutputAfterInput) eofFrames=\(r.pcm.count-r.beforeEOF) gaps=\(r.gaps) pcmSHA256=\(hash(r.pcm))")
                }catch{errors+=1;print("G0_F05B_ERROR impulse profile=\(label) rate=\(rate) error=\(error)")}
            }
        }
        print("G0_F05B_SUMMARY attempted=\(attempted) observed=\(observed) outputValues=\(outputValues) neutralToneBitwise=\(neutralExact) errors=\(errors)")
        XCTAssertEqual(attempted,392)
        XCTAssertEqual(observed,attempted)
        XCTAssertEqual(errors,0)
        // Observation completeness, not invented fidelity thresholds.
    }
}
