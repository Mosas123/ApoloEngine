import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AudioToolbox
import CoreMedia
import Darwin
import Foundation
import XCTest
@testable import ApoloEngine

final class G0F08AudioTests:XCTestCase{
    private enum MatrixError:Error{case invalidFixture,missingStream,missingPacket}
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ a:[Float])->String{
        var h:UInt64=14695981039346656037
        for v in a{h=(h ^ UInt64(v.bitPattern)) &* 1099511628211}
        return String(h,radix:16)
    }
    private func metric(_ a:[Float],_ b:[Float])->(Int,Double,Double){
        guard a.count==b.count,!a.isEmpty else{return(-1,.infinity,.infinity)}
        var diff=0,maxError=0.0,sum=0.0
        for (x,y) in zip(a,b){
            if x.bitPattern != y.bitPattern{diff+=1}
            let d=abs(Double(x)-Double(y));maxError=max(maxError,d);sum+=d*d
        }
        return(diff,maxError,sqrt(sum/Double(a.count)))
    }
    private func raw(url: URL, codecName: String, rate: Int32,
                         channels: Int, maxFrames: Int, traceMode: String? = nil,
                         setPacketTimeBase: Bool = false) throws
        -> (values: [Float], first: Int64?, end: Int64?, missingPTS: Int,
            discontinuities: Int, packets: Int, decodedFrames: Int,
            maxCursorError: Int64, maxStepError: Int64, timeBaseNum: Int32, timeBaseDen: Int32) {
        func trace(_ message: @autoclosure () -> String) {
            if let traceMode {
                print("G0_F08A_TRACE fixture=\(url.lastPathComponent) mode=\(traceMode) \(message())")
            }
        }
        let source = try OpenedSource.open(url: url)
        defer { source.close() }
        guard source.info.audioTracks.first?.codec == codecName else { throw MatrixError.invalidFixture }
        var owned = source.takeFormatContext()
        defer { avformat_close_input(&owned) }
        guard let context = owned, context.pointee.nb_streams == 1,
              let stream = context.pointee.streams[0], let params = stream.pointee.codecpar,
              params.pointee.sample_rate == rate, Int(params.pointee.ch_layout.nb_channels) == channels,
              stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0,
              let codec = avcodec_find_decoder(params.pointee.codec_id),
              let decoder = avcodec_alloc_context3(codec)
        else { throw MatrixError.missingStream }
        var ownedCodec: UnsafeMutablePointer<AVCodecContext>? = decoder
        defer { avcodec_free_context(&ownedCodec) }
        guard avcodec_parameters_to_context(decoder, params) >= 0 else { throw MatrixError.invalidFixture }
        // Diagnostic control only; default matches existing AudioDecoder.
        if setPacketTimeBase { decoder.pointee.pkt_timebase = stream.pointee.time_base }
        guard avcodec_open2(decoder, codec, nil) >= 0 else { throw MatrixError.invalidFixture }
        trace("stage=open streamStart=\(stream.pointee.start_time) streamDuration=\(stream.pointee.duration) streamTB=\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den) packetTB=\(decoder.pointee.pkt_timebase.num)/\(decoder.pointee.pkt_timebase.den) initialPadding=\(params.pointee.initial_padding) trailingPadding=\(params.pointee.trailing_padding) codecInitialPadding=\(decoder.pointee.initial_padding)")
        var ownedPacket = av_packet_alloc()
        var ownedFrame = av_frame_alloc()
        defer { av_frame_free(&ownedFrame); av_packet_free(&ownedPacket) }
        guard let packet = ownedPacket, let frame = ownedFrame else { throw MatrixError.missingPacket }
        let eof: Int32 = -541_478_725
        let again = -Int32(EAGAIN)
        var output: [Float] = []
        var first: Int64?
        var end: Int64?
        var missingPTS = 0
        var discontinuities = 0
        var packets = 0
        var frames = 0
        var maxCursorError: Int64 = 0
        var maxStepError: Int64 = 0
        func drain() throws -> Int32 {
            for _ in 0..<2048 {
                let rc = avcodec_receive_frame(decoder, frame)
                if rc == eof || rc == again { return rc }
                guard rc >= 0 else { throw MatrixError.invalidFixture }
                defer { av_frame_unref(frame) }
                let v = frame.pointee
                let fmt = AVSampleFormat(rawValue: v.format)
                let planar = fmt == AV_SAMPLE_FMT_FLTP
                let n = Int(v.nb_samples)
                guard (planar || fmt == AV_SAMPLE_FMT_FLT), v.sample_rate == rate,
                      Int(v.ch_layout.nb_channels) == channels, n > 0,
                      output.count + n * channels <= maxFrames * channels,
                      let planes = v.extended_data else { throw MatrixError.invalidFixture }
                frames += 1
                trace("stage=frame index=\(frames) packet=\(packets) pts=\(v.pts) bestEffort=\(v.best_effort_timestamp) duration=\(v.duration) samples=\(n) cursor=\(output.count / channels) format=\(v.format) rate=\(v.sample_rate) channels=\(v.ch_layout.nb_channels)")
                if v.pts == Int64.min {
                    missingPTS += 1
                    if let old = end { end = old + Int64(n) }
                } else {
                    let tick = av_rescale_q(v.pts, stream.pointee.time_base, AVRational(num: 1, den: rate))
                    let cursor = Int64(output.count / channels)
                    maxCursorError = max(maxCursorError, abs(tick - cursor))
                    if let old = end, old != tick {
                        discontinuities += 1
                        maxStepError = max(maxStepError, abs(tick - old))
                        trace("stage=discontinuity expected=\(old) actual=\(tick) delta=\(tick - old)")
                    }
                    if first == nil { first = tick }
                    end = tick + Int64(n)
                }
                for i in 0..<n {
                    for c in 0..<channels {
                        guard let plane = planes[planar ? c : 0] else { throw MatrixError.invalidFixture }
                        let offset = (planar ? i : i * channels + c) * 4
                        let x = UnsafeRawPointer(plane.advanced(by: offset)).loadUnaligned(as: Float.self)
                        guard x.isFinite else { throw MatrixError.invalidFixture }
                        output.append(x)
                    }
                }
            }
            throw MatrixError.invalidFixture
        }
        for _ in 0..<2048 {
            let rc = av_read_frame(context, packet)
            if rc == eof {
                let sent = avcodec_send_packet(decoder, nil)
                guard sent >= 0 || sent == eof, try drain() == eof else { throw MatrixError.invalidFixture }
                return (output, first, end, missingPTS, discontinuities, packets, frames,
                    maxCursorError, maxStepError, stream.pointee.time_base.num,
                    stream.pointee.time_base.den)
            }
            guard rc >= 0 else { throw MatrixError.invalidFixture }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == 0 else { continue }
            packets += 1
            if traceMode != nil {
                var skip: UInt32 = 0
                var discard: UInt32 = 0
                var sideBytes = 0
                if let side = packet.pointee.side_data {
                    for i in 0..<Int(packet.pointee.side_data_elems) {
                        let item = side[i]
                        if item.type == AV_PKT_DATA_SKIP_SAMPLES {
                            sideBytes = Int(item.size)
                            if let bytes = item.data, sideBytes >= 10 {
                                let base = UnsafeRawPointer(bytes)
                                skip = UInt32(littleEndian: base.loadUnaligned(as: UInt32.self))
                                discard = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                            }
                        }
                    }
                }
                trace("stage=packet index=\(packets) pts=\(packet.pointee.pts) dts=\(packet.pointee.dts) duration=\(packet.pointee.duration) size=\(packet.pointee.size) skipSideBytes=\(sideBytes) skip=\(skip) discard=\(discard)")
            }
            guard avcodec_send_packet(decoder, packet) >= 0 else { throw MatrixError.invalidFixture }
            _ = try drain()
        }
        throw MatrixError.invalidFixture
    }


    func testG0F08ACompressedAudio()throws{
        let profiles=[("wmav1","asf"),("wmav2","asf"),("aac_latm","latm"),("ac3","ac3"),("eac3","eac3")]
        var attempted=0,observed=0,errors=0,bridgeExact=0,hostCountMatch=0,compared=0
        for (codec,ext) in profiles{
            for rate:Int32 in [44100,48000]{
                for ch in [1,2]{
                    let name="\(codec)-\(rate)-\(ch)"
                    attempted+=1
                    do{
                        let url=try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Fixtures/G0F08A"))
                        let ref=try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"f32",subdirectory:"Fixtures/G0F08A"))
                        let data=try Data(contentsOf:ref)
                        guard data.count>0,data.count%(4*ch)==0 else{throw MatrixError.invalidFixture}
                        let host:[Float]=data.withUnsafeBytes{p in
                            (0..<(p.count/4)).map{Float(bitPattern:UInt32(littleEndian:p.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self)))}
                        }
                        let maxFrames=Int(rate)*3
                        guard host.count<=maxFrames*ch,host.allSatisfy({$0.isFinite}) else{throw MatrixError.invalidFixture}
                        let original=try raw(url:url,codecName:codec,rate:rate,channels:ch,maxFrames:maxFrames)
                        let control=try raw(url:url,codecName:codec,rate:rate,channels:ch,maxFrames:maxFrames,setPacketTimeBase:true)
                        let source=try OpenedSource.open(url:url)
                        defer{source.close()}
                        let decoder=AudioDecoder()
                        decoder.limiterEnabled=false
                        defer{decoder.close()}
                        try decoder.adopt(source)
                        var pcm:[Float]=[],first:Int64?,end:Int64?,jumps=0,maxJump:Int64=0,buffers=0,eof=false,asbdOK=true
                        for _ in 0..<2048{
                            guard let b=try decoder.readNextBuffer() else{eof=true;break}
                            let n=CMSampleBufferGetNumSamples(b)
                            guard let desc=CMSampleBufferGetFormatDescription(b),
                                  let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                                  let block=CMSampleBufferGetDataBuffer(b),n>0 else{throw MatrixError.invalidFixture}
                            let shape=asbd.pointee
                            let valid=shape.mSampleRate==Double(rate) && shape.mChannelsPerFrame==UInt32(ch) && shape.mFormatID==kAudioFormatLinearPCM && shape.mBitsPerChannel==32 && shape.mBytesPerFrame==UInt32(ch*4) && (shape.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && (shape.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0
                            asbdOK=asbdOK && valid
                            guard valid,CMBlockBufferGetDataLength(block)==n*ch*4,pcm.count+n*ch<=maxFrames*ch else{throw MatrixError.invalidFixture}
                            let t=CMSampleBufferGetPresentationTimeStamp(b).seconds
                            guard t.isFinite,abs(t)<3600 else{throw MatrixError.invalidFixture}
                            let tick=Int64((t*Double(rate)).rounded())
                            if let end,end != tick{jumps+=1;maxJump=max(maxJump,abs(tick-end))}
                            if first==nil{first=tick}
                            end=tick+Int64(n)
                            var chunk=[Float](repeating:0,count:n*ch)
                            let rc=chunk.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
                            guard rc==0,chunk.allSatisfy({$0.isFinite}) else{throw MatrixError.invalidFixture}
                            pcm.append(contentsOf:chunk);buffers+=1
                        }
                        guard eof,!original.values.isEmpty,!control.values.isEmpty,!pcm.isEmpty else{throw MatrixError.invalidFixture}
                        let rh=metric(original.values,host),bh=metric(pcm,host),br=metric(pcm,original.values),ctrl=metric(control.values,original.values)
                        if br.0==0{bridgeExact+=1}
                        if rh.0>=0{hostCountMatch+=1}
                        compared+=min(original.values.count,pcm.count);observed+=1
                        print("G0_F08A_CASE codec=\(codec) rate=\(rate) ch=\(ch) hostFrames=\(host.count/ch) rawFrames=\(original.values.count/ch) engineFrames=\(pcm.count/ch) rawFirst=\(original.first ?? Int64.min) rawEnd=\(original.end ?? Int64.min) rawMissing=\(original.missingPTS) rawJumps=\(original.discontinuities) rawMaxStep=\(original.maxStepError) controlFirst=\(control.first ?? Int64.min) controlEnd=\(control.end ?? Int64.min) controlMissing=\(control.missingPTS) controlJumps=\(control.discontinuities) controlMaxStep=\(control.maxStepError) controlDifferent=\(ctrl.0) tb=\(original.timeBaseNum)/\(original.timeBaseDen) engineFirst=\(first ?? Int64.min) engineEnd=\(end ?? Int64.min) engineJumps=\(jumps) engineMaxJump=\(maxJump) rawHostDifferent=\(rh.0) rawHostMax=\(rh.1) rawHostRMS=\(rh.2) engineHostMax=\(bh.1) bridgeDifferent=\(br.0) bridgeMax=\(br.1) bridgeRMS=\(br.2) rawHash=\(hash(original.values)) engineHash=\(hash(pcm)) asbdOK=\(asbdOK) buffers=\(buffers) eof=\(eof)")
                    }catch{
                        errors+=1
                        print("G0_F08A_ERROR codec=\(codec) rate=\(rate) ch=\(ch) error=\(error)")
                    }
                }
            }
        }
        print("G0_F08A_SUMMARY attempted=\(attempted) observed=\(observed) errors=\(errors) bridgeExact=\(bridgeExact) hostCountMatch=\(hostCountMatch) comparedValues=\(compared)")
        XCTAssertEqual(attempted,20);XCTAssertEqual(observed,20);XCTAssertEqual(errors,0)
    }
}
