import Foundation
import CoreMedia
import AudioToolbox
import Darwin
@testable import ApoloEngine
import XCTest
import CryptoKit
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

final class G0F09MuxPCMTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private struct Record: Decodable, Equatable {
        let size: Int
        let sha256: String
    }
    private struct Profile: Decodable {
        let name: String
        let input: String
        let muxer: String
        let output: String
        let demuxer: String
        let codec: String
        let options: [String:String]
        let packets: [Record]
    }
    private struct Manifest: Decodable {
        let profiles: [Profile]
        let files: [String:String]
    }
    private enum Failure: Error { case stage(String, Int32), invalid(String) }
    private func check(_ code: Int32, _ stage: String) throws {
        guard code >= 0 else { throw Failure.stage(stage, code) }
    }
    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }
    private func record(_ packet: UnsafeMutablePointer<AVPacket>) throws -> Record {
        let v = packet.pointee
        guard v.size > 0, v.size <= 1_048_576, let data = v.data else {
            throw Failure.invalid("packet size")
        }
        return Record(size:Int(v.size),sha256:hash(Data(bytes:data,count:Int(v.size))))
    }
    private func mux(_ spec: Profile, source: URL, destination: URL) throws -> [Record] {
        var input: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&input) }
        try check(source.path.withCString { avformat_open_input(&input,$0,nil,nil) },"input open")
        let ic = try XCTUnwrap(input)
        try check(avformat_find_stream_info(ic,nil),"input info")
        XCTAssertEqual(ic.pointee.nb_streams,1)
        let st = try XCTUnwrap(ic.pointee.streams[0])
        let par = try XCTUnwrap(st.pointee.codecpar)
        var output: UnsafeMutablePointer<AVFormatContext>?
        defer {
            if let oc = output {
                if oc.pointee.pb != nil, let of = oc.pointee.oformat,
                   (of.pointee.flags & 1) == 0 { _ = avio_closep(&oc.pointee.pb) }
                avformat_free_context(oc)
            }
        }
        let alloc = spec.muxer.withCString { fmt in
            destination.path.withCString { path in avformat_alloc_output_context2(&output,nil,fmt,path) }
        }
        try check(alloc,"output alloc")
        let oc = try XCTUnwrap(output)
        let of = try XCTUnwrap(oc.pointee.oformat)
        XCTAssertEqual(String(cString:of.pointee.name),spec.muxer)
        let ost = try XCTUnwrap(avformat_new_stream(oc,nil))
        let op = try XCTUnwrap(ost.pointee.codecpar)
        try check(avcodec_parameters_copy(op,par),"parameters copy")
        op.pointee.codec_tag = 0
        ost.pointee.time_base = st.pointee.time_base
        // AVFMT_NOFILE = 1; HLS manages its own local outputs.
        if (of.pointee.flags & 1) == 0 {
            try check(destination.path.withCString { avio_open(&oc.pointee.pb,$0,2) },"output io open")
        }
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        for (key,value) in spec.options.sorted(by:{$0.key<$1.key}) {
            try check(av_dict_set(&options,key,value,0),"option")
        }
        try check(avformat_write_header(oc,&options),"write header")
        XCTAssertEqual(av_dict_count(options),0)
        let inTB = st.pointee.time_base
        let outTB = ost.pointee.time_base
        print("G0_F09H1_HEADER profile=\(spec.name) inTB=\(inTB.num)/\(inTB.den) outTB=\(outTB.num)/\(outTB.den) nofile=\((of.pointee.flags & 1) != 0)")
        var owner = av_packet_alloc()
        defer { av_packet_free(&owner) }
        let p = try XCTUnwrap(owner)
        var records = [Record]()
        var eof = false
        for _ in 0..<4096 {
            let rc = av_read_frame(ic,p)
            if rc == -541478725 { eof=true; break }
            try check(rc,"input read")
            defer { av_packet_unref(p) }
            guard p.pointee.stream_index == 0 else { throw Failure.invalid("stream index") }
            records.append(try record(p))
            av_packet_rescale_ts(p,inTB,outTB)
            p.pointee.stream_index = ost.pointee.index
            p.pointee.pos = -1
            try check(av_interleaved_write_frame(oc,p),"write packet")
        }
        XCTAssertTrue(eof)
        XCTAssertFalse(records.isEmpty)
        try check(av_write_trailer(oc),"write trailer")
        if (of.pointee.flags & 1) == 0 { try check(avio_closep(&oc.pointee.pb),"close output") }
        return records
    }
    private func reopen(_ spec: Profile, url: URL) throws -> [Record] {
        var context: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&context) }
        try check(url.path.withCString { avformat_open_input(&context,$0,nil,nil) },"reopen")
        let c = try XCTUnwrap(context)
        try check(avformat_find_stream_info(c,nil),"reopen info")
        let fmt = String(cString:try XCTUnwrap(c.pointee.iformat).pointee.name)
        XCTAssertTrue(fmt.split(separator:",").contains(Substring(spec.demuxer)))
        XCTAssertEqual(c.pointee.nb_streams,1)
        let st = try XCTUnwrap(c.pointee.streams[0])
        let par = try XCTUnwrap(st.pointee.codecpar)
        let codec = String(cString:avcodec_get_name(par.pointee.codec_id))
        XCTAssertEqual(codec,spec.codec)
        if spec.codec == "aac" || spec.codec == "aac_latm" {
            XCTAssertEqual(par.pointee.sample_rate,48000)
            XCTAssertEqual(par.pointee.ch_layout.nb_channels,2)
        }
        var owner = av_packet_alloc()
        defer { av_packet_free(&owner) }
        let p = try XCTUnwrap(owner)
        var records = [Record]()
        var eof = false, missingPTS=0, missingDTS=0, backwards=0
        var prior: Int64?
        for _ in 0..<4096 {
            let rc=av_read_frame(c,p)
            if rc == -541478725 { eof=true; break }
            try check(rc,"output read")
            defer { av_packet_unref(p) }
            XCTAssertEqual(p.pointee.stream_index,0)
            let rec=try record(p)
            records.append(rec)
            let v=p.pointee
            if v.pts == Int64.min { missingPTS += 1 }
            else {
                if let prior, v.pts < prior { backwards += 1 }
                prior=v.pts
            }
            if v.dts == Int64.min { missingDTS += 1 }
            print("G0_F09H1_PACKET profile=\(spec.name) index=\(records.count) pts=\(v.pts) dts=\(v.dts) duration=\(v.duration) size=\(rec.size) sha=\(rec.sha256)")
        }
        XCTAssertTrue(eof)
        XCTAssertFalse(records.isEmpty)
        let repeatEOF=av_read_frame(c,p)
        if repeatEOF >= 0 { av_packet_unref(p) }
        XCTAssertEqual(repeatEOF,-541478725)
        XCTAssertEqual(backwards,0)
        let tb=st.pointee.time_base
        print("G0_F09H1_REOPEN profile=\(spec.name) format=\(fmt) codec=\(codec) tb=\(tb.num)/\(tb.den) streamDuration=\(st.pointee.duration) packets=\(records.count) hostPackets=\(spec.packets.count) hostExact=\(records == spec.packets) missingPTS=\(missingPTS) missingDTS=\(missingDTS) backwards=\(backwards) repeat=\(repeatEOF)")
        return records
    }
    private func raw(url: URL, codecName: String, rate: Int32,
                         channels: Int, maxFrames: Int, traceMode: String? = nil,
                         setPacketTimeBase: Bool = false) throws
        -> (values: [Float], first: Int64?, end: Int64?, missingPTS: Int,
            discontinuities: Int, packets: Int, decodedFrames: Int,
            maxCursorError: Int64, maxStepError: Int64, timeBaseNum: Int32, timeBaseDen: Int32) {
        func trace(_ message: @autoclosure () -> String) {
            if let traceMode {
                print("G0_F09H1_TRACE fixture=\(traceMode) mode=\(traceMode) \(message())")
            }
        }
        let source = try OpenedSource.open(url: url)
        defer { source.close() }
        guard source.info.audioTracks.first?.codec == codecName else { throw MatrixError.invalidFixture }
        var owned = source.takeFormatContext()
        defer { avformat_close_input(&owned) }
        guard let context=owned else{throw MatrixError.missingStream}
        // DVD program streams may also contain navigation packets. Select
        // the sole audio stream rather than requiring a single total stream.
        let indices=(0..<Int(context.pointee.nb_streams)).filter {
            context.pointee.streams[$0]?.pointee.codecpar?.pointee.codec_type == AVMEDIA_TYPE_AUDIO
        }
        guard indices.count==1,let index=indices.first,
              let stream=context.pointee.streams[index],let params=stream.pointee.codecpar,
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
                let planar = [AV_SAMPLE_FMT_U8P, AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_DBLP].contains(fmt)
                let packed = av_get_packed_sample_fmt(fmt)
                let stride = Int(av_get_bytes_per_sample(fmt))
                let n = Int(v.nb_samples)
                guard stride > 0, v.sample_rate == rate,
                      Int(v.ch_layout.nb_channels) == channels, n > 0,
                      output.count + n * channels <= maxFrames * channels,
                      let planes = v.extended_data else { throw MatrixError.invalidFixture }
                frames += 1
                trace("stage=frame index=\(frames) packet=\(packets) pts=\(v.pts) bestEffort=\(v.best_effort_timestamp) duration=\(v.duration) samples=\(n) cursor=\(output.count / channels) format=\(v.format) rate=\(v.sample_rate) channels=\(v.ch_layout.nb_channels)")
                if traceMode != nil {
                    let cursor=Int64(output.count/channels)
                    let ticks=v.pts==Int64.min ? nil:av_rescale_q(v.pts,stream.pointee.time_base,AVRational(num:1,den:rate))
                    let model=ticks ?? cursor
                    let anchored=(first ?? ticks ?? 0)+cursor
                    let residual=end.map{model-$0}
                    trace("stage=coordinate index=\(frames) cursor=\(cursor) ptsTick=\(ticks.map(String.init) ?? "none") modelTick=\(model) anchoredTick=\(anchored) previousRawEnd=\(end.map(String.init) ?? "none") modelVsRawEnd=\(residual.map(String.init) ?? "none")")
                }
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
                        let offset = (planar ? i : i * channels + c) * stride
                        let p = UnsafeRawPointer(plane.advanced(by: offset))
                        let x: Float
                        switch packed {
                        case AV_SAMPLE_FMT_U8: x = Float(Int(p.loadUnaligned(as: UInt8.self)) - 128) / 128
                        case AV_SAMPLE_FMT_S16: x = Float(p.loadUnaligned(as: Int16.self)) / 32768
                        case AV_SAMPLE_FMT_S32: x = Float(Double(p.loadUnaligned(as: Int32.self)) / 2147483648)
                        case AV_SAMPLE_FMT_FLT: x = p.loadUnaligned(as: Float.self)
                        case AV_SAMPLE_FMT_DBL: x = Float(p.loadUnaligned(as: Double.self))
                        default: throw MatrixError.invalidFixture
                        }
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
                trace("stage=flush packets=\(packets) frames=\(frames) cursor=\(output.count/channels)")
                let sent = avcodec_send_packet(decoder, nil)
                guard sent >= 0 || sent == eof, try drain() == eof else { throw MatrixError.invalidFixture }
                return (output, first, end, missingPTS, discontinuities, packets, frames,
                    maxCursorError, maxStepError, stream.pointee.time_base.num,
                    stream.pointee.time_base.den)
            }
            guard rc >= 0 else { throw MatrixError.invalidFixture }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == Int32(index) else { continue }
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



    private enum MatrixError:Error { case invalidFixture,missingStream,missingPacket }
    private func pcmHash(_ values:[Float])->String {
        var h:UInt64=14695981039346656037
        for v in values { h=(h ^ UInt64(v.bitPattern)) &* 1099511628211 }
        return String(h,radix:16)
    }
    private func metric(_ a:[Float],_ b:[Float])->(Int,Double,Double) {
        guard a.count==b.count,!a.isEmpty else{return(-1,.infinity,.infinity)}
        var diff=0,maxError=0.0,sum=0.0
        for (x,y) in zip(a,b) {
            if x.bitPattern != y.bitPattern { diff += 1 }
            let d=abs(Double(x)-Double(y))
            maxError=max(maxError,d);sum+=d*d
        }
        return (diff,maxError,sqrt(sum/Double(a.count)))
    }
    private func readReference(_ url:URL)throws->[Float] {
        let data=try Data(contentsOf:url)
        guard data.count>0,data.count%8==0,data.count<=48000*4*8 else { throw MatrixError.invalidFixture }
        let values:[Float]=data.withUnsafeBytes { p in
            (0..<(p.count/4)).map { Float(bitPattern:UInt32(littleEndian:p.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self))) }
        }
        guard values.allSatisfy({$0.isFinite}) else {throw MatrixError.invalidFixture}
        return values
    }
    private func bridge(_ url:URL,_ name:String)throws->[Float] {
        let source=try OpenedSource.open(url:url)
        defer {source.close()}
        let decoder=AudioDecoder()
        decoder.limiterEnabled=false
        defer {decoder.close()}
        try decoder.adopt(source)
        var pcm=[Float](),priorEnd:Int64?,first:Int64?,jumps=0,buffers=0
        for _ in 0..<2048 {
            guard let b=try decoder.readNextBuffer() else {
                XCTAssertNil(try decoder.readNextBuffer())
                XCTAssertFalse(pcm.isEmpty)
                print("G0_F09H1_BRIDGE profile=\(name) frames=\(pcm.count/2) buffers=\(buffers) first=\(first ?? Int64.min) end=\(priorEnd ?? Int64.min) jumps=\(jumps) hash=\(pcmHash(pcm))")
                return pcm
            }
            let n=CMSampleBufferGetNumSamples(b)
            guard n>0,pcm.count+n*2<=48000*4*2,
                  let desc=CMSampleBufferGetFormatDescription(b),
                  let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let block=CMSampleBufferGetDataBuffer(b) else {throw MatrixError.invalidFixture}
            let a=asbd.pointee
            guard a.mSampleRate==48000,a.mChannelsPerFrame==2,a.mFormatID==kAudioFormatLinearPCM,
                  a.mBitsPerChannel==32,a.mBytesPerFrame==8,(a.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0,
                  CMBlockBufferGetDataLength(block)==n*8 else {throw MatrixError.invalidFixture}
            let time=CMSampleBufferGetPresentationTimeStamp(b).seconds
            let duration=CMSampleBufferGetDuration(b).seconds
            guard time.isFinite,abs(time)<3600,duration.isFinite else {throw MatrixError.invalidFixture}
            let tick=Int64((time*48000).rounded())
            let durationTicks=Int64((duration*48000).rounded())
            XCTAssertEqual(durationTicks,Int64(n))
            if let priorEnd,priorEnd != tick {jumps+=1}
            if first==nil {first=tick}
            priorEnd=tick+Int64(n)
            var chunk=[Float](repeating:0,count:n*2)
            let rc=chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!) }
            guard rc==0,chunk.allSatisfy({$0.isFinite}) else {throw MatrixError.invalidFixture}
            pcm.append(contentsOf:chunk);buffers+=1
            print("G0_F09H1_BUFFER profile=\(name) index=\(buffers) tick=\(tick) samples=\(n) durationTicks=\(durationTicks)")
        }
        throw MatrixError.invalidFixture
    }
    private func compareAligned(_ a:[Float],_ b:[Float],_ name:String,_ route:String) {
        // Prespecified offsets only: zero, or one AAC-LC frame.
        // No unrestricted search or silently discarded samples.
        for offset in [0,1024] {
            let start=offset*2
            guard a.count>=start+b.count else {continue}
            let aligned=Array(a[start..<(start+b.count)])
            let m=metric(aligned,b)
            print("G0_F09H1_ALIGN profile=\(name) route=\(route) offset=\(offset) comparedFrames=\(b.count/2) leading=\(offset) trailing=\((a.count-start-b.count)/2) different=\(m.0) max=\(m.1) rms=\(m.2)")
        }
    }
    private func decodeProfile(_ url:URL,_ name:String,_ codec:String,_ host:[Float],_ sourcePCM:[Float]?)throws->[Float] {
        let decoded=try raw(url:url,codecName:codec,rate:48000,channels:2,maxFrames:48000*4,traceMode:name)
        let output=try bridge(url,name)
        let match=metric(decoded.values,output)
        let hm=metric(decoded.values,host)
        let bm=metric(output,host)
        XCTAssertEqual(match.0,0,"raw vs bridge \(name)")
        print("G0_F09H1_PCM profile=\(name) hostFrames=\(host.count/2) rawFrames=\(decoded.values.count/2) bridgeFrames=\(output.count/2) rawFirst=\(decoded.first ?? Int64.min) rawEnd=\(decoded.end ?? Int64.min) rawMissing=\(decoded.missingPTS) rawJumps=\(decoded.discontinuities) rawHostDifferent=\(hm.0) rawHostMax=\(hm.1) rawHostRMS=\(hm.2) bridgeHostDifferent=\(bm.0) bridgeDifferent=\(match.0) bridgeMax=\(match.1) rawHash=\(pcmHash(decoded.values)) bridgeHash=\(pcmHash(output))")
        if let sourcePCM {
            compareAligned(decoded.values,sourcePCM,name,"raw")
            compareAligned(output,sourcePCM,name,"bridge")
        }
        return output
    }

    func testMuxerRoundTrips() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"manifest-pcm",withExtension:"json",subdirectory:"Fixtures/G0F09H1")).deletingLastPathComponent()
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("manifest-pcm.json")))
        XCTAssertEqual(manifest.profiles.count,8)
        for (name,digest) in manifest.files.sorted(by:{$0.key<$1.key}) {
            XCTAssertEqual(URL(fileURLWithPath:name).lastPathComponent,name)
            XCTAssertEqual(hash(try Data(contentsOf:root.appendingPathComponent(name))),digest)
        }
        let work=FileManager.default.temporaryDirectory.appendingPathComponent("G0F09H1-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:work) }
        let hostSource=try readReference(root.appendingPathComponent("source.f32"))
        let sourcePCM=try decodeProfile(root.appendingPathComponent("source.m4a"),"source","aac",hostSource,nil)
        var successes=0,hostExact=0,decodedProfiles=0
        for spec in manifest.profiles {
            do {
                let dir=work.appendingPathComponent(spec.name,isDirectory:true)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                let out=dir.appendingPathComponent(spec.output)
                let source=root.appendingPathComponent(spec.input)
                let inputPackets=try mux(spec,source:source,destination:out)
                let outputPackets=try reopen(spec,url:out)
                let files=try FileManager.default.contentsOfDirectory(atPath:dir.path).sorted()
                XCTAssertTrue(files.contains(spec.output))
                var totalBytes=0
                for f in files {
                    let data=try Data(contentsOf:dir.appendingPathComponent(f))
                    XCTAssertFalse(data.isEmpty)
                    totalBytes += data.count
                    print("G0_F09H1_FILE profile=\(spec.name) name=\(f) bytes=\(data.count) sha=\(hash(data))")
                }
                if spec.muxer == "hls" {
                    let playlist=try String(contentsOf:out,encoding:.utf8)
                    XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
                    let segments=playlist.split(separator:"\n").filter{!$0.hasPrefix("#") && !$0.isEmpty}
                    XCTAssertGreaterThan(segments.count,1)
                    for s in segments { XCTAssertTrue(files.contains(String(s))) }
                }
                if spec.codec == "aac" || spec.codec == "aac_latm" {
                    let hostPCM=try readReference(root.appendingPathComponent("host").appendingPathComponent(spec.name).appendingPathComponent("decoded.f32"))
                    _ = try decodeProfile(out,spec.name,spec.codec,hostPCM,sourcePCM)
                    decodedProfiles+=1
                }
                let host=outputPackets == spec.packets
                if host { hostExact+=1 }
                successes+=1
                print("G0_F09H1_CASE profile=\(spec.name) inputPackets=\(inputPackets.count) outputPackets=\(outputPackets.count) hostExact=\(host) inputExact=\(inputPackets == outputPackets) files=\(files.count) bytes=\(totalBytes)")
            } catch {
                XCTFail("profile \(spec.name): \(error)")
                print("G0_F09H1_ERROR profile=\(spec.name) error=\(error)")
            }
        }
        XCTAssertEqual(successes,8)
        XCTAssertEqual(decodedProfiles,7)
        print("G0_F09H1_SUMMARY profiles=\(successes) hostExact=\(hostExact) decoded=\(decodedProfiles) sourceDecoded=1")
    }
}
