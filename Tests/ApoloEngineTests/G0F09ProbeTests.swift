import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import CryptoKit
import Foundation
import XCTest
@testable import ApoloEngine

final class G0F09ProbeTests:XCTestCase{
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private struct PacketRecord:Decodable,Equatable{
        let size:Int
        let sha256:String
    }
    private struct Fixture:Decodable{
        let file:String
        let format:String
        let codec:String
        let sha256:String
        let host_packets:[PacketRecord]
    }
    private struct Manifest:Decodable{let fixtures:[Fixture]}
    private enum LabError:Error{case invalidStream,readFailure,bound,invalidPacket}
    private func hash(_ d:Data)->String{
        SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()
    }
    private func title(_ dict:OpaquePointer?)->String{
        guard let e=av_dict_get(dict,"title",nil,0),let value=e.pointee.value else{return "none"}
        return String(cString:value)
    }
    private func observe(_ url:URL,_ spec:Fixture)throws->[PacketRecord]{
        var context:UnsafeMutablePointer<AVFormatContext>?
        defer{avformat_close_input(&context)}
        let open=url.path.withCString{avformat_open_input(&context,$0,nil,nil)}
        XCTAssertEqual(open,0)
        guard open>=0,let c=context else{throw LabError.invalidStream}
        let info=avformat_find_stream_info(c,nil)
        XCTAssertGreaterThanOrEqual(info,0)
        guard info>=0,let input=c.pointee.iformat,c.pointee.nb_streams==1,
              let stream=c.pointee.streams[0],let par=stream.pointee.codecpar else{throw LabError.invalidStream}
        let name=String(cString:input.pointee.name)
        let codec=String(cString:avcodec_get_name(par.pointee.codec_id))
        XCTAssertEqual(name,spec.format)
        XCTAssertEqual(codec,spec.codec)
        XCTAssertEqual(par.pointee.codec_type,AVMEDIA_TYPE_AUDIO)
        XCTAssertEqual(par.pointee.sample_rate,48000)
        XCTAssertEqual(par.pointee.ch_layout.nb_channels,2)
        XCTAssertGreaterThan(stream.pointee.time_base.num,0)
        XCTAssertGreaterThan(stream.pointee.time_base.den,0)
        let metadata=title(c.pointee.metadata)
        if spec.format=="avi"{XCTAssertEqual(metadata,"Apolo G0 synthetic")}
        print("G0_F09B_OPEN file=\(spec.file) format=\(name) codec=\(codec) rate=\(par.pointee.sample_rate) channels=\(par.pointee.ch_layout.nb_channels) probeScore=\(c.pointee.probe_score) streamTB=\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den) streamStart=\(stream.pointee.start_time) streamDuration=\(stream.pointee.duration) formatDuration=\(c.pointee.duration) title=\(metadata)")
        var packetOwner=av_packet_alloc()
        defer{av_packet_free(&packetOwner)}
        let packet=try XCTUnwrap(packetOwner)
        var records:[PacketRecord]=[],bytes=0,missingPTS=0,missingDTS=0,negativeDuration=0
        var first:Int64?,last:Int64?
        var eof=false
        for _ in 0..<2048{
            let rc=av_read_frame(c,packet)
            if rc == -541478725{eof=true;break}
            guard rc>=0 else{throw LabError.readFailure}
            defer{av_packet_unref(packet)}
            let p=packet.pointee
            guard p.stream_index==0,p.size>0,p.size<=1048576,let ptr=p.data else{throw LabError.invalidPacket}
            bytes+=Int(p.size)
            guard bytes<=8388608 else{throw LabError.bound}
            let h=hash(Data(bytes:ptr,count:Int(p.size)))
            records.append(PacketRecord(size:Int(p.size),sha256:h))
            if p.pts==Int64.min{missingPTS+=1}else{if first==nil{first=p.pts};last=p.pts}
            if p.dts==Int64.min{missingDTS+=1}
            if p.duration<0{negativeDuration+=1}
            print("G0_F09B_PACKET file=\(spec.file) index=\(records.count) size=\(p.size) pts=\(p.pts) dts=\(p.dts) duration=\(p.duration) hash=\(h)")
        }
        XCTAssertTrue(eof);XCTAssertFalse(records.isEmpty)
        let repeatEOF=av_read_frame(c,packet)
        if repeatEOF>=0{av_packet_unref(packet)}
        XCTAssertEqual(repeatEOF,-541478725)
        let hostMatch=records==spec.host_packets
        let hostBytes=spec.host_packets.reduce(0){$0+$1.size}
        // Host FFmpeg is a different distribution: report packetization
        // differences instead of silently forcing equivalence.
        print("G0_F09B_READ file=\(spec.file) packets=\(records.count) bytes=\(bytes) hostPackets=\(spec.host_packets.count) hostBytes=\(hostBytes) hostPacketExact=\(hostMatch) missingPTS=\(missingPTS) missingDTS=\(missingDTS) negativeDuration=\(negativeDuration) firstPTS=\(first.map(String.init) ?? "none") lastPTS=\(last.map(String.init) ?? "none") eof=\(eof) repeatEOF=\(repeatEOF)")
        return records
    }
    func testG0F09BProbeAndPackets()throws{
        let root=try XCTUnwrap(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures/G0F09B")).deletingLastPathComponent()
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.fixtures.count,6)
        var results:[String:[PacketRecord]]=[:],hostExact=0
        for spec in manifest.fixtures{
            let url=root.appendingPathComponent(spec.file)
            XCTAssertEqual(hash(try Data(contentsOf:url)),spec.sha256)
            let packets=try observe(url,spec)
            if packets==spec.host_packets{hostExact+=1}
            results[spec.file]=packets
        }
        var renameExact=0
        for name in ["dts","truehd","avi"]{
            let a=try XCTUnwrap(results[name+"."+name]),b=try XCTUnwrap(results[name+".bin"])
            XCTAssertEqual(a,b)
            if a==b{renameExact+=1}
        }
        print("G0_F09B_SUMMARY fixtures=\(results.count) renameExact=\(renameExact) hostExact=\(hostExact) decoded=0")
        XCTAssertEqual(results.count,6);XCTAssertEqual(renameExact,3)
    }
}
