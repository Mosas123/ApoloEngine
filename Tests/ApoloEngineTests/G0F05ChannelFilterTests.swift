import AetherLibavfilter
import AetherLibavutil
import Foundation
import CryptoKit
import Darwin
import XCTest

/// F05D: explicit-layout linked channel-filter observations.
final class G0F05ChannelFilterTests: XCTestCase {
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
    private func run(_ pcm:[Float],rate:Int32,name:String,args:String,inLayout:String,outLayout:String,inCh:Int,outCh:Int)throws->Run {
        var owner=avfilter_graph_alloc(), fi=av_frame_alloc(), fo=av_frame_alloc()
        defer{av_frame_free(&fi);av_frame_free(&fo);avfilter_graph_free(&owner)}
        guard let g=owner,let input=fi,let output=fo else{throw LabError.graph}
        g.pointee.nb_threads=1
        var sourceLayout=AVChannelLayout(),sinkLayout=AVChannelLayout()
        defer{av_channel_layout_uninit(&sourceLayout);av_channel_layout_uninit(&sinkLayout)}
        guard av_channel_layout_from_string(&sourceLayout,inLayout)>=0,
              av_channel_layout_from_string(&sinkLayout,outLayout)>=0,
              sourceLayout.nb_channels==Int32(inCh),sinkLayout.nb_channels==Int32(outCh),
              pcm.count%inCh==0 else{throw LabError.graph}
        let frames=pcm.count/inCh
        func node(_ filter:String,_ name:String,_ options:String?)throws->UnsafeMutablePointer<AVFilterContext>{
            var ptr:UnsafeMutablePointer<AVFilterContext>?
            guard let f=filter.withCString({avfilter_get_by_name($0)}) else{throw LabError.graph}
            let rc:Int32
            if let options {
                rc=options.withCString { a in name.withCString { n in avfilter_graph_create_filter(&ptr,f,n,a,nil,g) } }
            } else {
                rc=name.withCString { avfilter_graph_create_filter(&ptr,f,$0,nil,nil,g) }
            }
            guard rc>=0,let p=ptr else{print("G0_F05D_SETUP filter=\(filter) rc=\(rc)");throw LabError.graph}
            return p
        }
        let src=try node("abuffer","src","time_base=1/\(rate):sample_rate=\(rate):sample_fmt=flt:channel_layout=\(inLayout)")
        let effect=try node(name,"effect",args)
        let pin=try node("aformat","pin","sample_fmts=flt:sample_rates=\(rate):channel_layouts=\(outLayout)")
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
                guard n>0,n<=262144,r.pcm.count+n*outCh<=(frames+262144)*outCh,
                      f.format==AV_SAMPLE_FMT_FLT.rawValue,f.sample_rate==rate,
                      f.ch_layout.nb_channels==Int32(outCh),f.pts != Int64.min,
                      let planes=f.extended_data,let data=planes[0] else{throw LabError.bound}
                guard av_channel_layout_compare(&output.pointee.ch_layout,&sinkLayout)==0 else{throw LabError.frame}
                if r.first==nil{r.first=f.pts;r.firstOutputAfterInput=cursor}
                else if f.pts != r.end{r.gaps.append(f.pts-r.end)}
                r.end=f.pts+Int64(n);r.buffers+=1
                for i in 0..<(n*outCh) {
                    let v=UnsafeRawPointer(data).loadUnaligned(fromByteOffset:i*4,as:Float.self)
                    guard v.isFinite else{throw LabError.frame}
                    r.pcm.append(v)
                }
            }
            throw LabError.bound
        }
        let sizes=[1,7,31,127,509,1024,257]
        var index=0
        while cursor<frames {
            let n=min(sizes[index%sizes.count],frames-cursor)
            input.pointee.nb_samples=Int32(n);input.pointee.format=AV_SAMPLE_FMT_FLT.rawValue
            input.pointee.sample_rate=rate;input.pointee.pts=origin+Int64(cursor)
            guard av_channel_layout_copy(&input.pointee.ch_layout,&sourceLayout)>=0 else{throw LabError.frame}
            guard av_frame_get_buffer(input,0)>=0,let planes=input.pointee.extended_data,let data=planes[0] else{throw LabError.frame}
            for i in 0..<(n*inCh){UnsafeMutableRawPointer(data).storeBytes(of:pcm[cursor*inCh+i],toByteOffset:i*4,as:Float.self)}
            guard av_buffersrc_add_frame_flags(src,input,0)>=0 else{throw LabError.frame}
            av_frame_unref(input);cursor+=n;index+=1
            _=try drain()
        }
        r.beforeEOF=r.pcm.count/outCh
        guard av_buffersrc_add_frame_flags(src,nil,0)>=0,try drain()==eof,try drain()==eof,
              !r.pcm.isEmpty else{throw LabError.graph}
        return r
    }
    private struct Profile {
        let label:String,filter:String,args:String,input:String,output:String
        let inCh:Int,outCh:Int
        let matrix:[[Float]]?
        init(_ label:String,_ filter:String,_ args:String,_ input:String,_ output:String,
             _ inCh:Int,_ outCh:Int,_ matrix:[[Float]]?=nil){
            self.label=label;self.filter=filter;self.args=args
            self.input=input;self.output=output;self.inCh=inCh;self.outCh=outCh;self.matrix=matrix
        }
    }
    private func db(_ x:Double)->Double{20*log10(max(x,1e-15))}
    func testG0F05DChannelFilters()throws {
        let profiles=[
            Profile("panIdentity","pan","stereo|c0=c0|c1=c1","stereo","stereo",2,2,[[1,0],[0,1]]),
            Profile("panSwap","pan","stereo|c0=c1|c1=c0","stereo","stereo",2,2,[[0,1],[1,0]]),
            Profile("panMono","pan","mono|c0=0.5*c0+0.5*c1","stereo","mono",2,1,[[0.5,0.5]]),
            Profile("panDuplicate","pan","stereo|c0=c0|c1=c0","mono","stereo",1,2,[[1],[1]]),
            Profile("pan51","pan","stereo|c0=0.5*c0+0.25*c2+0.25*c4|c1=0.5*c1+0.25*c2+0.25*c5","5.1","stereo",6,2,[[0.5,0,0.25,0,0.25,0],[0,0.5,0.25,0,0,0.25]]),
            Profile("crossNeutral","crossfeed","strength=0:level_in=1:level_out=1","stereo","stereo",2,2),
            Profile("crossDefault","crossfeed","strength=0.2:range=0.5:slope=0.5:level_in=0.9:level_out=1","stereo","stereo",2,2),
            Profile("crossStrong","crossfeed","strength=0.8:range=0.5:slope=0.5:level_in=1:level_out=1","stereo","stereo",2,2),
            Profile("crossBlock","crossfeed","strength=0.8:range=0.5:slope=0.5:level_in=1:level_out=1:block_size=1024","stereo","stereo",2,2),
            Profile("dialogueDefault","dialoguenhance","original=1:enhance=1:voice=2","stereo","3.0",2,3),
            Profile("dialogueNoEnhance","dialoguenhance","original=1:enhance=0:voice=2","stereo","3.0",2,3)
        ]
        var attempted=0,observed=0,errors=0,values=0,panCompared=0,panExact=0
        for rate:Int32 in [44100,48000,96000,192000]{
            let slot=Int(rate)/4
            // 8 slots plus a deliberately non-block-aligned 37-sample tail.
            let frames=8*slot+37
            for p in profiles{
                for impulse in [false,true]{
                    attempted+=1
                    do{
                        var input=[Float](repeating:0,count:frames*p.inCh)
                        for ch in 0..<p.inCh{
                            if impulse{
                                input[(ch*slot+slot/4)*p.inCh+ch]=0.25
                            }else{
                                for i in 0..<slot{
                                    input[(ch*slot+i)*p.inCh+ch]=Float(0.25*sin(2*Double.pi*1000*Double(i)/Double(rate)))
                                }
                            }
                        }
                        if impulse{
                            for ch in 0..<p.inCh{input[(frames-8)*p.inCh+ch]=Float(ch+1)/32}
                        }else{
                            for i in 0..<slot{
                                let tone=Float(0.25*sin(2*Double.pi*1000*Double(i)/Double(rate)))
                                for ch in 0..<p.inCh{
                                    input[(6*slot+i)*p.inCh+ch]=tone
                                    input[(7*slot+i)*p.inCh+ch]=ch%2==0 ? tone : -tone
                                }
                            }
                        }
                        let r=try run(input,rate:rate,name:p.filter,args:p.args,inLayout:p.input,outLayout:p.output,inCh:p.inCh,outCh:p.outCh)
                        let outFrames=r.pcm.count/p.outCh
                        var peakError=0.0,exact=true,comparison=0
                        if let matrix=p.matrix{
                            if outFrames != frames{exact=false}
                            for i in 0..<min(frames,outFrames){
                                for o in 0..<p.outCh{
                                    var expected:Float=0
                                    for ch in 0..<p.inCh{expected+=matrix[o][ch]*input[i*p.inCh+ch]}
                                    let actual=r.pcm[i*p.outCh+o]
                                    peakError=max(peakError,abs(Double(actual)-Double(expected)))
                                    exact=exact && actual.bitPattern==expected.bitPattern
                                    comparison+=1
                                }
                            }
                            panCompared+=comparison
                            if exact{panExact+=1}
                        }
                        var metrics:[String]=[]
                        // Input-channel isolated slots, followed by correlated and
                        // anti-correlated probes. Output order is explicit layout.
                        for s in Array(0..<p.inCh)+[6,7]{
                            let lo=s*slot+slot/3,hi=min(outFrames,s*slot+slot*2/3)
                            if impulse{
                                let start=s*slot,end=min(outFrames,(s+1)*slot)
                                for o in 0..<p.outCh{
                                    var peak:Float=0,idx = -1
                                    if end>start{
                                        for i in start..<end{
                                            let v=r.pcm[i*p.outCh+o]
                                            if abs(v)>abs(peak){peak=v;idx=i}
                                        }
                                    }
                                    metrics.append("\(s):\(o):\(idx):\(peak)")
                                }
                            }else{
                                for o in 0..<p.outCh{
                                    var energy=0.0
                                    if hi>lo{for i in lo..<hi{let v=Double(r.pcm[i*p.outCh+o]);energy+=v*v}}
                                    let rms=sqrt(energy/Double(max(1,hi-lo)))
                                    metrics.append("\(s):\(o):\(db(rms/(0.25/sqrt(2.0))))")
                                }
                            }
                        }
                        // Tail peak is only a probe of final output region, not
                        // proof of impulse recovery for nonlinear/FFT filters.
                        var tail:[String]=[]
                        for o in 0..<p.outCh{
                            var peak:Float=0,idx = -1
                            for i in max(0,outFrames-Int(rate)/10)..<outFrames{
                                let v=r.pcm[i*p.outCh+o]
                                if abs(v)>abs(peak){peak=v;idx=i}
                            }
                            tail.append("\(o):\(idx):\(peak)")
                        }
                        observed+=1;values+=r.pcm.count
                        print("G0_F05D_CASE profile=\(p.label) rate=\(rate) impulse=\(impulse) inLayout=\(p.input) outLayout=\(p.output) inFrames=\(frames) outFrames=\(outFrames) firstPTS=\(r.first ?? -1) endPTS=\(r.end) gaps=\(r.gaps) firstOutputAfterInput=\(r.firstOutputAfterInput) eofFrames=\(outFrames-r.beforeEOF) compared=\(comparison) panExact=\(p.matrix != nil && exact) panPeakError=\(peakError) metrics=\(metrics.joined(separator:",")) tail=\(tail.joined(separator:",")) pcmSHA256=\(hash(r.pcm))")
                    }catch{errors+=1;print("G0_F05D_ERROR profile=\(p.label) rate=\(rate) impulse=\(impulse) error=\(error)")}
                }
            }
        }
        print("G0_F05D_SUMMARY attempted=\(attempted) observed=\(observed) outputValues=\(values) panCompared=\(panCompared) panExact=\(panExact) errors=\(errors)")
        XCTAssertEqual(attempted,88)
        XCTAssertEqual(observed,88)
        XCTAssertEqual(errors,0)
        // No arbitrary spectral or dialogue extraction thresholds.
    }
}
