import AetherLibavfilter
import AetherLibavutil
import AetherLibswresample
@testable import ApoloEngine
import Foundation
import CryptoKit
import Darwin
import XCTest

/// F05D: explicit-layout linked channel-filter observations.
final class G0F05BoundaryTests: XCTestCase {
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
    private func run(_ pcm:[Float],rate:Int32,outRate:Int32,name:String,args:String,inLayout:String,outLayout:String,inCh:Int,outCh:Int)throws->Run {
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
            guard rc>=0,let p=ptr else{print("G0_F05D1_SETUP filter=\(filter) rc=\(rc)");throw LabError.graph}
            return p
        }
        let src=try node("abuffer","src","time_base=1/\(rate):sample_rate=\(rate):sample_fmt=flt:channel_layout=\(inLayout)")
        let effect=try node(name,"effect",args)
        let pin=try node("aformat","pin","sample_fmts=flt:sample_rates=\(outRate):channel_layouts=\(outLayout)")
        let sink=try node("abuffersink","sink",nil)
        guard avfilter_link(src,0,effect,0)>=0,avfilter_link(effect,0,pin,0)>=0,
              avfilter_link(pin,0,sink,0)>=0,avfilter_graph_config(g,nil)>=0 else{throw LabError.graph}
        let tb=av_buffersink_get_time_base(sink)
        guard tb.num==1,tb.den==outRate else{throw LabError.graph}
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
                      f.format==AV_SAMPLE_FMT_FLT.rawValue,f.sample_rate==outRate,
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
        let sizes=[1,7,31,127,509,1024,3,257]
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
    private struct RateResult {
        let pcm: [Float]
        let tail: Int
        let maxDelayInputFrames: Int64
        let delayBeforeDrain: Int64
        let delayAfterDrain: Int64
        let zeroOutputCalls: Int
        let drainCalls: Int
    }

    private func convertRate(_ pcm: [Float], inputRate: Int32, outputRate: Int32,
                             channels: Int, split: Bool) throws -> RateResult {
        var input = AVChannelLayout()
        var output = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &input)
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &output)
        defer {
            av_channel_layout_uninit(&input)
            av_channel_layout_uninit(&output)
        }
        var context: OpaquePointer?
        defer { swr_free(&context) }
        guard swr_alloc_set_opts2(&context, &output, AV_SAMPLE_FMT_FLT, outputRate,
                                  &input, AV_SAMPLE_FMT_FLT, inputRate, 0, nil) >= 0,
              let swr = context, swr_init(swr) >= 0
        else { throw LabError.graph }
        guard !pcm.isEmpty, pcm.count % channels == 0 else { throw LabError.bound }
        var actual: [Float] = []
        var maxDelay: Int64 = 0
        var zeroCalls = 0
        func convert(_ source: UnsafePointer<UnsafePointer<UInt8>?>?, _ count: Int32) throws -> Int {
            let upper = swr_get_out_samples(swr, count)
            guard upper >= 0, upper <= 65536 else { throw LabError.bound }
            let capacity = max(1, Int(upper))
            var chunk = [Float](repeating: 0, count: capacity * channels)
            let got = chunk.withUnsafeMutableBytes { dst -> Int32 in
                var ptr: UnsafeMutablePointer<UInt8>? = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return withUnsafeMutablePointer(to: &ptr) {
                    swr_convert(swr, $0, Int32(capacity), source, count)
                }
            }
            guard got >= 0, got <= Int32(capacity) else { throw LabError.frame }
            actual.append(contentsOf: chunk.prefix(Int(got) * channels))
            guard actual.count <= 65536 * channels else { throw LabError.bound }
            let delay = swr_get_delay(swr, Int64(inputRate))
            guard delay >= 0 else { throw LabError.frame }
            maxDelay = max(maxDelay, delay)
            if count > 0 && got == 0 { zeroCalls += 1 }
            return Int(got)
        }
        let total = pcm.count / channels
        let sizes = [1, 7, 31, 127, 509, 1024, 3, 257]
        var cursor = 0, index = 0
        try pcm.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while cursor < total {
                let count = split ? min(sizes[index % sizes.count], total - cursor) : total
                var src: UnsafePointer<UInt8>? = base.advanced(by: cursor * channels * 4)
                _ = try withUnsafePointer(to: &src) { try convert($0, Int32(count)) }
                cursor += count
                index += 1
            }
        }
        let before = swr_get_delay(swr, Int64(inputRate))
        var tail = 0, calls = 0, drained = false
        for _ in 0..<32 {
            let n = try convert(nil, 0)
            calls += 1
            tail += n
            if n == 0 { drained = true; break }
        }
        guard drained, !actual.isEmpty, actual.allSatisfy({ $0.isFinite })
        else { throw LabError.bound }
        return RateResult(pcm: actual, tail: tail, maxDelayInputFrames: maxDelay,
                          delayBeforeDrain: before,
                          delayAfterDrain: swr_get_delay(swr, Int64(inputRate)),
                          zeroOutputCalls: zeroCalls, drainCalls: calls)
    }

    func testG0F05D1BoundaryAndResample()throws {
        var attempted=0,observed=0,errors=0,compared=0,resampleExact=0
        let rates:[Int32]=[44100,48000,96000,192000]
        for rate in rates{
            let n=Int(rate)/2+37
            let profiles:[(String,String,String,Int,Int,Int)]=[
                ("superUnity","superequalizer","9b=1",1,1,4095),
                ("superBoost","superequalizer","9b=2",1,1,4095),
                ("fireUnity","firequalizer","gain=0:delay=0.01",1,1,Int(rate)/100),
                ("fireZeroPhase","firequalizer","gain=0:delay=0.01:zero_phase=1",1,1,Int(rate)/100),
                ("dialogue","dialoguenhance","original=1:enhance=1:voice=2",2,3,rate>100000 ? 6144 : rate>50000 ? 3072 : 1536)
            ]
            for (label,name,args,inCh,outCh,lag) in profiles{
                attempted+=1
                do{
                    let position=n-8
                    var input=[Float](repeating:0,count:n*inCh)
                    for ch in 0..<inCh{input[position*inCh+ch]=Float(ch+1)/8}
                    let pad=max(16384,lag*3)
                    let extended=input+[Float](repeating:0,count:pad*inCh)
                    let il=inCh==1 ? "mono":"stereo",ol=outCh==1 ? "mono":"3.0"
                    let raw=try run(input,rate:rate,outRate:rate,name:name,args:args,inLayout:il,outLayout:ol,inCh:inCh,outCh:outCh)
                    let padded=try run(extended,rate:rate,outRate:rate,name:name,args:args,inLayout:il,outLayout:ol,inCh:inCh,outCh:outCh)
                    let target=position+lag
                    func at(_ r:Run,_ ch:Int)->String{
                        let i=target*outCh+ch
                        return i<r.pcm.count ? String(r.pcm[i]):"outside"
                    }
                    func energy(_ r:Run,_ ch:Int)->Double{
                        stride(from:ch,to:r.pcm.count,by:outCh).reduce(0.0){$0+Double(r.pcm[$1])*Double(r.pcm[$1])}
                    }
                    let rawTarget=(0..<outCh).map{at(raw,$0)}.joined(separator:",")
                    let paddedTarget=(0..<outCh).map{at(padded,$0)}.joined(separator:",")
                    let rawEnergy=(0..<outCh).map{String(energy(raw,$0))}.joined(separator:",")
                    let paddedEnergy=(0..<outCh).map{String(energy(padded,$0))}.joined(separator:",")
                    let prefix=min(raw.pcm.count,padded.pcm.count)
                    let prefixPeak=zip(raw.pcm.prefix(prefix),padded.pcm.prefix(prefix)).reduce(0.0){max($0,abs(Double($1.0)-Double($1.1)))}
                    observed+=1
                    print("G0_F05D1_BOUNDARY profile=\(label) rate=\(rate) input=\(n) pad=\(pad) impulse=\(position) expectedPeakIndex=\(target) rawFrames=\(raw.pcm.count/outCh) paddedFrames=\(padded.pcm.count/outCh) rawFirst=\(raw.first ?? -1) paddedFirst=\(padded.first ?? -1) rawTarget=\(rawTarget) paddedTarget=\(paddedTarget) rawEnergy=\(rawEnergy) paddedEnergy=\(paddedEnergy) prefixPeak=\(prefixPeak) rawEOF=\(raw.pcm.count/outCh-raw.beforeEOF) paddedEOF=\(padded.pcm.count/outCh-padded.beforeEOF) rawGaps=\(raw.gaps) paddedGaps=\(padded.gaps) rawSHA=\(hash(raw.pcm)) paddedSHA=\(hash(padded.pcm))")
                }catch{errors+=1;print("G0_F05D1_ERROR profile=\(label) rate=\(rate) error=\(error)")}
            }
        }
        for inputRate in rates{
            for outputRate in rates{
                for ch in [1,2]{
                    attempted+=1
                    do{
                        let n=8193,layout=ch==1 ? "mono":"stereo"
                        var input:[Float]=[]
                        for i in 0..<n{for c in 0..<ch{
                            input.append(Float(0.3*sin(2*Double.pi*Double(997+c*43)*Double(i)/Double(inputRate))+0.12*cos(2*Double.pi*Double(2711+c*61)*Double(i)/Double(inputRate))))
                        }}
                        let direct=try convertRate(input,inputRate:inputRate,outputRate:outputRate,channels:ch,split:true)
                        let graph=try run(input,rate:inputRate,outRate:outputRate,name:"aresample",args:"\(outputRate)",inLayout:layout,outLayout:layout,inCh:ch,outCh:ch)
                        let m=min(direct.pcm.count,graph.pcm.count)
                        let peak=zip(direct.pcm.prefix(m),graph.pcm.prefix(m)).reduce(0.0){max($0,abs(Double($1.0)-Double($1.1)))}
                        let exact=direct.pcm.count==graph.pcm.count && zip(direct.pcm,graph.pcm).allSatisfy{$0.0.bitPattern==$0.1.bitPattern}
                        if exact{resampleExact+=1}
                        compared+=m;observed+=1
                        let origin=Double(12345)*Double(outputRate)/Double(inputRate)
                        print("G0_F05D1_RESAMPLE in=\(inputRate) out=\(outputRate) channels=\(ch) directFrames=\(direct.pcm.count/ch) graphFrames=\(graph.pcm.count/ch) compared=\(m) exact=\(exact) peak=\(peak) firstPTS=\(graph.first ?? -1) expectedOrigin=\(origin) endPTS=\(graph.end) gaps=\(graph.gaps) directTail=\(direct.tail) graphTail=\(graph.pcm.count/ch-graph.beforeEOF) directSHA=\(hash(direct.pcm)) graphSHA=\(hash(graph.pcm))")
                    }catch{errors+=1;print("G0_F05D1_ERROR in=\(inputRate) out=\(outputRate) channels=\(ch) error=\(error)")}
                }
            }
        }
        print("G0_F05D1_SUMMARY attempted=\(attempted) observed=\(observed) compared=\(compared) resampleExact=\(resampleExact) errors=\(errors)")
        XCTAssertEqual(attempted,52)
        XCTAssertEqual(observed,52)
        XCTAssertEqual(errors,0)
    }
}
