import CoreMedia
import AudioToolbox
import CryptoKit
import Foundation
import Network
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import XCTest
@testable import ApoloEngine

/// Same position-coded short WAV as #130. Raw and bridge controls.
final class G0ShortSeekCausalityTests:XCTestCase {
    override func setUpWithError()throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_SHORT_SEEK"] == "1")
    }
    private enum Failure:Error {case invalid,unbounded}
    private func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func raw(_ url:URL,_ wave:Data,_ name:String,_ target:Int64,_ flush:Bool)throws {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        var owned=source.takeFormatContext()
        let transport=source.takeTransport()
        defer{avformat_close_input(&owned);transport?.close()}
        let ctx=try XCTUnwrap(owned)
        let idx=av_find_best_stream(ctx,AVMEDIA_TYPE_AUDIO,-1,-1,nil,0)
        guard idx>=0,let stream=ctx.pointee.streams[Int(idx)],let params=stream.pointee.codecpar,
              let codec=avcodec_find_decoder(params.pointee.codec_id),let dec=avcodec_alloc_context3(codec) else{throw Failure.invalid}
        var decoder:UnsafeMutablePointer<AVCodecContext>?=dec
        defer{avcodec_free_context(&decoder)}
        XCTAssertEqual(stream.pointee.time_base.num,1);XCTAssertEqual(stream.pointee.time_base.den,48000)
        guard avcodec_parameters_to_context(dec,params)>=0,avcodec_open2(dec,codec,nil)>=0 else{throw Failure.invalid}
        var ownedPacket=av_packet_alloc(),ownedFrame=av_frame_alloc()
        defer{av_packet_free(&ownedPacket);av_frame_free(&ownedFrame)}
        let p=try XCTUnwrap(ownedPacket),f=try XCTUnwrap(ownedFrame)
        let eof:Int32 = -541478725
        let again = -Int32(EAGAIN)
        var pre=0
        for _ in 0..<16 {
            let rc=av_read_frame(ctx,p)
            if rc==eof{break}
            guard rc>=0,avcodec_send_packet(dec,p)>=0 else{throw Failure.invalid}
            av_packet_unref(p)
            while avcodec_receive_frame(dec,f)>=0{
                pre+=Int(f.pointee.nb_samples);av_frame_unref(f)
            }
        }
        XCTAssertEqual(pre,24000)
        guard avcodec_send_packet(dec,nil)>=0 else{throw Failure.invalid}
        XCTAssertEqual(avcodec_receive_frame(dec,f),eof)
        let rc=avformat_seek_file(ctx,idx,Int64.min,target,Int64.max,AVSEEK_FLAG_BACKWARD)
        XCTAssertEqual(rc,0)
        guard rc>=0 else{throw Failure.invalid}
        if flush {avformat_flush(ctx)}
        avcodec_flush_buffers(dec)
        var packets=0,frames=0,samples=0,eligible=0,mismatch=0,jumps=0
        var firstPTS=Int64.min,lastEnd=Int64.min
        var digest=SHA256()
        func drain()throws->Int32 {
            for _ in 0..<256 {
                let result=avcodec_receive_frame(dec,f)
                if result==again || result==eof{return result}
                guard result>=0 else{throw Failure.invalid}
                defer{av_frame_unref(f)}
                let v=f.pointee,n=Int(v.nb_samples)
                guard n>0,v.format==AV_SAMPLE_FMT_S16.rawValue,v.sample_rate==48000,
                      v.ch_layout.nb_channels==2,let data=v.data.0,
                      samples+n<=24000-Int(target) else{throw Failure.invalid}
                if frames==0{firstPTS=v.pts}
                else if v.pts != lastEnd{jumps+=1}
                lastEnd=v.pts+Int64(n)
                if v.pts>=target{eligible+=n}
                let bytes=Data(bytes:data,count:n*4)
                let offset=44+(Int(target)+samples)*4
                if bytes != wave.subdata(in:offset..<(offset+n*4)){mismatch+=1}
                digest.update(data:bytes)
                frames+=1;samples+=n
                print("G0_4B95_FRAME case=\(name) flush=\(flush) index=\(frames) pts=\(v.pts) bestEffort=\(v.best_effort_timestamp) samples=\(n) cursor=\(samples-n) duration=\(v.duration)")
            }
            throw Failure.unbounded
        }
        var terminal:Int32=0
        for _ in 0..<256 {
            let result=av_read_frame(ctx,p)
            if result<0{terminal=result;break}
            guard p.pointee.stream_index==idx else{throw Failure.invalid}
            packets+=1
            print("G0_4B95_PACKET case=\(name) flush=\(flush) index=\(packets) pts=\(p.pointee.pts) pos=\(p.pointee.pos) duration=\(p.pointee.duration)")
            let sent=avcodec_send_packet(dec,p)
            av_packet_unref(p)
            guard sent>=0,try drain()==again else{throw Failure.invalid}
        }
        XCTAssertEqual(terminal,eof)
        guard avcodec_send_packet(dec,nil)>=0,try drain()==eof else{throw Failure.invalid}
        XCTAssertEqual(samples,24000-Int(target))
        XCTAssertEqual(mismatch,0);XCTAssertEqual(jumps,0)
        XCTAssertEqual(firstPTS,flush ? 0:target)
        XCTAssertEqual(lastEnd,flush ? 24000-target:24000)
        print("G0_4B95_RAW case=\(name) flush=\(flush) packets=\(packets) frames=\(frames) samples=\(samples) firstPTS=\(firstPTS) endPTS=\(lastEnd) eligibleSamples=\(eligible) mismatch=\(mismatch) hash=\(digest.finalize().map{String(format:"%02x",$0)}.joined())")
    }
    private struct PCM {
        let pts:Int64
        let frames:Int
        let bytes:Data
    }
    private func read(_ d:AudioDecoder)throws->PCM? {
        guard let b=try d.readNextBuffer() else{return nil}
        let n=CMSampleBufferGetNumSamples(b)
        let pts=CMSampleBufferGetPresentationTimeStamp(b)
        guard n>0,pts.isNumeric,let desc=CMSampleBufferGetFormatDescription(b),
              let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let block=CMSampleBufferGetDataBuffer(b) else{throw Failure.invalid}
        let a=asbd.pointee
        guard a.mSampleRate==48000,a.mChannelsPerFrame==2,a.mBitsPerChannel==32,a.mBytesPerFrame==8,
              a.mFormatID==kAudioFormatLinearPCM,(a.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0,
              CMBlockBufferGetDataLength(block)==n*8 else{throw Failure.invalid}
        var data=Data(count:n*8)
        let rc=data.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
        guard rc==0 else{throw Failure.invalid}
        return PCM(pts:CMTimeConvertScale(pts,timescale:48000,method:.default).value,frames:n,bytes:data)
    }
    private func mismatch(_ pcm:PCM,_ wave:Data,_ start:Int64,_ skip:Int)->Int {
        guard start>=0,start+Int64(pcm.frames)<=24000,skip<=pcm.frames else{return -1}
        let offset=44+Int(start)*4
        return pcm.bytes.withUnsafeBytes { raw in
            var mismatches=0
            for i in (skip*2)..<(pcm.frames*2) {
                let p=offset+i*2
                let s=Int16(bitPattern:UInt16(wave[p]) | UInt16(wave[p+1])<<8)
                if raw.loadUnaligned(fromByteOffset:i*4,as:Float.self) != Float(s)/32768 {mismatches+=1}
            }
            return mismatches
        }
    }
    private func fixture()->Data{
        let rate=48000,n=24000
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func integer<T:FixedWidthInteger>(_ x:T){var v=x.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");integer(UInt32(36+n*4));ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2))
        integer(UInt32(rate));integer(UInt32(rate*4));integer(UInt16(4));integer(UInt16(16));ascii("data");integer(UInt32(n*4))
        for i in 0..<n{
            integer(Int16(i%16384-8192));integer(Int16(4096+(i/16384)*256))
        }
        return data
    }
    private func bridge(_ url:URL,_ wave:Data,_ overlay:Bool)throws{
        let d=AudioDecoder();d.limiterEnabled=false
        defer{d.close()}
        try d.open(url:url,httpHeaders:[:])
        var pre=0
        for _ in 0..<16{
            guard let p=try read(d) else{break}
            XCTAssertEqual(p.pts,Int64(pre))
            XCTAssertEqual(mismatch(p,wave,p.pts,0),0)
            pre+=p.frames
        }
        XCTAssertEqual(pre,24000);XCTAssertNil(try read(d))
        try d.seek(to:0.1)
        var frames=0,buffers=0,sourceStart:Int64 = -1,sourceEnd:Int64 = -1,firstPTS:Int64 = -1,endPTS:Int64 = -1
        var sourceJumps=0,ptsJumps=0,checked=0,errors=0,eof=false
        for _ in 0..<16{
            guard let p=try read(d) else{eof=true;break}
            let last=p.bytes.withUnsafeBytes{raw->Int64 in
                let l=Int((raw.loadUnaligned(fromByteOffset:(p.frames*2-2)*4,as:Float.self)*32768).rounded())
                let r=Int((raw.loadUnaligned(fromByteOffset:(p.frames*2-1)*4,as:Float.self)*32768).rounded())
                return Int64((r-4096)/256*16384+l+8192)
            }
            let start=last-Int64(p.frames)+1
            let skip=min(p.frames,max(0,144-frames))
            let mm=mismatch(p,wave,start,skip)
            XCTAssertEqual(mm,0)
            errors+=max(0,mm);checked+=(p.frames-skip)*2
            if buffers==0{sourceStart=start;firstPTS=p.pts}
            else{if sourceEnd != start{sourceJumps+=1};if endPTS != p.pts{ptsJumps+=1}}
            sourceEnd=last+1;endPTS=p.pts+Int64(p.frames)
            print("G0_4B95_BUFFER overlay=\(overlay) sourceStart=\(start) pts=\(p.pts) frames=\(p.frames) skip=\(skip) mismatch=\(mm)")
            frames+=p.frames;buffers+=1
        }
        XCTAssertTrue(eof);XCTAssertNil(try read(d))
        XCTAssertEqual(sourceEnd,24000);XCTAssertEqual(sourceJumps,0);XCTAssertEqual(ptsJumps,0)
        if overlay{
            XCTAssertEqual(sourceStart,4800);XCTAssertEqual(firstPTS,4800)
            XCTAssertEqual(frames,19200);XCTAssertEqual(endPTS,24000)
        }else{
            XCTAssertEqual(sourceStart,12992);XCTAssertEqual(firstPTS,8192)
            XCTAssertEqual(frames,11008);XCTAssertEqual(endPTS,19200)
        }
        print("G0_4B95_CONTROL overlay=\(overlay) sourceStart=\(sourceStart) sourceEnd=\(sourceEnd) firstPTS=\(firstPTS) endPTS=\(endPTS) frames=\(frames) buffers=\(buffers) checked=\(checked) mismatch=\(errors) sourceJumps=\(sourceJumps) ptsJumps=\(ptsJumps)")
    }
    func testMatrix()throws{
        let overlay=ProcessInfo.processInfo.environment["APOLO_G0_SEEK_OVERLAY"]=="1"
        let wave=fixture(),url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try wave.write(to:url);defer{try? FileManager.default.removeItem(at:url)}
        print("G0_4B95_PROCESS pid=\(getpid()) overlay=\(overlay) sha=\(sha(wave))")
        for flush in [false,true]{try raw(url,wave,"short",4800,flush)}
        try bridge(url,wave,overlay)
    }
}
