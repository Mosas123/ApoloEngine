import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import CryptoKit
import Foundation
import XCTest

final class G0F09AVISeekTests:XCTestCase {
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private struct Manifest:Decodable{
        let original_sha256:String
        let control_sha256:String
    }
    private struct Packet {
        let pts:Int64
        let dts:Int64
        let duration:Int64
        let pos:Int64
        let size:Int
        let hash:String
    }
    private enum LabError:Error{case invalidSource,read,bound}
    private func hash(_ data:Data)->String{
        SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    private func withSource<T>(_ url:URL,_ body:(UnsafeMutablePointer<AVFormatContext>,UnsafeMutablePointer<AVPacket>)throws->T)throws->T{
        var owned:UnsafeMutablePointer<AVFormatContext>?
        defer{avformat_close_input(&owned)}
        let rc=url.path.withCString{avformat_open_input(&owned,$0,nil,nil)}
        guard rc>=0,let c=owned,avformat_find_stream_info(c,nil)>=0,c.pointee.nb_streams==1,
              let s=c.pointee.streams[0],s.pointee.time_base.num==1,s.pointee.time_base.den==48000 else{throw LabError.invalidSource}
        var packet=av_packet_alloc()
        defer{av_packet_free(&packet)}
        return try body(c,XCTUnwrap(packet))
    }
    private func next(_ c:UnsafeMutablePointer<AVFormatContext>,_ p:UnsafeMutablePointer<AVPacket>)throws->Packet?{
        let rc=av_read_frame(c,p)
        if rc == -541478725{return nil}
        guard rc>=0 else{throw LabError.read}
        defer{av_packet_unref(p)}
        let v=p.pointee
        guard v.stream_index==0,v.size>0,v.size<=1048576,let data=v.data else{throw LabError.bound}
        return Packet(pts:v.pts,dts:v.dts,duration:v.duration,pos:v.pos,size:Int(v.size),hash:hash(Data(bytes:data,count:Int(v.size))))
    }
    func testG0F09D1AVISeek()throws{
        let root=try XCTUnwrap(Bundle.module.url(forResource:"avi-control",withExtension:"json",subdirectory:"Fixtures/G0F09B")).deletingLastPathComponent()
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("avi-control.json")))
        var attempts=0,accepted=0,rejected=0,empty=0,uniqueMatch=0,ptsMismatch=0
        var originalReference:[Packet]=[]
        for (name,expectedHash) in [("avi",manifest.original_sha256),("avi-unique",manifest.control_sha256)]{
            let url=root.appendingPathComponent(name+".avi")
            let bytes=try Data(contentsOf:url)
            XCTAssertEqual(hash(bytes),expectedHash)
            let reference=try withSource(url){c,p in
                var a:[Packet]=[],eof=false
                for _ in 0..<2048{
                    guard let v=try next(c,p) else{eof=true;break}
                    a.append(v)
                }
                XCTAssertTrue(eof)
                XCTAssertEqual(a.reduce(0){$0+$1.size},192000)
                return a
            }
            if name=="avi"{originalReference=reference}else{
                XCTAssertEqual(reference.count,originalReference.count)
                XCTAssertEqual(Set(reference.map{$0.hash}).count,reference.count)
                for (a,b) in zip(originalReference,reference){
                    XCTAssertEqual(a.pts,b.pts);XCTAssertEqual(a.dts,b.dts)
                    XCTAssertEqual(a.duration,b.duration);XCTAssertEqual(a.pos,b.pos);XCTAssertEqual(a.size,b.size)
                }
            }
            for (i,v) in reference.enumerated(){
                var fileMatch=false
                if v.pos>=0,v.pos<=Int64(bytes.count-v.size){
                    let offset=Int(v.pos)
                    fileMatch=hash(bytes.subdata(in:offset..<(offset+v.size)))==v.hash
                }
                print("G0_F09D1_REF fixture=\(name) index=\(i) pts=\(v.pts) dts=\(v.dts) duration=\(v.duration) pos=\(v.pos) size=\(v.size) hash=\(v.hash) fileAtPos=\(fileMatch)")
            }
            for ms in [0,250,750,960,980,990,999,1000,1010]{
                for backward in [false,true]{
                    for warm in [false,true]{
                        try withSource(url){c,p in
                            // Warm control reads seven packets before the same seek.
                            if warm{for _ in 0..<7{_ = try next(c,p)}}
                            let wanted=Int64(ms)*48
                            let rc=av_seek_frame(c,0,wanted,backward ? AVSEEK_FLAG_BACKWARD:0)
                            attempts+=1
                            if rc<0{
                                rejected+=1
                                print("G0_F09D1_SEEK fixture=\(name) ms=\(ms) backward=\(backward) warm=\(warm) rc=\(rc)")
                                return
                            }
                            accepted+=1
                            var count=0
                            for _ in 0..<4{
                                guard let v=try next(c,p) else{break}
                                count+=1
                                let hashMatches=reference.indices.filter{reference[$0].size==v.size && reference[$0].hash==v.hash}
                                let posMatches=hashMatches.filter{reference[$0].pos==v.pos}
                                let match=posMatches.count==1 ? posMatches.first : (hashMatches.count==1 ? hashMatches.first:nil)
                                let refPTS=match.map{reference[$0].pts}
                                let residual=refPTS.map{v.pts==$0 ? Int64(0):v.pts-$0}
                                if match != nil{uniqueMatch+=1}
                                if let residual,residual != 0{ptsMismatch+=1}
                                let refText=refPTS.map(String.init) ?? "none"
                                let delta=residual.map(String.init) ?? "none"
                                print("G0_F09D1_PACKET fixture=\(name) ms=\(ms) backward=\(backward) warm=\(warm) index=\(count) pts=\(v.pts) dts=\(v.dts) duration=\(v.duration) pos=\(v.pos) size=\(v.size) hash=\(v.hash) hashMatches=\(hashMatches.count) posMatches=\(posMatches.count) refIndex=\(match.map(String.init) ?? "none") refPTS=\(refText) ptsVsRef=\(delta)")
                            }
                            if count==0{empty+=1}
                            print("G0_F09D1_SEEK fixture=\(name) ms=\(ms) backward=\(backward) warm=\(warm) rc=\(rc) packets=\(count)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(attempts,72);XCTAssertEqual(accepted+rejected,attempts)
        print("G0_F09D1_SUMMARY attempts=\(attempts) accepted=\(accepted) rejected=\(rejected) empty=\(empty) uniquelyMatchedPackets=\(uniqueMatch) ptsMismatchPackets=\(ptsMismatch) decoded=0")
    }
}
