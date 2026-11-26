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

/// Compare unchanged decoder bridge to two raw-frame SWR models. Only stereo
/// FLTP input is admitted, so stale context never reads missing planes.
final class G0DynamicSWRTests:XCTestCase {
    private enum LabError:Error{case invalid(String)}
    private struct Result{
        var pcm=[Float]()
        var tails=[Int]()
        var runs=[String]()
        var rate:Int32=0
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
    private func raw(_ url:URL,reconfigure:Bool)throws->Result{
        let source=try OpenedSource.open(url:url)
        defer{source.close()}
        var owner=source.takeFormatContext()
        defer{avformat_close_input(&owner)}
        let ic=try XCTUnwrap(owner)
        let index=av_find_best_stream(ic,AVMEDIA_TYPE_AUDIO,-1,-1,nil,0)
        guard index>=0,let stream=ic.pointee.streams[Int(index)],let par=stream.pointee.codecpar,
              par.pointee.codec_id==AV_CODEC_ID_AAC,par.pointee.ch_layout.nb_channels==2,
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
        var inputRate:Int32=0,runRate:Int32=0,runFrames=0,decodedFrames=0
        func convert(_ data:UnsafePointer<UnsafePointer<UInt8>?>?,_ count:Int32)throws->Int{
            let ctx=try XCTUnwrap(swr)
            let bound=swr_get_out_samples(ctx,count)
            guard bound>=0,bound<=65536 else{throw LabError.invalid("bound")}
            let capacity=max(1,Int(bound))
            var dst=[Float](repeating:0,count:capacity*2)
            let n=dst.withUnsafeMutableBytes{raw -> Int32 in
                var p:UnsafeMutablePointer<UInt8>?=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
                return withUnsafeMutablePointer(to:&p){swr_convert(ctx,$0,Int32(capacity),data,count)}
            }
            guard n>=0,n<=Int32(capacity),result.pcm.count+Int(n)*2<=2_000_000 else{throw LabError.invalid("convert")}
            result.pcm.append(contentsOf:dst.prefix(Int(n)*2))
            return Int(n)
        }
        func flush()throws{
            var tail=0
            for _ in 0..<32{
                let n=try convert(nil,0)
                tail+=n
                if n==0{result.tails.append(tail);return}
            }
            throw LabError.invalid("flush bound")
        }
        func consume()throws{
            let v=frame.pointee
            guard v.sample_rate>0,v.ch_layout.nb_channels==2,v.format==AV_SAMPLE_FMT_FLTP.rawValue,
                  v.nb_samples>0,v.nb_samples<=8192,let planes=v.extended_data,
                  planes[0] != nil,planes[1] != nil else{throw LabError.invalid("unsafe frame shape")}
            decodedFrames+=1
            guard decodedFrames<=2048 else{throw LabError.invalid("frame bound")}
            if runRate != v.sample_rate{
                if runRate>0{result.runs.append("\(runRate):\(runFrames)")}
                runRate=v.sample_rate;runFrames=0
            }
            runFrames+=Int(v.nb_samples)
            if swr==nil || (reconfigure && inputRate != v.sample_rate){
                if swr != nil{try flush();swr_free(&swr)}
                var input=AVChannelLayout(),output=AVChannelLayout()
                guard av_channel_layout_copy(&input,&frame.pointee.ch_layout)>=0 else{throw LabError.invalid("layout")}
                av_channel_layout_default(&output,2)
                defer{av_channel_layout_uninit(&input);av_channel_layout_uninit(&output)}
                inputRate=v.sample_rate
                guard swr_alloc_set_opts2(&swr,&output,AV_SAMPLE_FMT_FLT,result.rate,&input,AV_SAMPLE_FMT_FLTP,inputRate,0,nil)>=0,
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
        result.runs.append("\(runRate):\(runFrames)")
        try flush()
        guard result.pcm.allSatisfy({$0.isFinite}) else{throw LabError.invalid("nonfinite")}
        return result
    }
    private func bridge(_ url:URL,rate:Int32)throws->Result{
        let d=AudioDecoder()
        d.limiterEnabled=false
        defer{d.close()}
        try d.open(url:url,httpHeaders:[:])
        var r=Result();r.rate=rate
        for _ in 0..<2048{
            guard let b=try d.readNextBuffer() else{
                XCTAssertNil(try d.readNextBuffer())
                XCTAssertFalse(r.pcm.isEmpty)
                return r
            }
            let n=CMSampleBufferGetNumSamples(b)
            guard n>0,r.pcm.count+n*2<=2_000_000,
                  let desc=CMSampleBufferGetFormatDescription(b),
                  let a=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let block=CMSampleBufferGetDataBuffer(b),
                  a.pointee.mSampleRate==Double(rate),a.pointee.mChannelsPerFrame==2,
                  a.pointee.mBytesPerFrame==8,(a.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  CMBlockBufferGetDataLength(block)==n*8 else{throw LabError.invalid("bridge format")}
            let t=CMSampleBufferGetPresentationTimeStamp(b).seconds
            guard t.isFinite,abs(t)<3600 else{throw LabError.invalid("PTS")}
            let tick=Int64((t*Double(rate)).rounded())
            if let last=r.end,last != tick{r.jumps+=1}
            if r.first==nil{r.first=tick}
            r.end=tick+Int64(n)
            var chunk=[Float](repeating:0,count:n*2)
            let rc=chunk.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
            guard rc==0,chunk.allSatisfy({$0.isFinite}) else{throw LabError.invalid("bridge PCM")}
            r.pcm.append(contentsOf:chunk)
        }
        throw LabError.invalid("bridge bound")
    }
    private func run(_ name:String,expectedRates:[Int32])throws{
        let b64=try XCTUnwrap(ProcessInfo.processInfo.environment["APOLO_G0_DYNAMIC_FIXTURE"])
        let data=try XCTUnwrap(Data(base64Encoded:b64))
        guard data.count>0,data.count<=128_000 else{throw LabError.invalid("fixture")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".aac")
        try data.write(to:url)
        defer{try? FileManager.default.removeItem(at:url)}
        print("G0_4B81_PROCESS pid=\(getpid()) scenario=\(name)")
        let fixed=try raw(url,reconfigure:false),dynamic=try raw(url,reconfigure:true)
        XCTAssertEqual(fixed.runs,dynamic.runs)
        XCTAssertEqual(fixed.rate,dynamic.rate)
        let rates=fixed.runs.compactMap{Int32($0.split(separator:":")[0])}
        XCTAssertEqual(rates,expectedRates,"fixture must actually change decoded AVFrame rate")
        let actual=try bridge(url,rate:fixed.rate)
        let f=hash(fixed.pcm),d=hash(dynamic.pcm),a=hash(actual.pcm)
        if expectedRates.count==1{
            XCTAssertEqual(a,f);XCTAssertEqual(a,d)
        }
        // Dynamic discrepancies are observations, not silently accepted as fidelity.
        print("G0_4B81_CONTROL scenario=\(name) outRate=\(fixed.rate) runs=\(fixed.runs.joined(separator:",")) fixedFrames=\(fixed.pcm.count/2) dynamicFrames=\(dynamic.pcm.count/2) bridgeFrames=\(actual.pcm.count/2) fixedTail=\(fixed.tails.map(String.init).joined(separator:",")) dynamicTail=\(dynamic.tails.map(String.init).joined(separator:",")) fixedHash=\(f) dynamicHash=\(d) bridgeHash=\(a) bridgeFixed=\(a==f) bridgeDynamic=\(a==d) first=\(actual.first ?? Int64.min) end=\(actual.end ?? Int64.min) jumps=\(actual.jumps)")
        print("G0_4B81_SUMMARY controls=1")
    }
    func testConstant()throws{try run("Constant",expectedRates:[48000])}
    func testDown()throws{try run("Down",expectedRates:[48000,32000,48000])}
    func testUp()throws{try run("Up",expectedRates:[44100,48000,44100])}
}
