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
final class G0WAVSeekLocalizationTests:XCTestCase {
    override func setUpWithError()throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private enum Failure:Error {case invalid,unbounded}
    private func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func raw(_ url:URL,_ wave:Data,_ name:String,_ depth:Int,_ target:Int64,_ flush:Bool)throws {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        var context=source.takeFormatContext()
        let transport=source.takeTransport()
        defer{avformat_close_input(&context);transport?.close()}
        let ctx=try XCTUnwrap(context)
        let streamIndex=av_find_best_stream(ctx,AVMEDIA_TYPE_AUDIO,-1,-1,nil,0)
        XCTAssertGreaterThanOrEqual(streamIndex,0)
        guard streamIndex>=0,let stream=ctx.pointee.streams[Int(streamIndex)] else{throw Failure.invalid}
        let tb=stream.pointee.time_base
        XCTAssertEqual(tb.num,1);XCTAssertEqual(tb.den,48000)
        var packet=av_packet_alloc()
        defer{av_packet_free(&packet)}
        let p=try XCTUnwrap(packet)
        func position()->String {
            guard let io=ctx.pointee.pb else{return "none"}
            return "\(avio_seek(io,0,SEEK_CUR)):\(io.pointee.eof_reached):\(io.pointee.error)"
        }
        var pre=0
        var preEOF=false
        for _ in 0..<(depth == -1 ? 256:depth) {
            let rc=av_read_frame(ctx,p)
            if rc<0 {XCTAssertEqual(rc,-541478725);preEOF=true;break}
            XCTAssertEqual(p.pointee.stream_index,streamIndex)
            pre+=1
            av_packet_unref(p)
        }
        if depth == -1 {XCTAssertTrue(preEOF)} else {XCTAssertEqual(pre,depth)}
        let before=position()
        let rc=avformat_seek_file(ctx,streamIndex,Int64.min,target,Int64.max,AVSEEK_FLAG_BACKWARD)
        let afterSeek=position()
        if rc>=0 && flush {avformat_flush(ctx)}
        let afterFlush=position()
        var packets=0,eligible=0,missing=0,mismatch=0,badPosition=0
        var firstPTS=Int64.min,firstPos:Int64 = -1,lastPTS=Int64.min
        var firstEligiblePTS=Int64.min,firstEligiblePos:Int64 = -1
        var terminal:Int32=0
        var totalFrames=0
        if rc>=0 {
            for _ in 0..<256 {
                let read=av_read_frame(ctx,p)
                if read<0 {terminal=read;break}
                let a=p.pointee
                guard a.stream_index==streamIndex,a.size>0,a.size%4==0,let bytes=a.data else{throw Failure.invalid}
                let n=Int(a.size),frames=n/4
                if packets==0{firstPTS=a.pts;firstPos=a.pos}
                lastPTS=a.pts;packets+=1;totalFrames+=frames
                if a.pts==Int64.min {missing+=1}
                if a.pts != Int64.min && a.pts>=target {
                    if eligible==0 {firstEligiblePTS=a.pts;firstEligiblePos=a.pos}
                    eligible+=1
                }
                if a.pos>=78,a.pos<=Int64(wave.count-n) {
                    let start=Int(a.pos)
                    if Data(bytes:bytes,count:n) != wave.subdata(in:start..<(start+n)){mismatch+=1}
                } else {badPosition+=1}
                if packets<=2 || packets==3 {
                    print("G0_4B31_PACKET case=\(name) flush=\(flush) index=\(packets) pts=\(a.pts) dts=\(a.dts) pos=\(a.pos) duration=\(a.duration) size=\(n) hash=\(sha(Data(bytes:bytes,count:n)))")
                }
                av_packet_unref(p)
            }
            XCTAssertNotEqual(terminal,0,"bounded demux")
            XCTAssertEqual(mismatch,0,"payload at reported file position")
        }
        print("G0_4B31_RAW case=\(name) flush=\(flush) depth=\(depth) pre=\(pre) preEOF=\(preEOF) target=\(target) tb=\(tb.num)/\(tb.den) rc=\(rc) before=\(before) afterSeek=\(afterSeek) afterFlush=\(afterFlush) packets=\(packets) frames=\(totalFrames) firstPTS=\(firstPTS) firstPos=\(firstPos) lastPTS=\(lastPTS) eligible=\(eligible) eligiblePTS=\(firstEligiblePTS) eligiblePos=\(firstEligiblePos) missing=\(missing) payloadMismatch=\(mismatch) badPosition=\(badPosition) terminal=\(terminal)")
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
    private func bridge(_ url:URL,_ wave:Data,_ name:String,_ depth:Int,_ target:Int64)throws {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        let d=AudioDecoder()
        d.limiterEnabled=false
        defer{d.close()}
        try d.adopt(source)
        print("G0_4B31_PHASE case=\(name) phase=adopted")
        var pre=0,preFrames=0
        var preEOF=false
        for _ in 0..<(depth == -1 ? 256:depth) {
            guard let pcm=try read(d) else{preEOF=true;break}
            XCTAssertEqual(pcm.pts,Int64(preFrames))
            XCTAssertEqual(mismatch(pcm,wave,pcm.pts,0),0)
            preFrames+=pcm.frames;pre+=1
        }
        if depth == -1 {XCTAssertTrue(preEOF);XCTAssertEqual(preFrames,192000)}
        else{XCTAssertEqual(pre,depth)}
        print("G0_4B31_PHASE case=\(name) phase=preRead pre=\(pre) frames=\(preFrames) eof=\(preEOF)")
        let t=DispatchTime.now().uptimeNanoseconds
        do {try d.seek(to:Double(target)/48000)}
        catch {
            print("G0_4B31_BRIDGE case=\(name) seek=error read=notRun error=\(String(describing:error))")
            return
        }
        let sought=DispatchTime.now().uptimeNanoseconds
        print("G0_4B31_PHASE case=\(name) phase=seekReturned seekNS=\(sought-t)")
        do {
            guard let pcm=try read(d) else {
                let repeated=try read(d)==nil
                print("G0_4B31_BRIDGE case=\(name) seek=ok read=nil repeatedNil=\(repeated) readNS=\(DispatchTime.now().uptimeNanoseconds-sought)")
                return
            }
            let first=DispatchTime.now().uptimeNanoseconds
            let skip=min(144,pcm.frames)
            print("G0_4B31_BRIDGE case=\(name) seek=ok read=pcm pts=\(pcm.pts) target=\(target) frames=\(pcm.frames) mismatchPTS=\(mismatch(pcm,wave,pcm.pts,skip)) mismatchTarget=\(mismatch(pcm,wave,target,skip)) skip=\(skip) hash=\(sha(pcm.bytes)) readNS=\(first-sought)")
        }catch{
            print("G0_4B31_BRIDGE case=\(name) seek=ok read=error error=\(String(describing:error))")
        }
    }
    private func run(_ name:String,_ remote:Bool,_ pattern:Bool)throws {
        let file=try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"wav",subdirectory:"Fixtures/G04B31"))
        let original=try Data(contentsOf:file)
        XCTAssertEqual(original.count,768078)
        XCTAssertEqual(sha(original),"a11b59d05ee2011bdd4df4b1bf10d27b371d2cb29e49683f42adea25ccc43b8b")
        XCTAssertEqual(String(data:original[70..<74],encoding:.ascii),"data")
        var wave=original
        if pattern {
            // Deterministic nonperiodic pseudo-random signed16 samples, not a sine.
            var x:UInt32=0x12345678
            for i in stride(from:78,to:wave.count,by:2) {
                x ^= x<<13;x ^= x>>17;x ^= x<<5
                let u=UInt16(truncatingIfNeeded:x)
                wave[i]=UInt8(truncatingIfNeeded:u);wave[i+1]=UInt8(truncatingIfNeeded:u>>8)
            }
        }
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try wave.write(to:temp)
        defer{try? FileManager.default.removeItem(at:temp)}
        let ep=G0SeekRSSEndpointState()
        let server=remote ? try G0SeekRSSLoopbackServer(endpoint:ep):nil
        defer{server?.stop()}
        let url=server?.url ?? temp
        print("G0_4B31_PROCESS profile=\(name) pid=\(getpid()) route=\(remote ? "http206":"local") sha=\(sha(wave))")
        var cases=0
        for depth in [0,1,8,-1] {
            for target:Int64 in [0,12000,48000,96000,144000] {
                let id="\(name)-d\(depth)-t\(target)"
                for flush in [false,true] {
                    ep.configure(payload:wave,range:true)
                    try raw(url,wave,id,depth,target,flush)
                    print("G0_4B31_HTTP case=\(id) route=raw-\(flush) requests=\(ep.snapshot().count) starts=\(ep.snapshot().map{$0.requestStart}) statuses=\(ep.snapshot().map{$0.status})")
                }
                ep.configure(payload:wave,range:true)
                try bridge(url,wave,id,depth,target)
                print("G0_4B31_HTTP case=\(id) route=bridge requests=\(ep.snapshot().count) starts=\(ep.snapshot().map{$0.requestStart}) statuses=\(ep.snapshot().map{$0.status})")
                cases+=1
            }
        }
        XCTAssertEqual(cases,20)
        print("G0_4B31_SUMMARY profile=\(name) cases=\(cases) routes=60")
    }
    func testLocalSine()throws{try run("local-sine",false,false)}
    func testHTTPSine()throws{try run("http-sine",true,false)}
    func testLocalPattern()throws{try run("local-pattern",false,true)}
    func testHTTPPattern()throws{try run("http-pattern",true,true)}
}
private final class G0SeekRSSEndpointState: @unchecked Sendable {
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

private final class G0SeekRSSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0SeekRSSEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b31.loopback")
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
        _ connection: NWConnection, endpoint: G0SeekRSSEndpointState,
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


