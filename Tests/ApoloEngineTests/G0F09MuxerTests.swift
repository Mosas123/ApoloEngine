import Foundation
import XCTest
import CryptoKit
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

final class G0F09MuxerTests: XCTestCase {
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
        print("G0_F09H_HEADER profile=\(spec.name) inTB=\(inTB.num)/\(inTB.den) outTB=\(outTB.num)/\(outTB.den) nofile=\((of.pointee.flags & 1) != 0)")
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
            print("G0_F09H_PACKET profile=\(spec.name) index=\(records.count) pts=\(v.pts) dts=\(v.dts) duration=\(v.duration) size=\(rec.size) sha=\(rec.sha256)")
        }
        XCTAssertTrue(eof)
        XCTAssertFalse(records.isEmpty)
        let repeatEOF=av_read_frame(c,p)
        if repeatEOF >= 0 { av_packet_unref(p) }
        XCTAssertEqual(repeatEOF,-541478725)
        XCTAssertEqual(backwards,0)
        let tb=st.pointee.time_base
        print("G0_F09H_REOPEN profile=\(spec.name) format=\(fmt) codec=\(codec) tb=\(tb.num)/\(tb.den) streamDuration=\(st.pointee.duration) packets=\(records.count) hostPackets=\(spec.packets.count) hostExact=\(records == spec.packets) missingPTS=\(missingPTS) missingDTS=\(missingDTS) backwards=\(backwards) repeat=\(repeatEOF)")
        return records
    }
    func testMuxerRoundTrips() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures/G0F09H")).deletingLastPathComponent()
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.profiles.count,7)
        for (name,digest) in manifest.files.sorted(by:{$0.key<$1.key}) {
            XCTAssertEqual(URL(fileURLWithPath:name).lastPathComponent,name)
            XCTAssertEqual(hash(try Data(contentsOf:root.appendingPathComponent(name))),digest)
        }
        let work=FileManager.default.temporaryDirectory.appendingPathComponent("G0F09H-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:work) }
        var successes=0,hostExact=0
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
                    print("G0_F09H_FILE profile=\(spec.name) name=\(f) bytes=\(data.count) sha=\(hash(data))")
                }
                if spec.muxer == "hls" {
                    let playlist=try String(contentsOf:out,encoding:.utf8)
                    XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
                    let segments=playlist.split(separator:"\n").filter{!$0.hasPrefix("#") && !$0.isEmpty}
                    XCTAssertGreaterThan(segments.count,1)
                    for s in segments { XCTAssertTrue(files.contains(String(s))) }
                }
                let host=outputPackets == spec.packets
                if host { hostExact+=1 }
                successes+=1
                print("G0_F09H_CASE profile=\(spec.name) inputPackets=\(inputPackets.count) outputPackets=\(outputPackets.count) hostExact=\(host) inputExact=\(inputPackets == outputPackets) files=\(files.count) bytes=\(totalBytes)")
            } catch {
                XCTFail("profile \(spec.name): \(error)")
                print("G0_F09H_ERROR profile=\(spec.name) error=\(error)")
            }
        }
        XCTAssertEqual(successes,7)
        print("G0_F09H_SUMMARY profiles=\(successes) hostExact=\(hostExact) decoded=0")
    }
}
