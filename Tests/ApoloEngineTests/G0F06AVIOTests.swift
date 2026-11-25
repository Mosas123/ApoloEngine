import Foundation
import AetherLibavformat
import AetherLibavutil
import XCTest
@testable import ApoloEngine

// URLProtocol isolates all network traffic; no server or credentials.
private final class G0F06FixtureProtocol: URLProtocol, @unchecked Sendable {
    static func wave()->Data {
        var d=Data()
        func tag(_ s:String){d.append(contentsOf:s.utf8)}
        func u16(_ x:UInt16){var v=x.littleEndian;withUnsafeBytes(of:&v){d.append(contentsOf:$0)}}
        func u32(_ x:UInt32){var v=x.littleEndian;withUnsafeBytes(of:&v){d.append(contentsOf:$0)}}
        let frames=16391
        tag("RIFF");u32(UInt32(36+frames*4));tag("WAVE")
        tag("fmt ");u32(16);u16(1);u16(2);u32(48000);u32(192000);u16(4);u16(16)
        tag("data");u32(UInt32(frames*4))
        for i in 0..<(frames*2){u16(UInt16(truncatingIfNeeded:i*37))}
        return d
    }
    override class func canInit(with request:URLRequest)->Bool{request.url?.host=="g0-f06.invalid"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        guard let url=request.url else{return}
        let bad=url.path.contains("bad"),missing=url.path.contains("missing")
        let body=missing ? Data() : bad ? Data(repeating:0,count:4096):Self.wave()
        var headers=["Content-Length":String(body.count),"Content-Type":"audio/wav"]
        let status=missing ? 404 : url.path.contains("range") ? 206:200
        if status==206{headers["Content-Range"]="bytes 0-\(body.count-1)/\(body.count)"}
        guard let response=HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers) else{return}
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if !body.isEmpty{client?.urlProtocol(self,didLoad:body)}
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}

final class G0F06AVIOTests: XCTestCase {
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func configuration()->URLSessionConfiguration{
        let c=URLSessionConfiguration.ephemeral
        c.protocolClasses=[G0F06FixtureProtocol.self]
        return c
    }
    private func value(_ dict:OpaquePointer?,_ key:String)->String?{
        guard let entry=av_dict_get(dict,key,nil,0),let v=entry.pointee.value else{return nil}
        return String(cString:v)
    }
    private func dictionary(_ n:Int)throws->Bool{
        var a:OpaquePointer?,b:OpaquePointer?
        defer{av_dict_free(&a);av_dict_free(&b)}
        let source=String(repeating:"x",count:n)+"é"
        guard av_dict_set(&a,"replaygain_track_gain","-7.23 dB",0)==0,
              av_dict_set(&a,"headers",source,0)==0,
              av_dict_set(&a,"probesize","2000000",0)==0,
              av_dict_copy(&b,a,0)==0 else{return false}
        let initial=av_dict_count(a)==3 && av_dict_count(b)==3
            && value(a,"headers")==source && value(b,"headers")==source
        let replace=av_dict_set(&a,"headers","changed",0)==0
        let remove=av_dict_set(&a,"probesize",nil,0)==0
        let isolated=value(b,"headers")==source && value(b,"probesize")=="2000000"
            && value(a,"headers")=="changed" && value(a,"probesize")==nil
        av_dict_free(&a);av_dict_free(&a)
        let surviving=value(b,"replaygain_track_gain")=="-7.23 dB" && value(b,"headers")==source
        av_dict_free(&b);av_dict_free(&b)
        return initial && replace && remove && isolated && surviving && a==nil && b==nil
    }
    func testG0F06B2DictionaryAndAVIO()throws{
        var attempted=0,observed=0,passed=0,transferOK=0,closeOK=0,failureOK=0,weakReleased=0,weakCount=0
        for n in [0,1,31,257,4096,32768]{
            attempted+=1
            let ok=try dictionary(n)
            observed+=1;if ok{passed+=1}
            print("G0_F06B2_DICT length=\(n) exact=\(ok)")
        }
        // Real HTTPTransport allocates the current AVIO buffer and retains
        // its HTTPStream. Replace the buffer with another av_malloc block
        // under exclusive ownership, modelling the documented AVIO contract.
        // No read occurs during substitution; not a claim FFmpeg replaced it.
        for size in [32768,65536,131072]{
            for iteration in 0..<4{
                attempted+=1
                var stream:HTTPStream?=HTTPStream(url:URL(string:"https://g0-f06.invalid/wav")!,headers:[:],configuration:configuration())
                weak var weakStream=stream
                var transport:HTTPTransport?=HTTPTransport(stream:try XCTUnwrap(stream))
                let ctx=try XCTUnwrap(transport?.context)
                stream=nil
                let retained=weakStream != nil
                let raw=try XCTUnwrap(av_malloc(size))
                let old=ctx.pointee.buffer
                let p=raw.assumingMemoryBound(to:UInt8.self)
                ctx.pointee.buffer=p
                ctx.pointee.buffer_size=Int32(size)
                ctx.pointee.buf_ptr=p
                ctx.pointee.buf_end=p
                if let old{av_free(old)}
                transport?.close();transport?.close()
                let closed=transport?.context==nil
                transport=nil
                let released=weakStream==nil
                weakCount+=1;if released{weakReleased+=1}
                let ok=retained && closed && released
                observed+=1;if ok{passed+=1}
                print("G0_F06B2_TRANSPORT size=\(size) iteration=\(iteration) retained=\(retained) closed=\(closed) weakReleased=\(released) exact=\(ok)")
            }
        }
        // Actual production OpenedSource: local valid/bad/missing and
        // custom HTTP 200/206/404/bad. All inputs synthetic.
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("g0-f06b2-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let local=dir.appendingPathComponent("fixture audio.wav")
        let bad=dir.appendingPathComponent("bad.wav")
        try G0F06FixtureProtocol.wave().write(to:local)
        try Data(repeating:0,count:4096).write(to:bad)
        let inputs:[(String,URL,Bool,Bool)]=[
            ("local",local,true,false),("localBad",bad,false,false),("localMissing",dir.appendingPathComponent("missing.wav"),false,false),
            ("http200",URL(string:"https://g0-f06.invalid/wav")!,true,true),
            ("http206",URL(string:"https://g0-f06.invalid/range")!,true,true),
            ("http404",URL(string:"https://g0-f06.invalid/missing")!,false,true),
            ("httpBad",URL(string:"https://g0-f06.invalid/bad")!,false,true)
        ]
        for (label,url,valid,http) in inputs{
            for mode in 0..<3{
                for iteration in 0..<3{
                    attempted+=1
                    var ok=false,infoOK=false,contextOK=false,transportOK=false
                    do{
                        var source:OpenedSource?=try OpenedSource.open(url:url,httpHeaders:http ? ["X-G0":"fixture"]:[:],sessionConfiguration:configuration())
                        if valid{
                            let info=try XCTUnwrap(source?.info)
                            infoOK=info.audioTracks.count==1 && info.audioTracks.first?.sampleRate==48000 && info.audioTracks.first?.channels==2
                            if mode==0{
                                source?.close();source?.close()
                                contextOK=source?.takeFormatContext()==nil
                                transportOK=source?.takeTransport()==nil
                                ok=infoOK && contextOK && transportOK
                                if ok{closeOK+=1}
                            }else if mode==1{
                                var ctx=source?.takeFormatContext()
                                var transport=source?.takeTransport()
                                source?.close();source=nil
                                contextOK=ctx?.pointee.nb_streams==1
                                transportOK=http ? transport?.context != nil : transport==nil
                                avformat_close_input(&ctx)
                                transport?.close();transport?.close()
                                let closed=ctx==nil && transport?.context==nil
                                transport=nil
                                ok=infoOK && contextOK && transportOK && closed
                                if ok{transferOK+=1}
                            }else{
                                weak var weakSource=source
                                source=nil
                                ok=infoOK && weakSource==nil
                                if ok{closeOK+=1}
                            }
                        }
                        source?.close()
                    }catch{
                        ok = !valid
                        if ok{failureOK+=1}
                    }
                    observed+=1;if ok{passed+=1}
                    print("G0_F06B2_OPEN profile=\(label) mode=\(mode) iteration=\(iteration) expectedValid=\(valid) infoOK=\(infoOK) contextOK=\(contextOK) transportOK=\(transportOK) exact=\(ok)")
                }
            }
        }
        print("G0_F06B2_SUMMARY attempted=\(attempted) observed=\(observed) passed=\(passed) transferOK=\(transferOK) closeOK=\(closeOK) failureOK=\(failureOK) weakReleased=\(weakReleased) weakCount=\(weakCount)")
        XCTAssertEqual(attempted,81)
        XCTAssertEqual(observed,81)
        XCTAssertEqual(passed,81)
    }
}
