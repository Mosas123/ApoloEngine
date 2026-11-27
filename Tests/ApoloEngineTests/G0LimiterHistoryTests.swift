import Foundation
import CoreMedia
import AudioToolbox
import CryptoKit
import Darwin
import XCTest
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
@testable import ApoloEngine

/// Compare runner-only reconfiguration in the actual bridge to a raw SWR reference.
/// Fixed output format, real AAC-LC FLTP transitions, no incompatible conversion.
final class G0LimiterHistoryTests:XCTestCase {
    private enum LabError:Error{case invalid(String)}
    private struct Result{
        var pcm=[Float]()
        var tails=[Int]()
        var ends=[Int]()
        var runs=[String]()
        var rate:Int32=0
        var channels:Int32=0
        var jumps=0
        var first:Int64?
        var end:Int64?
    }
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ pcm:[Float])->String{
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func raw(_ url:URL)throws->Result{
        let source=try OpenedSource.open(url:url)
        defer{source.close()}
        var owner=source.takeFormatContext()
        defer{avformat_close_input(&owner)}
        let ic=try XCTUnwrap(owner)
        let index=av_find_best_stream(ic,AVMEDIA_TYPE_AUDIO,-1,-1,nil,0)
        guard index>=0,let stream=ic.pointee.streams[Int(index)],let par=stream.pointee.codecpar,
              par.pointee.codec_id==AV_CODEC_ID_AAC,par.pointee.ch_layout.nb_channels>0,par.pointee.ch_layout.nb_channels<=8,
              par.pointee.sample_rate>0,let codec=avcodec_find_decoder(par.pointee.codec_id) else{throw LabError.invalid("stream")}
        var dc=avcodec_alloc_context3(codec)
        defer{avcodec_free_context(&dc)}
        let decoder=try XCTUnwrap(dc)
        guard avcodec_parameters_to_context(decoder,par)>=0,avcodec_open2(decoder,codec,nil)>=0 else{throw LabError.invalid("codec")}
        var packetOwner=av_packet_alloc(),frameOwner=av_frame_alloc()
        defer{av_packet_free(&packetOwner);av_frame_free(&frameOwner)}
        let packet=try XCTUnwrap(packetOwner),frame=try XCTUnwrap(frameOwner)
        var swr:OpaquePointer?
        defer{swr_free(&swr)}
        var result=Result()
        result.rate=par.pointee.sample_rate
        result.channels=par.pointee.ch_layout.nb_channels
        let outCh=Int(result.channels)
        var signature:String?,runSignature:String?,runFrames=0,decodedFrames=0
        func convert(_ data:UnsafePointer<UnsafePointer<UInt8>?>?,_ count:Int32)throws->Int{
            let ctx=try XCTUnwrap(swr)
            let bound=swr_get_out_samples(ctx,count)
            guard bound>=0,bound<=65536 else{throw LabError.invalid("bound")}
            let capacity=max(1,Int(bound))
            var dst=[Float](repeating:0,count:capacity*outCh)
            let n=dst.withUnsafeMutableBytes{raw -> Int32 in
                var p:UnsafeMutablePointer<UInt8>?=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
                return withUnsafeMutablePointer(to:&p){swr_convert(ctx,$0,Int32(capacity),data,count)}
            }
            guard n>=0,n<=Int32(capacity),result.pcm.count+Int(n)*outCh<=2_000_000 else{throw LabError.invalid("convert")}
            result.pcm.append(contentsOf:dst.prefix(Int(n)*outCh))
            return Int(n)
        }
        func flush()throws{
            var tail=0
            for _ in 0..<32{
                let n=try convert(nil,0)
                tail+=n
                if n==0{result.tails.append(tail);result.ends.append(result.pcm.count/outCh);return}
            }
            throw LabError.invalid("flush bound")
        }
        func consume()throws{
            let v=frame.pointee
            guard v.sample_rate>0,v.ch_layout.nb_channels>0,v.ch_layout.nb_channels<=8,v.format==AV_SAMPLE_FMT_FLTP.rawValue,
                  v.nb_samples>0,v.nb_samples<=8192,let planes=v.extended_data,
                  (0..<Int(v.ch_layout.nb_channels)).allSatisfy({planes[$0] != nil}) else{throw LabError.invalid("unsafe frame shape")}
            decodedFrames+=1
            guard decodedFrames<=2048 else{throw LabError.invalid("frame bound")}
            var layout=v.ch_layout
            let ids=(0..<Int(layout.nb_channels)).map{String(av_channel_layout_channel_from_index(&layout,UInt32($0)).rawValue)}
            let sig="\(v.sample_rate):\(v.format):\(layout.nb_channels):\(ids.joined(separator: ","))"
            if runSignature != sig{
                if let previous=runSignature{result.runs.append("\(previous)/\(runFrames)")}
                runSignature=sig;runFrames=0
            }
            runFrames+=Int(v.nb_samples)
            if swr==nil || signature != sig{
                if swr != nil{try flush();swr_free(&swr)}
                var input=AVChannelLayout(),output=AVChannelLayout()
                guard av_channel_layout_copy(&input,&frame.pointee.ch_layout)>=0 else{throw LabError.invalid("layout")}
                AudioDecoder.makeResamplerOutputLayout(channels:result.channels,into:&output)
                defer{av_channel_layout_uninit(&input);av_channel_layout_uninit(&output)}
                signature=sig
                guard swr_alloc_set_opts2(&swr,&output,AV_SAMPLE_FMT_FLT,result.rate,&input,AV_SAMPLE_FMT_FLTP,v.sample_rate,0,nil)>=0,
                      let ctx=swr,swr_init(ctx)>=0 else{throw LabError.invalid("SWR init")}
            }
            let src=UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(planes))
            _=try convert(src,v.nb_samples)
        }
        let eof:Int32 = -541_478_725,again = -Int32(EAGAIN)
        func drain()throws->Int32{
            for _ in 0..<2048{
                let rc=avcodec_receive_frame(decoder,frame)
                if rc==eof || rc==again{return rc}
                guard rc>=0 else{throw LabError.invalid("receive")}
                defer{av_frame_unref(frame)}
                try consume()
            }
            throw LabError.invalid("drain bound")
        }
        var reached=false
        for _ in 0..<2048{
            let rc=av_read_frame(ic,packet)
            if rc==eof{
                let sent=avcodec_send_packet(decoder,nil)
                guard sent>=0 || sent==eof,try drain()==eof else{throw LabError.invalid("decoder flush")}
                reached=true;break
            }
            guard rc>=0 else{throw LabError.invalid("read")}
            defer{av_packet_unref(packet)}
            if packet.pointee.stream_index != index{continue}
            guard avcodec_send_packet(decoder,packet)>=0 else{throw LabError.invalid("send")}
            _=try drain()
        }
        guard reached,swr != nil,runFrames>0 else{throw LabError.invalid("EOF")}
        result.runs.append("\(try XCTUnwrap(runSignature))/\(runFrames)")
        try flush()
        guard result.pcm.allSatisfy({$0.isFinite}) else{throw LabError.invalid("nonfinite")}
        return result
    }
    private func bridge(_ url:URL,rate:Int32,ch:Int32,effect:String,preserve:Bool)throws->Result{
        guard ProcessInfo.processInfo.environment["APOLO_G0_RECONFIGURE"]=="1" else{throw LabError.invalid("overlay required")}
        let d=AudioDecoder()
        let config=configuration(effect)
        setenv("APOLO_G0_DSP_PRESERVE",preserve ? "1":"0",1)
        defer{unsetenv("APOLO_G0_DSP_PRESERVE")}
        d.processingSettings=config.0
        d.limiterEnabled=config.1
        d.trackGainDB=config.2
        defer{d.close()}
        try d.open(url:url,httpHeaders:[:])
        var r=Result();r.rate=rate;r.channels=ch
        let outCh=Int(ch)
        for _ in 0..<2048{
            guard let b=try d.readNextBuffer() else{
                XCTAssertNil(try d.readNextBuffer())
                XCTAssertFalse(r.pcm.isEmpty)
                return r
            }
            let n=CMSampleBufferGetNumSamples(b)
            guard n>0,r.pcm.count+n*outCh<=2_000_000,
                  let desc=CMSampleBufferGetFormatDescription(b),
                  let a=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let block=CMSampleBufferGetDataBuffer(b),
                  a.pointee.mSampleRate==Double(rate),a.pointee.mChannelsPerFrame==UInt32(ch),
                  a.pointee.mBytesPerFrame==UInt32(ch*4),(a.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  CMBlockBufferGetDataLength(block)==n*outCh*4 else{throw LabError.invalid("bridge format")}
            let t=CMSampleBufferGetPresentationTimeStamp(b).seconds
            guard t.isFinite,abs(t)<3600 else{throw LabError.invalid("PTS")}
            let tick=Int64((t*Double(rate)).rounded())
            if let last=r.end,last != tick{r.jumps+=1}
            if r.first==nil{r.first=tick}
            r.end=tick+Int64(n)
            var chunk=[Float](repeating:0,count:n*outCh)
            let rc=chunk.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
            guard rc==0,chunk.allSatisfy({$0.isFinite}) else{throw LabError.invalid("bridge PCM")}
            r.pcm.append(contentsOf:chunk)
        }
        throw LabError.invalid("bridge bound")
    }
    private func configuration(_ effect:String)->(EqualizerSettings,Bool,Double){
        let eq=EqualizerSettings(bandsDB:[6,-3,4,-6,3],preampDB:3)
        switch effect{
        case "gain":return (.flat,false,6)
        case "eq":return (eq,false,0)
        case "limiter":return (.flat,true,0)
        case "combined":return (eq,true,6)
        default:return (.flat,false,0)
        }
    }
    private func reference(_ raw:Result,effect:String,preserve:Bool)->[Float]{
        let c=configuration(effect),ch=Int(raw.channels)
        func chain()->AudioProcessingChain{
            AudioProcessingChain(sampleRate:Double(raw.rate),channels:ch,settings:c.0,limiterEnabled:c.1,trackGainDB:c.2)
        }
        var pcm=raw.pcm
        var processor=chain()
        var previous=0
        pcm.withUnsafeMutableBufferPointer{p in
            for end in raw.ends{
                if !preserve{processor=chain()}
                processor.process(interleaved:p.baseAddress!.advanced(by:previous*ch),frames:end-previous)
                previous=end
            }
        }
        return pcm
    }
    // Double analytic envelope, independent of production Float recurrence.
    private func oracle(_ input:[Float],ch:Int,rate:Int,ends:[Int],preserve:Bool)->([Double],[Double]){
        let ceiling=pow(10.0,-1.0/20),coef=exp(-1/(0.05*Double(rate)))
        var envelope=1.0,out=[Double](),gains=[Double]()
        let resets=Set(ends.dropLast())
        for i in 0..<(input.count/ch){
            if !preserve && resets.contains(i){envelope=1}
            let peak=(0..<ch).reduce(0.0){max($0,abs(Double(input[i*ch+$1])))}
            let target=peak>ceiling ? ceiling/peak:1
            envelope=target<envelope ? target:target+(envelope-target)*coef
            gains.append(envelope)
            for c in 0..<ch{out.append(Double(input[i*ch+c])*envelope)}
        }
        return (out,gains)
    }
    private func errors(_ actual:[Float],_ expected:[Double])->(Double,Double){
        let d=zip(actual,expected).map{Double($0.0)-$0.1}
        return (d.reduce(0.0){max($0,abs($1))},sqrt(d.reduce(0.0){$0+$1*$1}/Double(d.count)))
    }
    private func analytic(_ rate:Int,_ ch:Int)throws{
        let high=rate/10,low=rate*3/10,n=high+low+high
        let ends=[high,high+low,n]
        var input=[Float]()
        for i in 0..<n{
            let peak:Float=i<high || i>=high+low ? 1.5:0.25
            for c in 0..<ch{input.append(c==0 ? peak:c==ch-1 ? 0:peak*0.25)}
        }
        let ceiling=pow(10.0,-1.0/20),g0=ceiling/1.5
        var results=[[Float]]()
        for preserve in [false,true]{
            let (ref,g)=oracle(input,ch:ch,rate:rate,ends:ends,preserve:preserve)
            var pcm=input,chain=AudioProcessingChain(sampleRate:Double(rate),channels:ch,settings:.flat,limiterEnabled:true,trackGainDB:0)
            var previous=0
            for end in ends{
                if !preserve{chain=AudioProcessingChain(sampleRate:Double(rate),channels:ch,settings:.flat,limiterEnabled:true,trackGainDB:0)}
                pcm.withUnsafeMutableBufferPointer{p in
                    var cursor=previous
                    while cursor<end{
                        let count=min(127,end-cursor)
                        chain.process(interleaved:p.baseAddress!.advanced(by:cursor*ch),frames:count)
                        cursor+=count
                    }
                }
                previous=end
            }
            let (maxError,rms)=errors(pcm,ref)
            let peak=pcm.reduce(0.0){max($0,abs(Double($1)))}
            let offsets=[0,rate/20,rate/10,rate/5,low-1]
            let gains=offsets.map{Double(pcm[(high+$0)*ch])/0.25}
            for (i,k) in offsets.enumerated(){
                let expected=preserve ? 1-(1-g0)*exp(-Double(k+1)/(0.05*Double(rate))):1
                XCTAssertEqual(g[high+k],expected,accuracy:1e-10)
                XCTAssertEqual(gains[i],expected,accuracy:0.001)
            }
            XCTAssertEqual(Double(pcm[0]),ceiling,accuracy:1e-6)
            XCTAssertEqual(Double(pcm[(high+low)*ch]),ceiling,accuracy:1e-6)
            XCTAssertLessThanOrEqual(peak,ceiling+1e-6)
            XCTAssertTrue(pcm.allSatisfy{$0.isFinite})
            XCTAssertEqual(stride(from:ch-1,to:pcm.count,by:ch).map{abs(pcm[$0])}.max(),0)
            XCTAssertLessThanOrEqual(maxError,0.001)
            print("G0_4B86_ANALYTIC rate=\(rate) channels=\(ch) preserve=\(preserve) frames=\(n) hash=\(hash(pcm)) maxError=\(maxError) rms=\(rms) peak=\(peak) gains=\(gains.map{String($0)}.joined(separator:","))")
            results.append(pcm)
        }
        XCTAssertGreaterThan(Double(results[0][high*ch]-results[1][high*ch]),0.09)
    }
    private func run(_ name:String,expectedRates:[Int32],expectedChannels:[Int32])throws{
        let b64=try XCTUnwrap(ProcessInfo.processInfo.environment["APOLO_G0_DYNAMIC_FIXTURE"])
        let data=try XCTUnwrap(Data(base64Encoded:b64))
        guard data.count>0,data.count<=128_000 else{throw LabError.invalid("fixture")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".aac")
        try data.write(to:url);defer{try? FileManager.default.removeItem(at:url)}
        print("G0_4B86_PROCESS pid=\(getpid()) scenario=\(name)")
        let raw=try raw(url)
        let fields=raw.runs.map{$0.split(separator:":")}
        XCTAssertEqual(fields.compactMap{Int32($0[0])},expectedRates)
        XCTAssertEqual(fields.compactMap{Int32($0[2])},expectedChannels)
        XCTAssertEqual(raw.rate,expectedRates[0]);XCTAssertEqual(raw.channels,expectedChannels[0])
        let ch=Int(raw.channels),count=raw.pcm.count/ch
        let ceiling=pow(10.0,-1.0/20)
        let rawPeak=raw.pcm.reduce(0.0){max($0,abs(Double($1)))}
        let active=(0..<count).filter{i in (0..<ch).contains{abs(Double(raw.pcm[i*ch+$0]))>ceiling}}.count
        XCTAssertGreaterThan(active,0,"fixture must engage limiter")
        var outputs=[[Float]]()
        for preserve in [false,true]{
            let ref=reference(raw,effect:"limiter",preserve:preserve)
            let actual=try bridge(url,rate:raw.rate,ch:raw.channels,effect:"limiter",preserve:preserve)
            XCTAssertEqual(actual.pcm.count,ref.count)
            guard actual.pcm.count==ref.count else{throw LabError.invalid("count")}
            let exact=hash(ref)==hash(actual.pcm)
            let (analytic,gains)=oracle(raw.pcm,ch:ch,rate:Int(raw.rate),ends:raw.ends,preserve:preserve)
            let (maxError,rms)=errors(actual.pcm,analytic)
            let peak=actual.pcm.reduce(0.0){max($0,abs(Double($1)))}
            let boundaries=raw.ends.dropLast().map{String(gains[$0])}.joined(separator:",")
            XCTAssertTrue(exact)
            XCTAssertEqual(actual.first,0);XCTAssertEqual(actual.end,Int64(count));XCTAssertEqual(actual.jumps,0)
            XCTAssertLessThanOrEqual(peak,ceiling+1e-6)
            XCTAssertLessThanOrEqual(maxError,0.001)
            print("G0_4B86_CONTROL scenario=\(name) preserve=\(preserve) frames=\(count) channels=\(ch) ends=\(raw.ends.map(String.init).joined(separator:",")) hash=\(hash(actual.pcm)) refHash=\(hash(ref)) exact=\(exact) rawPeak=\(rawPeak) active=\(active) peak=\(peak) maxError=\(maxError) rms=\(rms) boundaryGains=\(boundaries.isEmpty ? "none":boundaries) jumps=\(actual.jumps)")
            outputs.append(actual.pcm)
        }
        let reset=outputs[0],kept=outputs[1]
        let differences=zip(reset,kept).map{abs(Double($0.0)-Double($0.1))}
        let firstEnd=try XCTUnwrap(raw.ends.first)
        XCTAssertEqual(hash(Array(reset.prefix(firstEnd*ch))),hash(Array(kept.prefix(firstEnd*ch))))
        if raw.ends.count==1{XCTAssertEqual(hash(reset),hash(kept))}
        let boundary=raw.ends.dropLast().map{end in
            let lo=end*ch,hi=min(differences.count,(end+256)*ch)
            return String(differences[lo..<hi].max() ?? 0)
        }.joined(separator:",")
        print("G0_4B86_COMPARE scenario=\(name) maxDelta=\(differences.max() ?? 0) rms=\(sqrt(differences.reduce(0.0){$0+$1*$1}/Double(differences.count))) different=\(differences.filter{$0 != 0}.count) boundary256=\(boundary.isEmpty ? "none":boundary)")
        try analytic(Int(raw.rate),max(2,ch))
        print("G0_4B86_SUMMARY controls=2 comparisons=1 analytic=2")
    }
    func testConstant()throws{try run("Constant",expectedRates:[48000],expectedChannels:[2])}
    func testDown()throws{try run("Down",expectedRates:[48000,32000,48000],expectedChannels:[2,2,2])}
    func testUp()throws{try run("Up",expectedRates:[44100,48000,44100],expectedChannels:[2,2,2])}
    func testStereoMono()throws{try run("StereoMono",expectedRates:[48000,48000,48000],expectedChannels:[2,1,2])}
    func testMonoStereo()throws{try run("MonoStereo",expectedRates:[48000,48000,48000],expectedChannels:[1,2,1])}
    func testStereoSix()throws{try run("StereoSix",expectedRates:[48000,48000,48000],expectedChannels:[2,6,2])}
}
