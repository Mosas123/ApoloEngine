import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Darwin
import Foundation
import XCTest

final class G0F07ExternalTests: XCTestCase {
    private enum LabError:Error{case fixture,codec,frame,drain}
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ bytes:[UInt8])->String{
        var h:UInt64=14695981039346656037
        for b in bytes{h=(h ^ UInt64(b)) &* 1099511628211}
        return String(h,radix:16)
    }
    private func fixture(_ depth:Int)throws->([UInt8],[[UInt8]]){
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let bytes=[UInt8](try Data(contentsOf:root.appendingPathComponent("g0-f07c-\(depth).ivf")))
        let reference=[UInt8](try Data(contentsOf:root.appendingPathComponent("g0-f07c-\(depth).yuv")))
        guard bytes.count>=32,Array(bytes.prefix(4))==Array("DKIF".utf8),Array(bytes[8..<12])==Array("AV01".utf8) else{throw LabError.fixture}
        var cursor=32,packets:[[UInt8]]=[]
        while cursor<bytes.count{
            guard cursor+12<=bytes.count else{throw LabError.fixture}
            var n=0
            for i in 0..<4{n |= Int(bytes[cursor+i]) << (8*i)}
            cursor+=12
            guard n>0,n<=1048576,cursor+n<=bytes.count else{throw LabError.fixture}
            packets.append(Array(bytes[cursor..<cursor+n]));cursor+=n
        }
        guard packets.count==4,reference.count==32*24*3/2*4*(depth==10 ? 2:1) else{throw LabError.fixture}
        return(reference,packets)
    }
    private func decode(_ name:String,_ depth:Int,_ packets:[[UInt8]])throws->([UInt8],[Int64]){
        guard let codec=avcodec_find_decoder_by_name(name) else{throw LabError.codec}
        var owner=avcodec_alloc_context3(codec),packet=av_packet_alloc(),frame=av_frame_alloc()
        defer{avcodec_free_context(&owner);av_packet_free(&packet);av_frame_free(&frame)}
        guard let ctx=owner,let p=packet,let f=frame else{throw LabError.codec}
        ctx.pointee.thread_count=1
        ctx.pointee.pkt_timebase=AVRational(num:1,den:25)
        guard avcodec_open2(ctx,codec,nil)>=0 else{throw LabError.codec}
        var bytes:[UInt8]=[],pts:[Int64]=[]
        let eof:Int32 = -541478725,again = -Int32(EAGAIN)
        func drain()throws->Int32{
            for _ in 0..<16{
                let rc=avcodec_receive_frame(ctx,f)
                if rc==eof || rc==again{return rc}
                guard rc>=0 else{throw LabError.drain}
                defer{av_frame_unref(f)}
                let fmt=depth==10 ? AV_PIX_FMT_YUV420P10LE:AV_PIX_FMT_YUV420P
                guard f.pointee.width==32,f.pointee.height==24,f.pointee.format==fmt.rawValue,pts.count<4 else{throw LabError.frame}
                pts.append(f.pointee.pts)
                let planes=[f.pointee.data.0,f.pointee.data.1,f.pointee.data.2]
                let strides=[f.pointee.linesize.0,f.pointee.linesize.1,f.pointee.linesize.2]
                for plane in 0..<3{
                    let w=(plane==0 ? 32:16)*(depth==10 ? 2:1),h=plane==0 ? 24:12
                    guard let base=planes[plane],strides[plane]>=Int32(w) else{throw LabError.frame}
                    for y in 0..<h{bytes.append(contentsOf:UnsafeBufferPointer(start:base.advanced(by:y*Int(strides[plane])),count:w))}
                }
            }
            throw LabError.drain
        }
        for (i,data) in packets.enumerated(){
            guard av_new_packet(p,Int32(data.count))>=0,let dest=p.pointee.data else{throw LabError.fixture}
            data.withUnsafeBufferPointer{dest.update(from:$0.baseAddress!,count:data.count)}
            p.pointee.pts=Int64(i);p.pointee.dts=Int64(i);p.pointee.duration=1
            let rc=avcodec_send_packet(ctx,p)
            av_packet_unref(p)
            guard rc>=0 else{throw LabError.codec}
            _=try drain()
        }
        guard avcodec_send_packet(ctx,nil)>=0,try drain()==eof,try drain()==eof,pts.count==4 else{throw LabError.drain}
        return(bytes,pts)
    }
    func testG0F07CExternalInventory()throws{
        var opaque:UnsafeMutableRawPointer?
        var codecs:[String]=[],demuxers:[String]=[],muxers:[String]=[]
        while let c=av_codec_iterate(&opaque){
            let name=String(cString:c.pointee.name)
            codecs.append("\(name):\(c.pointee.type.rawValue):\(av_codec_is_decoder(c)):\(av_codec_is_encoder(c))")
        }
        opaque=nil
        while let f=av_demuxer_iterate(&opaque){demuxers.append(String(cString:f.pointee.name))}
        opaque=nil
        while let f=av_muxer_iterate(&opaque){muxers.append(String(cString:f.pointee.name))}
        for c in codecs.sorted(){print("G0_F07C_CODEC entry=\(c)")}
        for f in demuxers.sorted(){print("G0_F07C_DEMUX name=\(f)")}
        for f in muxers.sorted(){print("G0_F07C_MUX name=\(f)")}
        var decoded=0,exact=0,compared=0
        for depth in [8,10]{
            let (ref,packets)=try fixture(depth)
            // Native AV1 is inventoried separately: it may require hardware.
            // Only libdav1d is the software decoder under this test.
            let (actual,pts)=try decode("libdav1d",depth,packets)
            let match=actual==ref
            decoded+=1;if match{exact+=1}
            compared+=min(actual.count,ref.count)
            print("G0_F07C_AV1 depth=\(depth) bytes=\(actual.count) reference=\(ref.count) exact=\(match) pts=\(pts.map(String.init).joined(separator:",")) hash=\(hash(actual)) referenceHash=\(hash(ref))")
            XCTAssertEqual(actual.count,ref.count)
            XCTAssertEqual(pts,[0,1,2,3])
        }
        // Subtitle API has a different contract. Check registration/open/close,
        // not successful page decoding without a verified teletext fixture.
        var teletextOpen=0
        for i in 0..<4{
            let codec=try XCTUnwrap(avcodec_find_decoder_by_name("libzvbi_teletext"))
            var ctx=avcodec_alloc_context3(codec)
            defer{avcodec_free_context(&ctx)}
            let rc=avcodec_open2(try XCTUnwrap(ctx),codec,nil)
            if rc>=0{teletextOpen+=1}
            avcodec_free_context(&ctx)
            print("G0_F07C_ZVBI iteration=\(i) openCode=\(rc) freed=\(ctx==nil)")
            XCTAssertEqual(rc,0);XCTAssertNil(ctx)
        }
        print("G0_F07C_SUMMARY codecs=\(codecs.count) demuxers=\(demuxers.count) muxers=\(muxers.count) decoded=\(decoded) exact=\(exact) comparedBytes=\(compared) teletextOpen=\(teletextOpen)")
        XCTAssertEqual(decoded,2);XCTAssertEqual(teletextOpen,4)
    }
}
