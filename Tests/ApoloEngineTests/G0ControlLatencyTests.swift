import CoreMedia
import AudioToolbox
import CryptoKit
import Foundation
import Network
import XCTest
@testable import ApoloEngine

/// Measures real decoder operations on a serial host model, not renderer or UI latency.
final class G0ControlLatencyTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private enum Failure:Error {case invalid,timeout}
    private final class State:@unchecked Sendable {
        var decoder:AudioDecoder?
        weak var previous:AudioDecoder?
        func close(){decoder?.close();decoder=nil}
    }
    private struct PCM:Sendable {
        let pts:Int64
        let frames:Int
        let bytes:Data
    }
    private struct Measurement:Sendable {
        let begin:UInt64
        let end:UInt64
        let first:UInt64
        let pts:Int64
        let frames:Int
        let hash:String
    }
    private func now()->UInt64{DispatchTime.now().uptimeNanoseconds}
    private func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func submit<T:Sendable>(_ q:DispatchQueue,_ work:@escaping @Sendable ()throws->T)async throws->T {
        try await withCheckedThrowingContinuation { continuation in
            q.async {
                let result=Result{try work()}
                q.async{continuation.resume(with:result)}
            }
        }
    }
    private func open(_ url:URL)throws->AudioDecoder {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        let d=AudioDecoder()
        d.limiterEnabled=false
        try d.adopt(source)
        return d
    }
    private func read(_ d:AudioDecoder)throws->PCM {
        let b=try XCTUnwrap(d.readNextBuffer())
        let n=CMSampleBufferGetNumSamples(b)
        let pts=CMSampleBufferGetPresentationTimeStamp(b)
        guard n>0,pts.isNumeric,let desc=CMSampleBufferGetFormatDescription(b),
              let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let block=CMSampleBufferGetDataBuffer(b) else {throw Failure.invalid}
        let a=asbd.pointee
        guard a.mSampleRate==48000,a.mChannelsPerFrame==2,a.mBitsPerChannel==32,a.mBytesPerFrame==8,
              a.mFormatID==kAudioFormatLinearPCM,(a.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0,
              CMBlockBufferGetDataLength(block)==n*8 else {throw Failure.invalid}
        var data=Data(count:n*8)
        let rc=data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!) }
        guard rc==0 else{throw Failure.invalid}
        return PCM(pts:CMTimeConvertScale(pts,timescale:48000,method:.default).value,frames:n,bytes:data)
    }
    // Independent signed-16 WAV oracle: exclude only the intentional 3ms seek ramp.
    private func check(_ pcm:PCM,_ wave:Data,seek:Bool)throws {
        let skip=seek ? 144:0
        guard pcm.pts>=0,pcm.frames>skip,pcm.pts+Int64(pcm.frames)<=192000 else{throw Failure.invalid}
        let offset=78+Int(pcm.pts)*4
        var mismatch=0
        pcm.bytes.withUnsafeBytes { raw in
            for i in (skip*2)..<(pcm.frames*2) {
                let p=offset+i*2
                let s=Int16(bitPattern:UInt16(wave[p]) | UInt16(wave[p+1])<<8)
                let expected=Float(s)/32768
                let got=raw.loadUnaligned(fromByteOffset:i*4,as:Float.self)
                if got != expected {mismatch+=1}
            }
        }
        XCTAssertEqual(mismatch,0)
    }
    private func run(_ name:String,_ command:String,_ remote:Bool,_ delayed:Bool)async throws {
        let file=try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"wav",subdirectory:"Fixtures/G04B3"))
        let wave=try Data(contentsOf:file)
        XCTAssertEqual(wave.count,768078)
        XCTAssertEqual(sha(wave),"a11b59d05ee2011bdd4df4b1bf10d27b371d2cb29e49683f42adea25ccc43b8b")
        XCTAssertEqual(String(data:wave[70..<74],encoding:.ascii),"data")
        var modified=wave
        // Distinct B: polarity inversion of the original known sine, no codec change.
        for i in stride(from:78,to:wave.count,by:2) {
            let s=Int16(bitPattern:UInt16(wave[i]) | UInt16(wave[i+1])<<8)
            let u=UInt16(bitPattern:Int16(clamping:-Int(s)))
            modified[i]=UInt8(truncatingIfNeeded:u);modified[i+1]=UInt8(truncatingIfNeeded:u>>8)
        }
        let bWave=modified
        XCTAssertNotEqual(sha(wave),sha(bWave))
        let bFile=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try bWave.write(to:bFile)
        defer{try? FileManager.default.removeItem(at:bFile)}
        let ep=G0ControlRSSEndpointState(),epB=G0ControlRSSEndpointState()
        let blocker=G0ControlRSSEndpointState()
        let aServer=remote ? try G0ControlRSSLoopbackServer(endpoint:ep):nil
        let bServer=remote ? try G0ControlRSSLoopbackServer(endpoint:epB):nil
        let blockServer=delayed ? try G0ControlRSSLoopbackServer(endpoint:blocker,delayMS:250):nil
        defer{aServer?.stop();bServer?.stop();blockServer?.stop()}
        let aURL=aServer?.url ?? file,bURL=bServer?.url ?? bFile
        let q=DispatchQueue(label:"apolo.g0.4b3.host",qos:.userInitiated)
        print("G0_4B3_PROCESS profile=\(name) pid=\(getpid()) route=\(remote ? "http206":"local") command=\(command) delayed=\(delayed) fixtureSHA=\(sha(wave)) bSHA=\(sha(bWave))")
        var wait=[UInt64](),service=[UInt64](),response=[UInt64]()
        for index in -1...20 {
            ep.configure(payload:wave,range:true);epB.configure(payload:bWave,range:true)
            blocker.configure(payload:wave,range:true)
            let state=State()
            try await submit(q) {
                let d=try self.open(aURL);state.decoder=d;state.previous=d
                let first=try self.read(d)
                try self.check(first,wave,seek:false)
                XCTAssertEqual(first.pts,0)
            }
            let blocked=G0ControlBlockResult()
            if let blockServer {
                let u=blockServer.url
                q.async {
                    let begin=self.now()
                    do {
                        let source=try OpenedSource.open(url:u,sessionConfiguration:.ephemeral)
                        source.close()
                        blocked.set(begin,self.now(),true)
                    } catch {blocked.set(begin,self.now(),false)}
                }
                // Confirm an actual HTTP request was selected before command submission.
                let deadline = self.now() + 10_000_000_000
                while blocker.snapshot().isEmpty {
                    guard self.now() < deadline else {throw Failure.timeout}
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            let submitted=now()
            let value=try await submit(q) {
                let begin=self.now()
                let d=try XCTUnwrap(state.decoder)
                switch command {
                case "stop":
                    state.close()
                    let end=self.now()
                    XCTAssertNil(try d.readNextBuffer())
                    return Measurement(begin:begin,end:end,first:end,pts:-1,frames:0,hash:"none")
                case "seek":
                    try d.seek(to:2)
                    let end=self.now()
                    let pcm=try self.read(d)
                    let first=self.now()
                    XCTAssertGreaterThanOrEqual(pcm.pts,96000)
                    try self.check(pcm,wave,seek:true)
                    return Measurement(begin:begin,end:end,first:first,pts:pcm.pts,frames:pcm.frames,hash:self.sha(pcm.bytes))
                case "next":
                    let next=try self.open(bURL)
                    state.close();state.decoder=next
                    let end=self.now()
                    let pcm=try self.read(next)
                    let first=self.now()
                    XCTAssertEqual(pcm.pts,0)
                    try self.check(pcm,bWave,seek:false)
                    return Measurement(begin:begin,end:end,first:first,pts:pcm.pts,frames:pcm.frames,hash:self.sha(pcm.bytes))
                default:throw Failure.invalid
                }
            }
            let prior=blocked.get()
            if delayed {
                XCTAssertTrue(prior.2)
                XCTAssertLessThanOrEqual(prior.1,value.begin)
                XCTAssertLessThanOrEqual(prior.0,submitted)
                XCTAssertFalse(blocker.snapshot().isEmpty)
            }
            let aEvents=ep.snapshot(),bEvents=epB.snapshot()
            if remote {
                XCTAssertFalse(aEvents.isEmpty)
                XCTAssertTrue((aEvents+bEvents).allSatisfy{$0.status==206})
                if command=="next"{XCTAssertFalse(bEvents.isEmpty)}else{XCTAssertTrue(bEvents.isEmpty)}
            }else{XCTAssertTrue(aEvents.isEmpty && bEvents.isEmpty)}
            if command=="stop" || command=="next" {XCTAssertNil(state.previous)}
            try await submit(q){state.close()}
            XCTAssertNil(state.previous)
            let w=value.begin-submitted,s=value.end-value.begin,f=value.first-submitted
            if index>0 {wait.append(w);service.append(s);response.append(f)}
            let priorRemaining=prior.1>submitted ? prior.1-submitted:0
            print("G0_4B3_CASE profile=\(name) index=\(index) warmup=\(index<=0) waitNS=\(w) serviceNS=\(s) responseNS=\(f) priorRemainingNS=\(priorRemaining) priorNS=\(prior.1-prior.0) pts=\(value.pts) frames=\(value.frames) hash=\(value.hash) reqA=\(aEvents.count) reqB=\(bEvents.count) reqBlock=\(blocker.snapshot().count)")
        }
        for (metric,values) in [("waitNS",wait),("serviceNS",service),("responseNS",response)] {
            let v=values.sorted();XCTAssertEqual(v.count,20)
            print("G0_4B3_STATS profile=\(name) metric=\(metric) n=20 min=\(v[0]) p50=\(v[9]) p95=\(v[18]) max=\(v[19])")
        }
        print("G0_4B3_SUMMARY profile=\(name) measured=20 warmups=2")
    }
    func testLocalStop()async throws{try await run("local-stop","stop",false,false)}
    func testLocalSeek()async throws{try await run("local-seek","seek",false,false)}
    func testLocalNext()async throws{try await run("local-next","next",false,false)}
    func testHTTPStop()async throws{try await run("http-stop","stop",true,false)}
    func testHTTPSeek()async throws{try await run("http-seek","seek",true,false)}
    func testHTTPNext()async throws{try await run("http-next","next",true,false)}
    func testBlockedStop()async throws{try await run("blocked-stop","stop",true,true)}
    func testBlockedSeek()async throws{try await run("blocked-seek","seek",true,true)}
    func testBlockedNext()async throws{try await run("blocked-next","next",true,true)}
}
private final class G0ControlBlockResult:@unchecked Sendable {
    private let lock=NSLock()
    private var v:(UInt64,UInt64,Bool)=(0,0,false)
    func set(_ a:UInt64,_ b:UInt64,_ ok:Bool){lock.lock();v=(a,b,ok);lock.unlock()}
    func get()->(UInt64,UInt64,Bool){lock.lock();defer{lock.unlock()};return v}
}
private final class G0ControlRSSEndpointState: @unchecked Sendable {
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

private final class G0ControlRSSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0ControlRSSEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b3.loopback")
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
        _ connection: NWConnection, endpoint: G0ControlRSSEndpointState,
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


