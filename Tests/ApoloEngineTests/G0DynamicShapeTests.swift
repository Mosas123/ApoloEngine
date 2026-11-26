import Foundation
import CoreMedia
import AudioToolbox
import Darwin
import CryptoKit
import XCTest
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

/// Observe real AAC channel changes, then use a runner-only safety guard
/// in the actual bridge. Never pass incompatible frames to stale SWR.
final class G0DynamicShapeTests:XCTestCase {
    private enum LabError:Error {case invalid(String)}
    private struct FrameShape:Equatable {
        let rate:Int32
        let fmt:Int32
        let ch:Int32
        let ids:[String]
        var key:String{"\(rate):\(fmt):\(ch):\(ids.joined(separator:","))"}
    }
    private struct Run {
        let shape:FrameShape
        var samples:Int=0
        var frames:Int=0
    }
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func shape(rate:Int32,fmt:Int32,layout:inout AVChannelLayout)throws->FrameShape{
        let ch=layout.nb_channels
        guard rate>0,ch>0,ch<=8,av_get_bytes_per_sample(AVSampleFormat(rawValue:fmt))>0 else{throw LabError.invalid("shape")}
        let ids=(0..<Int(ch)).map{String(av_channel_layout_channel_from_index(&layout,UInt32($0)).rawValue)}
        return FrameShape(rate:rate,fmt:fmt,ch:ch,ids:ids)
    }
    private func raw(_ url:URL)throws->(Int32,Int32,[Run]){
        let source=try OpenedSource.open(url:url)
        defer{source.close()}
        var owner=source.takeFormatContext()
        defer{avformat_close_input(&owner)}
        let ic=try XCTUnwrap(owner)
        let index=av_find_best_stream(ic,AVMEDIA_TYPE_AUDIO,-1,-1,nil,0)
        guard index>=0,let stream=ic.pointee.streams[Int(index)],let par=stream.pointee.codecpar,
              par.pointee.codec_id==AV_CODEC_ID_AAC,let codec=avcodec_find_decoder(par.pointee.codec_id) else{throw LabError.invalid("stream")}
        let outputRate=par.pointee.sample_rate,outputCh=par.pointee.ch_layout.nb_channels
        var dc=avcodec_alloc_context3(codec)
        defer{avcodec_free_context(&dc)}
        let decoder=try XCTUnwrap(dc)
        guard avcodec_parameters_to_context(decoder,par)>=0,avcodec_open2(decoder,codec,nil)>=0 else{throw LabError.invalid("codec")}
        var packetOwner=av_packet_alloc(),frameOwner=av_frame_alloc()
        defer{av_packet_free(&packetOwner);av_frame_free(&frameOwner)}
        let packet=try XCTUnwrap(packetOwner),frame=try XCTUnwrap(frameOwner)
        var runs=[Run]()
        let eof:Int32 = -541_478_725,again = -Int32(EAGAIN)
        func drain()throws->Int32{
            for _ in 0..<2048{
                let rc=avcodec_receive_frame(decoder,frame)
                if rc==eof || rc==again{return rc}
                guard rc>=0 else{throw LabError.invalid("receive")}
                defer{av_frame_unref(frame)}
                let s=try shape(rate:frame.pointee.sample_rate,fmt:frame.pointee.format,layout:&frame.pointee.ch_layout)
                let n=Int(frame.pointee.nb_samples)
                guard s.rate==48000,s.fmt==AV_SAMPLE_FMT_FLTP.rawValue,n>0,n<=8192 else{throw LabError.invalid("unexpected fixture shape")}
                if runs.last?.shape != s{runs.append(Run(shape:s))}
                runs[runs.count-1].samples+=n
                runs[runs.count-1].frames+=1
            }
            throw LabError.invalid("drain bound")
        }
        for _ in 0..<2048{
            let rc=av_read_frame(ic,packet)
            if rc==eof{
                let sent=avcodec_send_packet(decoder,nil)
                guard sent>=0 || sent==eof,try drain()==eof,!runs.isEmpty else{throw LabError.invalid("EOF")}
                return (outputRate,outputCh,runs)
            }
            guard rc>=0 else{throw LabError.invalid("read")}
            defer{av_packet_unref(packet)}
            if packet.pointee.stream_index != index{continue}
            guard avcodec_send_packet(decoder,packet)>=0 else{throw LabError.invalid("send")}
            _=try drain()
        }
        throw LabError.invalid("packet bound")
    }
    private func bridge(_ url:URL,rate:Int32,ch:Int32)throws->(Int,String,Int){
        // This method is ONLY called when the runner has inserted the guard.
        guard ProcessInfo.processInfo.environment["APOLO_G0_SHAPE_GUARD"]=="1" else{throw LabError.invalid("guard not enabled")}
        let d=AudioDecoder();d.limiterEnabled=false
        defer{d.close()}
        try d.open(url:url,httpHeaders:[:])
        var pcm=[Float](),jumps=0,prior:Int64?
        for _ in 0..<2048{
            guard let b=try d.readNextBuffer() else{
                XCTAssertNil(try d.readNextBuffer());XCTAssertFalse(pcm.isEmpty)
                let bits=pcm.map{$0.bitPattern.littleEndian}
                let hash=bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
                return (pcm.count/Int(ch),hash,jumps)
            }
            let n=CMSampleBufferGetNumSamples(b),count=n*Int(ch)
            guard n>0,pcm.count+count<=2_000_000,let desc=CMSampleBufferGetFormatDescription(b),
                  let a=CMAudioFormatDescriptionGetStreamBasicDescription(desc),let block=CMSampleBufferGetDataBuffer(b),
                  a.pointee.mSampleRate==Double(rate),a.pointee.mChannelsPerFrame==UInt32(ch),
                  a.pointee.mBytesPerFrame==UInt32(ch*4),(a.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  CMBlockBufferGetDataLength(block)==count*4 else{throw LabError.invalid("bridge shape")}
            let t=CMSampleBufferGetPresentationTimeStamp(b).seconds
            guard t.isFinite,abs(t)<3600 else{throw LabError.invalid("PTS")}
            let tick=Int64((t*Double(rate)).rounded())
            if let prior,prior != tick{jumps+=1}
            prior=tick+Int64(n)
            var chunk=[Float](repeating:0,count:count)
            let rc=chunk.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
            guard rc==0,chunk.allSatisfy({$0.isFinite}) else{throw LabError.invalid("bridge PCM")}
            pcm.append(contentsOf:chunk)
        }
        throw LabError.invalid("bridge bound")
    }
    private func run(_ name:String,channels:[Int32])throws{
        let b64=try XCTUnwrap(ProcessInfo.processInfo.environment["APOLO_G0_DYNAMIC_FIXTURE"])
        let data=try XCTUnwrap(Data(base64Encoded:b64))
        guard data.count>0,data.count<=128_000 else{throw LabError.invalid("fixture")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".aac")
        try data.write(to:url);defer{try? FileManager.default.removeItem(at:url)}
        print("G0_4B82_PROCESS pid=\(getpid()) scenario=\(name)")
        let (rate,ch,runs)=try raw(url)
        let first=try XCTUnwrap(runs.first?.shape)
        XCTAssertEqual(runs.map{$0.shape.ch},channels)
        guard runs.map({$0.shape.ch})==channels,rate==first.rate,ch==first.ch else{throw LabError.invalid("fixture must realize requested transition")}
        let accepted=runs.filter{$0.shape==first},blocked=runs.filter{$0.shape != first}
        let expected=accepted.reduce(0){$0+$1.samples}
        let out=try bridge(url,rate:rate,ch:ch)
        XCTAssertEqual(out.0,expected)
        print("G0_4B82_CONTROL scenario=\(name) runs=\(runs.map{"\($0.shape.key)/\($0.samples)/\($0.frames)"}.joined(separator:";")) acceptedFrames=\(accepted.reduce(0){$0+$1.frames}) blockedFrames=\(blocked.reduce(0){$0+$1.frames}) acceptedSamples=\(expected) blockedSamples=\(blocked.reduce(0){$0+$1.samples}) bridgeSamples=\(out.0) bridgeHash=\(out.1) jumps=\(out.2)")
        print("G0_4B82_SUMMARY controls=1")
    }
    func testConstant()throws{try run("Constant",channels:[2])}
    func testStereoMono()throws{try run("StereoMono",channels:[2,1,2])}
    func testMonoStereo()throws{try run("MonoStereo",channels:[1,2,1])}
    func testStereoSix()throws{try run("StereoSix",channels:[2,6,2])}
    // Synthetic descriptors only: demonstrate same-count semantic and
    // packed/planar/numeric differences without passing them to stale SWR.
    func testDescriptors()throws{
        print("G0_4B82_PROCESS pid=\(getpid()) scenario=Descriptors")
        var back=AVChannelLayout(),side=AVChannelLayout(),stereo=AVChannelLayout()
        defer{av_channel_layout_uninit(&back);av_channel_layout_uninit(&side);av_channel_layout_uninit(&stereo)}
        guard av_channel_layout_from_mask(&back,0x3f)>=0,av_channel_layout_from_mask(&side,0x60f)>=0 else{throw LabError.invalid("layout")}
        av_channel_layout_default(&stereo,2)
        let a=try shape(rate:48000,fmt:AV_SAMPLE_FMT_FLTP.rawValue,layout:&back)
        let b=try shape(rate:48000,fmt:AV_SAMPLE_FMT_FLTP.rawValue,layout:&side)
        let c=try shape(rate:48000,fmt:AV_SAMPLE_FMT_FLTP.rawValue,layout:&stereo)
        let d=try shape(rate:48000,fmt:AV_SAMPLE_FMT_FLT.rawValue,layout:&stereo)
        let e=try shape(rate:48000,fmt:AV_SAMPLE_FMT_S16P.rawValue,layout:&stereo)
        let f=try shape(rate:48000,fmt:AV_SAMPLE_FMT_S32P.rawValue,layout:&stereo)
        XCTAssertEqual(a.ch,b.ch);XCTAssertNotEqual(a,b)
        XCTAssertEqual(Set([c.key,d.key,e.key,f.key]).count,4)
        print("G0_4B82_CONTROL scenario=Descriptors layoutBack=\(a.key) layoutSide=\(b.key) planarFloat=\(c.key) packedFloat=\(d.key) planarS16=\(e.key) planarS32=\(f.key)")
        print("G0_4B82_SUMMARY controls=1")
    }
}
