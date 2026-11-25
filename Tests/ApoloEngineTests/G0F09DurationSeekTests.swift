import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import CryptoKit
import Foundation
import XCTest

final class G0F09DurationSeekTests:XCTestCase {
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private struct Packet:Equatable {
        let pts:Int64
        let dts:Int64
        let duration:Int64
        let size:Int
        let hash:String
    }
    private enum Failure:Error{case open,read,bound}
    private func withSource<T>(_ url:URL,_ body:(UnsafeMutablePointer<AVFormatContext>,UnsafeMutablePointer<AVStream>)throws->T)throws->T{
        var owned:UnsafeMutablePointer<AVFormatContext>?
        defer{avformat_close_input(&owned)}
        let rc=url.path.withCString{avformat_open_input(&owned,$0,nil,nil)}
        guard rc>=0,let c=owned,avformat_find_stream_info(c,nil)>=0,c.pointee.nb_streams==1,
              let stream=c.pointee.streams[0],stream.pointee.time_base.num>0,stream.pointee.time_base.den>0 else{throw Failure.open}
        return try body(c,stream)
    }
    private func next(_ c:UnsafeMutablePointer<AVFormatContext>,_ p:UnsafeMutablePointer<AVPacket>)throws->Packet?{
        let rc=av_read_frame(c,p)
        if rc == -541478725{return nil}
        guard rc>=0 else{throw Failure.read}
        defer{av_packet_unref(p)}
        let v=p.pointee
        guard v.stream_index==0,v.size>0,v.size<=1048576,let data=v.data else{throw Failure.bound}
        let h=SHA256.hash(data:Data(bytes:data,count:Int(v.size))).map{String(format:"%02x",$0)}.joined()
        return Packet(pts:v.pts,dts:v.dts,duration:v.duration,size:Int(v.size),hash:h)
    }
    func testG0F09DDurationSeek()throws{
        let fixtures:[(String,String,String)]=[
            ("dts","dts","b528ff74aec97bcdfdc6179d3377142a90e7631fc0f40604f9aa59b58a5a8610"),
            ("truehd","truehd","88191db41ab0b1e4cc9e85d072337a6738558ff466c5db0026a0d57607eb0426"),
            ("avi","avi","23c559ae77c50679fdbc21bff2b515dfce1a0da8cad1bf47cc4630f281ca2f13")
        ]
        var fullReads=0,attempts=0,accepted=0,rejected=0,exactCoordinate=0,matchedPayload=0
        for (name,ext,sha) in fixtures{
            let url=try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Fixtures/G0F09B"))
            let fileHash=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
            XCTAssertEqual(fileHash,sha)
            let reference=try withSource(url){c,s in
                var owned=av_packet_alloc()
                defer{av_packet_free(&owned)}
                let p=try XCTUnwrap(owned)
                var records:[Packet]=[],eof=false
                for _ in 0..<2048{
                    guard let v=try next(c,p) else{eof=true;break}
                    records.append(v)
                }
                XCTAssertTrue(eof);XCTAssertFalse(records.isEmpty)
                let known=records.filter{$0.pts != Int64.min && $0.duration>0}
                let first=known.map{$0.pts}.min()
                let end=known.map{$0.pts+$0.duration}.max()
                let span=first.flatMap{a in end.map{$0-a}}
                let sum=records.reduce(Int64(0)){$0+max(0,$1.duration)}
                let tb=s.pointee.time_base
                let micros=AVRational(num:1,den:1000000)
                let spanUS=span.map{av_rescale_q($0,tb,micros)}
                let bytes=records.reduce(0){$0+$1.size}
                let gaps=zip(records,records.dropFirst()).filter{pair in pair.0.pts != Int64.min && pair.1.pts != Int64.min && pair.0.duration>0 && pair.0.pts+pair.0.duration != pair.1.pts}.count
                print("G0_F09D_DURATION fixture=\(name) packets=\(records.count) payloadBytes=\(bytes) sourceUS=1000000 formatUS=\(c.pointee.duration) streamTicks=\(s.pointee.duration) tb=\(tb.num)/\(tb.den) sumTicks=\(sum) first=\(first.map(String.init) ?? "none") end=\(end.map(String.init) ?? "none") spanUS=\(spanUS.map(String.init) ?? "none") missingPTS=\(records.filter{$0.pts==Int64.min}.count) zeroDuration=\(records.filter{$0.duration==0}.count) gaps=\(gaps) estimationMethod=unavailable")
                if name=="avi"{XCTAssertEqual(bytes,192000)}
                fullReads+=1
                return records
            }
            // Fresh context per seek: no prior read or previous seek contaminates outcome.
            // Acceptance, packet identity and coordinate residual are distinct observations.
            for ms in [0,250,500,750,990]{
                for backward in [false,true]{
                    try withSource(url){c,s in
                        let target=av_rescale_q(Int64(ms),AVRational(num:1,den:1000),s.pointee.time_base)
                        let origin=s.pointee.start_time==Int64.min ? 0:s.pointee.start_time
                        let wanted=origin+target
                        let rc=av_seek_frame(c,0,wanted,backward ? AVSEEK_FLAG_BACKWARD:0)
                        attempts+=1
                        if rc<0{
                            rejected+=1
                            print("G0_F09D_SEEK fixture=\(name) ms=\(ms) backward=\(backward) wanted=\(wanted) rc=\(rc) observed=none")
                            return
                        }
                        accepted+=1
                        var owned=av_packet_alloc()
                        defer{av_packet_free(&owned)}
                        let p=try XCTUnwrap(owned)
                        // Capture up to four post-seek packets, never decode.
                        var records:[Packet]=[]
                        for _ in 0..<4{guard let v=try next(c,p) else{break};records.append(v)}
                        // Explicit bounded sequence comparison avoids Swift type-check timeout.
                        var matches: [Int] = []
                        if !records.isEmpty && records.count <= reference.count {
                            for i in 0...(reference.count-records.count) {
                                var equal = true
                                for j in records.indices {
                                    let a = reference[i+j]
                                    let b = records[j]
                                    if a.size != b.size || a.hash != b.hash {
                                        equal = false
                                        break
                                    }
                                }
                                if equal { matches.append(i) }
                            }
                        }
                        if !matches.isEmpty{matchedPayload+=1}
                        let first=records.first
                        let exact=first.map{$0.pts==wanted} ?? false
                        if exact{exactCoordinate+=1}
                        let residual=first.flatMap{$0.pts==Int64.min ? nil:$0.pts-wanted}
                        print("G0_F09D_SEEK fixture=\(name) ms=\(ms) backward=\(backward) wanted=\(wanted) rc=\(rc) packets=\(records.count) payloadMatches=\(matches.count) firstIndex=\(matches.first.map(String.init) ?? "none") firstPTS=\(first.map{String($0.pts)} ?? "none") residualTicks=\(residual.map(String.init) ?? "none") exactCoordinate=\(exact)")
                    }
                }
            }
        }
        print("G0_F09D_SUMMARY fullReads=\(fullReads) seeks=\(attempts) accepted=\(accepted) rejected=\(rejected) matchedPayload=\(matchedPayload) exactCoordinate=\(exactCoordinate) decoded=0")
        XCTAssertEqual(fullReads,3);XCTAssertEqual(attempts,30);XCTAssertEqual(accepted+rejected,attempts)
    }
}
