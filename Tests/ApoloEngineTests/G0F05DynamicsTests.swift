import AetherLibavfilter
import AetherLibavutil
import AetherLibswresample
@testable import ApoloEngine
import Foundation
import CryptoKit
import Darwin
import XCTest

/// F05C: dynamics observations, separate from actual Swift playback DSP.
final class G0F05DynamicsTests: XCTestCase {
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
            guard rc>=0,let p=ptr else{print("G0_F05C_SETUP filter=\(filter) rc=\(rc)");throw LabError.graph}
            return p
        }
        let src=try node("abuffer","src","time_base=1/\(rate):sample_rate=\(rate):sample_fmt=flt:channel_layout=mono")
        let effect=try node(name,"effect",args)
        let pin=try node("aformat","pin","sample_fmts=flt:sample_rates=\(rate):channel_layouts=mono")
        let sink=try node("abuffersink","sink",nil)
        guard avfilter_link(src,0,effect,0)>=0,avfilter_link(effect,0,pin,0)>=0,
              avfilter_link(pin,0,sink,0)>=0,avfilter_graph_config(g,nil)>=0 else{throw LabError.graph}
        if let dump=avfilter_graph_dump(g,nil) {
            let graph=String(cString:dump).replacingOccurrences(of:"\n",with:" ")
            print("G0_F05C_GRAPH rate=\(rate) filter=\(name) args=\(args) graph=\(graph)")
            av_free(dump)
        }
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
                // loudnorm drains up to a three-second window. Keep a
                // rate-scaled finite bound and distinguish it from shape errors.
                let frameLimit=max(262144,Int(rate)*3+4096)
                guard n>0,n<=frameLimit,r.pcm.count+n<=pcm.count+frameLimit else {
                    print("G0_F05C_BOUND rate=\(rate) filter=\(name) frame=\(n) accumulated=\(r.pcm.count) input=\(pcm.count) limit=\(frameLimit)")
                    throw LabError.bound
                }
                guard
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
        let sizes=[1,7,127,509,4096,1024,257]
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
    private func db(_ x:Double)->Double { 20*log10(max(x,1e-15)) }
    private func peak(_ x:[Float])->Double { x.reduce(0.0){max($0,abs(Double($1)))} }
    // Fixed 192k observation grid; SWR interpolation is not a certified
    // BS.1770 true-peak meter. At 192k this is simply the sample peak.
    private func interpolatedPeak(_ pcm:[Float],rate:Int32)throws->Double {
        if rate==192000{return peak(pcm)}
        var a=AVChannelLayout(),b=AVChannelLayout(),owner:OpaquePointer?
        av_channel_layout_default(&a,1);av_channel_layout_default(&b,1)
        defer{av_channel_layout_uninit(&a);av_channel_layout_uninit(&b);swr_free(&owner)}
        guard swr_alloc_set_opts2(&owner,&b,AV_SAMPLE_FMT_FLT,192000,
                                  &a,AV_SAMPLE_FMT_FLT,rate,0,nil)>=0,
              let swr=owner,swr_init(swr)>=0 else{throw LabError.graph}
        var maximum=0.0
        func step(_ src:UnsafePointer<UnsafePointer<UInt8>?>?,_ n:Int32)throws->Int32 {
            let cap=swr_get_out_samples(swr,n)
            guard cap>=0,cap<=65536 else{throw LabError.bound}
            var dst=[Float](repeating:0,count:max(1,Int(cap)))
            let rc=dst.withUnsafeMutableBytes{ raw -> Int32 in
                var p:UnsafeMutablePointer<UInt8>?=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
                return withUnsafeMutablePointer(to:&p){swr_convert(swr,$0,max(1,cap),src,n)}
            }
            guard rc>=0,rc<=max(1,cap) else{throw LabError.frame}
            for v in dst.prefix(Int(rc)){
                guard v.isFinite else{throw LabError.frame}
                maximum=max(maximum,abs(Double(v)))
            }
            return rc
        }
        try pcm.withUnsafeBytes{raw in
            let p=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
            var cursor=0
            while cursor<pcm.count{
                let n=min(4096,pcm.count-cursor)
                var src:UnsafePointer<UInt8>?=p.advanced(by:cursor*4)
                _=try withUnsafePointer(to:&src){try step($0,Int32(n))}
                cursor+=n
            }
        }
        for _ in 0..<32{if try step(nil,0)==0{return maximum}}
        throw LabError.bound
    }
    private func rms(_ pcm:[Float],_ lo:Int,_ hi:Int)->Double {
        guard lo>=0,hi<=pcm.count,hi>lo else{return 0}
        return sqrt(pcm[lo..<hi].reduce(0.0){$0+Double($1)*Double($1)}/Double(hi-lo))
    }

    func testG0F05CDynamics()throws {
        let profiles:[(String,String,String)] = [
            ("compUnity","acompressor","threshold=0.2:ratio=1:attack=10:release=100:knee=1:detection=peak:makeup=1"),
            ("comp4","acompressor","threshold=0.2:ratio=4:attack=10:release=100:knee=1:detection=peak:makeup=1"),
            ("limitRaw","alimiter","limit=0.5:attack=5:release=50:level=0:latency=0"),
            ("limitAligned","alimiter","limit=0.5:attack=5:release=50:level=0:latency=1"),
            ("limitAuto","alimiter","limit=0.5:attack=5:release=50:level=1:latency=1"),
            ("dynShort","dynaudnorm","framelen=100:gausssize=5:peak=0.9:maxgain=4"),
            ("dynDefault","dynaudnorm","peak=0.9:maxgain=4"),
            ("loud16","loudnorm","I=-16:LRA=7:TP=-1:linear=0:print_format=json"),
            ("loud23","loudnorm","I=-23:LRA=7:TP=-2:linear=0:print_format=json")
        ]
        let amplitudes:[Double]=[0.05,0.25,0.9,0.1,0.6,0.05]
        var attempted=0,observed=0,errors=0,values=0,unityExact=0,boundary=0
        for rate:Int32 in [44100,48000,96000,192000] {
            let n=Int(rate)
            // Alternating one-second levels plus deterministic phase;
            // a continuous 997 Hz tone reveals attack/release and gain.
            let pcm=(0..<(6*n)).map{i in
                Float(amplitudes[i/n]*sin(2*Double.pi*997*Double(i)/Double(rate)+0.31))
            }
            let inPeak=peak(pcm),inInterp=try interpolatedPeak(pcm,rate:rate)
            let inLU=LoudnessAnalyzer.integratedLoudness(interleaved:pcm,channels:1,sampleRate:Double(rate))
            for (label,name,args) in profiles {
                attempted+=1
                do {
                    let r=try run(pcm,rate:rate,name:name,args:args)
                    let outPeak=peak(r.pcm),outInterp=try interpolatedPeak(r.pcm,rate:rate)
                    let outLU=LoudnessAnalyzer.integratedLoudness(interleaved:r.pcm,channels:1,sampleRate:Double(rate))
                    // Raw buffer-index windows, not latency-compensated timing.
                    let gains=(0..<6).map{i in
                        let lo=i*n+n*6/10,hi=i*n+n*9/10
                        return hi<=r.pcm.count ? String(db(rms(r.pcm,lo,hi)/max(rms(pcm,lo,hi),1e-15))) : "NA"
                    }.joined(separator:",")
                    let exact=r.pcm.count==pcm.count && zip(r.pcm,pcm).allSatisfy{$0.0.bitPattern==$0.1.bitPattern}
                    if label=="compUnity" && exact{unityExact+=1}
                    observed+=1;values+=r.pcm.count
                    print("G0_F05C_CASE profile=\(label) rate=\(rate) input=\(pcm.count) output=\(r.pcm.count) firstPTS=\(r.first ?? -1) endPTS=\(r.end) gaps=\(r.gaps) firstOutputAfterInput=\(r.firstOutputAfterInput) eofFrames=\(r.pcm.count-r.beforeEOF) buffers=\(r.buffers) inSamplePeakDBFS=\(db(inPeak)) outSamplePeakDBFS=\(db(outPeak)) inGrid192kPeakDBFS=\(db(inInterp)) outGrid192kPeakDBFS=\(db(outInterp)) inEngineLUFS=\(inLU) outEngineLUFS=\(outLU) windowGainDB=\(gains) bitwise=\(exact) pcmSHA256=\(hash(r.pcm))")
                }catch{errors+=1;print("G0_F05C_ERROR profile=\(label) rate=\(rate) error=\(error)")}
                if name=="alimiter" {
                    // End impulse 1 ms before EOF, shorter than 5 ms lookahead.
                    // Keep beginning and middle probes separated from it.
                    attempted+=1
                    do {
                        var input=[Float](repeating:0,count:n)
                        input[n/10]=0.2;input[n/2]=0.4;input[n-n/1000]=0.3
                        let r=try run(input,rate:rate,name:name,args:args)
                        let hits=r.pcm.indices.filter{abs(r.pcm[$0])>0.01}
                        let hitValues=hits.map{String(r.pcm[$0])}.joined(separator:",")
                        observed+=1;boundary+=1;values+=r.pcm.count
                        print("G0_F05C_BOUNDARY profile=\(label) rate=\(rate) inputIndices=\([n/10,n/2,n-n/1000]) outputIndices=\(hits) values=\(hitValues) output=\(r.pcm.count) firstPTS=\(r.first ?? -1) endPTS=\(r.end) gaps=\(r.gaps) eofFrames=\(r.pcm.count-r.beforeEOF) pcmSHA256=\(hash(r.pcm))")
                    }catch{errors+=1;print("G0_F05C_ERROR boundary profile=\(label) rate=\(rate) error=\(error)")}
                }
            }
        }
        print("G0_F05C_SUMMARY attempted=\(attempted) observed=\(observed) outputValues=\(values) unityExact=\(unityExact) boundary=\(boundary) errors=\(errors)")
        XCTAssertEqual(attempted,48)
        XCTAssertEqual(observed,48)
        XCTAssertEqual(boundary,12)
        XCTAssertEqual(errors,0)
        // No arbitrary loudness/peak tolerance or acoustic certification.
    }
}
