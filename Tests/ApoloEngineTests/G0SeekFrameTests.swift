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

/// Observational seek localization. Preserve the strict failure of #110.
final class G0SeekFrameTests:XCTestCase {
    override func setUpWithError()throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
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
        // Decode one frame before seeking, like the failed #110 profiles.
        guard av_read_frame(ctx,p)>=0,avcodec_send_packet(dec,p)>=0,avcodec_receive_frame(dec,f)>=0 else{throw Failure.invalid}
        XCTAssertEqual(f.pointee.pts,0)
        av_packet_unref(p);av_frame_unref(f)
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
                      samples+n<=192000-Int(target) else{throw Failure.invalid}
                if frames==0{firstPTS=v.pts}
                else if v.pts != lastEnd{jumps+=1}
                lastEnd=v.pts+Int64(n)
                if v.pts>=target{eligible+=n}
                let bytes=Data(bytes:data,count:n*4)
                let offset=78+(Int(target)+samples)*4
                if bytes != wave.subdata(in:offset..<(offset+n*4)){mismatch+=1}
                digest.update(data:bytes)
                frames+=1;samples+=n
                print("G0_4B32_FRAME case=\(name) flush=\(flush) index=\(frames) pts=\(v.pts) bestEffort=\(v.best_effort_timestamp) samples=\(n) cursor=\(samples-n) duration=\(v.duration)")
            }
            throw Failure.unbounded
        }
        var terminal:Int32=0
        for _ in 0..<256 {
            let result=av_read_frame(ctx,p)
            if result<0{terminal=result;break}
            guard p.pointee.stream_index==idx else{throw Failure.invalid}
            packets+=1
            print("G0_4B32_PACKET case=\(name) flush=\(flush) index=\(packets) pts=\(p.pointee.pts) pos=\(p.pointee.pos) duration=\(p.pointee.duration)")
            let sent=avcodec_send_packet(dec,p)
            av_packet_unref(p)
            guard sent>=0,try drain()==again else{throw Failure.invalid}
        }
        XCTAssertEqual(terminal,eof)
        guard avcodec_send_packet(dec,nil)>=0,try drain()==eof else{throw Failure.invalid}
        XCTAssertEqual(samples,192000-Int(target))
        XCTAssertEqual(mismatch,0);XCTAssertEqual(jumps,0)
        XCTAssertEqual(firstPTS,flush ? 0:target)
        XCTAssertEqual(lastEnd,flush ? 192000-target:192000)
        print("G0_4B32_RAW case=\(name) flush=\(flush) packets=\(packets) frames=\(frames) samples=\(samples) firstPTS=\(firstPTS) endPTS=\(lastEnd) eligibleSamples=\(eligible) mismatch=\(mismatch) hash=\(digest.finalize().map{String(format:"%02x",$0)}.joined())")
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
        guard start>=0,start+Int64(pcm.frames)<=192000,skip<=pcm.frames else{return -1}
        let offset=78+Int(start)*4
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
    private func bridge(_ url:URL,_ wave:Data,_ name:String,_ depth:Int,_ target:Int64,_ overlay:Bool)throws {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        let d=AudioDecoder();d.limiterEnabled=false
        defer{d.close()}
        try d.adopt(source)
        var pre=0
        for _ in 0..<(depth == -1 ? 256:depth) {
            guard let p=try read(d) else{break}
            XCTAssertEqual(mismatch(p,wave,p.pts,0),0)
            pre+=1
        }
        XCTAssertEqual(pre,depth == -1 ? 47:depth)
        try d.seek(to:Double(target)/48000)
        var count=0,frames=0,mismatches=0,jumps=0,firstPTS=Int64.min,endPTS=Int64.min
        var digest=SHA256(),eof=false
        for _ in 0..<256 {
            guard let p=try read(d) else{eof=true;break}
            if count==0{firstPTS=p.pts}
            else if p.pts != endPTS{jumps+=1}
            endPTS=p.pts+Int64(p.frames)
            let skip=min(p.frames,max(0,144-frames))
            let mm=mismatch(p,wave,target+Int64(frames),skip)
            if mm<0{mismatches+=p.frames*2}else{mismatches+=mm}
            frames+=p.frames;count+=1;digest.update(data:p.bytes)
        }
        XCTAssertTrue(eof);XCTAssertNil(try read(d))
        // Only the isolated runner overlay has strict target-aligned acceptance.
        if overlay {
            XCTAssertEqual(firstPTS,target);XCTAssertEqual(endPTS,192000)
            XCTAssertEqual(frames,192000-Int(target));XCTAssertEqual(jumps,0);XCTAssertEqual(mismatches,0)
        }
        print("G0_4B32_BRIDGE case=\(name) overlay=\(overlay) target=\(target) depth=\(depth) buffers=\(count) samples=\(frames) firstPTS=\(firstPTS) endPTS=\(endPTS) mismatchTarget=\(mismatches) jumps=\(jumps) eof=\(eof) hash=\(digest.finalize().map{String(format:"%02x",$0)}.joined())")
    }
    private func compressed(_ url:URL,_ name:String,_ target:Int64,_ overlay:Bool)throws {
        // Observational: codec delay and seek granularity require separate gates.
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        let d=AudioDecoder();d.limiterEnabled=false
        defer{d.close()}
        try d.adopt(source)
        _=try XCTUnwrap(read(d))
        do{try d.seek(to:Double(target)/48000)}
        catch {print("G0_4B32_COMPRESSED case=\(name) overlay=\(overlay) seek=error read=notRun");return}
        var samples=0,buffers=0,first=Int64.min,end=Int64.min,jumps=0,eof=false
        var h=SHA256()
        do{
            for _ in 0..<256 {
                guard let p=try read(d) else{eof=true;break}
                if buffers==0{first=p.pts}else if p.pts != end{jumps+=1}
                end=p.pts+Int64(p.frames);samples+=p.frames;buffers+=1;h.update(data:p.bytes)
            }
            XCTAssertTrue(eof)
            print("G0_4B32_COMPRESSED case=\(name) overlay=\(overlay) seek=ok read=\(buffers>0 ? "pcm":"nil") samples=\(samples) buffers=\(buffers) firstPTS=\(first) endPTS=\(end) jumps=\(jumps) eof=\(eof) hash=\(h.finalize().map{String(format:"%02x",$0)}.joined())")
        }catch{print("G0_4B32_COMPRESSED case=\(name) overlay=\(overlay) seek=ok read=error samples=\(samples) buffers=\(buffers)")}
    }
    func testMatrix()throws {
        let overlay=ProcessInfo.processInfo.environment["APOLO_G0_SEEK_OVERLAY"]=="1"
        let root=try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"wav",subdirectory:"Fixtures/G04B32")).deletingLastPathComponent()
        let original=try Data(contentsOf:root.appendingPathComponent("source.wav"))
        XCTAssertEqual(sha(original),"a11b59d05ee2011bdd4df4b1bf10d27b371d2cb29e49683f42adea25ccc43b8b")
        var wave=original,x:UInt32=0x12345678
        for i in stride(from:78,to:wave.count,by:2) {
            x ^= x<<13;x ^= x>>17;x ^= x<<5
            let u=UInt16(truncatingIfNeeded:x);wave[i]=UInt8(truncatingIfNeeded:u);wave[i+1]=UInt8(truncatingIfNeeded:u>>8)
        }
        let tmp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try wave.write(to:tmp);defer{try? FileManager.default.removeItem(at:tmp)}
        let ep=G0FrameRSSEndpointState(),server=try G0FrameRSSLoopbackServer(endpoint:ep)
        defer{server.stop()}
        print("G0_4B32_PROCESS pid=\(getpid()) overlay=\(overlay) sha=\(sha(wave))")
        var rawCount=0,bridgeCount=0,compressedCount=0
        for remote in [false,true] {
            let route=remote ? "http":"local",url=remote ? server.url:tmp
            for target:Int64 in [0,12000,48000,96000,144000] {
                if !overlay {
                    for flush in [false,true] {
                        ep.configure(payload:wave,range:true)
                        try raw(url,wave,"\(route)-t\(target)",target,flush);rawCount+=1
                    }
                }
                for depth in [0,1,8,-1] {
                    ep.configure(payload:wave,range:true)
                    try bridge(url,wave,"\(route)-d\(depth)-t\(target)",depth,target,overlay);bridgeCount+=1
                }
            }
            for ext in ["flac","opus","m4a"] {
                let file=root.appendingPathComponent("source."+ext)
                let data=try Data(contentsOf:file)
                for target:Int64 in [12000,48000,96000,144000] {
                    ep.configure(payload:data,range:true)
                    try compressed(remote ? server.url:file,"\(route)-\(ext)-t\(target)",target,overlay);compressedCount+=1
                }
            }
        }
        print("G0_4B32_SUMMARY overlay=\(overlay) raw=\(rawCount) bridge=\(bridgeCount) compressed=\(compressedCount)")
    }
}
private final class G0FrameRSSEndpointState: @unchecked Sendable {
    struct Event {
        let requestStart: Int
        let start: Int
        let status: Int
        let bytes: Int
    }
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }
    private let lock = NSLock()
    private var payload = Data()
    private var range = true
    private var failures = 0
    private var failureStatus = 0
    private var malformed = false
    private var events: [Event] = []

    func configure(payload: Data, range: Bool, failures: Int = 0,
                   failureStatus: Int = 0, malformed: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.payload = payload
        self.range = range
        self.failures = failures
        self.failureStatus = failureStatus
        self.malformed = malformed
        events = []
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func reply(for request: URLRequest) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        let parts = header.hasPrefix("bytes=")
            ? header.dropFirst(6).split(separator: "-") : []
        let start = parts.count == 2 ? Int(parts[0]) ?? -1 : -1
        let requestedEnd = parts.count == 2 ? Int(parts[1]) ?? -1 : -1
        var status = 200
        var responseStart = 0
        var body = payload
        var headers = ["Accept-Ranges": range ? "bytes" : "none"]
        if failures > 0 {
            failures -= 1
            status = failureStatus
            body = Data()
        } else if range {
            if start < 0 || start >= payload.count || requestedEnd < start {
                status = 416
                body = Data()
                headers["Content-Range"] = "bytes */\(payload.count)"
            } else {
                status = 206
                responseStart = start
                let end = min(requestedEnd, payload.count - 1)
                body = payload.subdata(in: start..<(end + 1))
                let reportedStart = malformed ? start + 1 : start
                headers["Content-Range"] = "bytes \(reportedStart)-\(end)/\(payload.count)"
            }
        }
        headers["Content-Length"] = String(body.count)
        events.append(Event(requestStart: start, start: responseStart, status: status, bytes: body.count))
        return Reply(status: status, headers: headers, body: body)
    }
}

private final class G0FrameRSSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0FrameRSSEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b32.loopback")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(connection, endpoint: endpoint, delayMS: delayMS, queue: queue, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port, port.rawValue != 0,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.wav")
        else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.url = url
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }

    private static func receive(
        _ connection: NWConnection, endpoint: G0FrameRSSEndpointState,
        delayMS: Int, queue: DispatchQueue, accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data, _, complete, error in
            var header = accumulated
            if let data { header.append(data) }
            guard error == nil, header.count <= 16384 else { connection.cancel(); return }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                guard let text = String(data: header.prefix(upTo: end.lowerBound), encoding: .utf8)
                else { connection.cancel(); return }
                let lines = text.components(separatedBy: "\r\n")
                guard let first = lines.first, first.hasPrefix("GET /fixture.wav ")
                else { connection.cancel(); return }
                var request = URLRequest(url: URL(string: "http://127.0.0.1/fixture.wav")!)
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 && parts[0].lowercased() == "range" {
                        request.setValue(parts[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
                    }
                }
                let reply = endpoint.reply(for: request)
                let reason: String
                switch reply.status {
                case 200: reason = "OK"
                case 206: reason = "Partial Content"
                case 416: reason = "Range Not Satisfiable"
                case 503: reason = "Service Unavailable"
                default: reason = "Error"
                }
                var response = "HTTP/1.1 \(reply.status) \(reason)\r\nConnection: close\r\nContent-Type: application/octet-stream\r\n"
                for key in reply.headers.keys.sorted() {
                    response += "\(key): \(reply.headers[key]!)\r\n"
                }
                response += "\r\n"
                var bytes = Data(response.utf8)
                bytes.append(reply.body)
                let packet = bytes
                queue.asyncAfter(deadline: .now() + .milliseconds(delayMS)) {
                    connection.send(content: packet, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            } else if complete {
                connection.cancel()
            } else {
                Self.receive(connection, endpoint: endpoint, delayMS: delayMS, queue: queue, accumulated: header)
            }
        }
    }
}


