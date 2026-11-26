import CoreMedia
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import Network
import AetherLibavformat
import XCTest
@testable import ApoloEngine

/// Isolate one profile per test process. All resources are diagnostic observations.
final class G0HTTPMemoryTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private enum Failure:Error {case invalid,timeout,resource}
    private struct Snapshot {
        let rss:UInt64
        let peak:Int64
        let footprint:UInt64?
    }
    private final class Owners {
        weak var stream:HTTPStream?
        weak var transport:HTTPTransport?
        weak var source:OpenedSource?
        weak var decoder:AudioDecoder?
        weak var session:URLSession?
        var live:Int {
            (stream == nil ? 0:1)+(transport == nil ? 0:1)+(source == nil ? 0:1)+(decoder == nil ? 0:1)+(session == nil ? 0:1)
        }
    }
    private func snapshot() throws -> Snapshot {
        var u=rusage()
        guard getrusage(RUSAGE_SELF,&u)==0 else {throw Failure.resource}
        var b=mach_task_basic_info_data_t()
        var n=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size/MemoryLayout<integer_t>.size)
        let cap=Int(n)
        let rc=withUnsafeMutablePointer(to:&b) {p in
            p.withMemoryRebound(to:integer_t.self,capacity:cap) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&n)}
        }
        guard rc==KERN_SUCCESS else {throw Failure.resource}
        var vm=task_vm_info_data_t()
        var vn=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let vc=Int(vn)
        let vr=withUnsafeMutablePointer(to:&vm) {p in
            p.withMemoryRebound(to:integer_t.self,capacity:vc) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&vn)}
        }
        return Snapshot(rss:UInt64(b.resident_size),peak:Int64(u.ru_maxrss),footprint:vr==KERN_SUCCESS ? UInt64(vm.phys_footprint):nil)
    }
    private func sha(_ d:Data)->String {SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
    private func pcm(_ url:URL,_ owners:Owners)throws {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        owners.source=source
        defer{source.close()}
        let t=try XCTUnwrap(source.info.audioTracks.first)
        XCTAssertEqual(t.codec,"pcm_s16le");XCTAssertEqual(t.sampleRate,48000);XCTAssertEqual(t.channels,2)
        let decoder=AudioDecoder()
        owners.decoder=decoder
        decoder.limiterEnabled=false
        defer{decoder.close()}
        try decoder.adopt(source)
        var count=0,eof=false
        var h=SHA256()
        for _ in 0..<256 {
            guard let b=try decoder.readNextBuffer() else{eof=true;break}
            let n=CMSampleBufferGetNumSamples(b)
            guard n>0,count+n<=192000,let block=CMSampleBufferGetDataBuffer(b),
                  CMBlockBufferGetDataLength(block)==n*8 else{throw Failure.invalid}
            var bytes=Data(count:n*8)
            let rc=bytes.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
            guard rc==0 else{throw Failure.invalid}
            h.update(data:bytes);count+=n
        }
        XCTAssertTrue(eof);XCTAssertNil(try decoder.readNextBuffer());XCTAssertEqual(count,192000)
        XCTAssertEqual(h.finalize().map{String(format:"%02x",$0)}.joined(),"846a78fdbfec935e92d9397bc2f6957f76022f66b7d4162868c4b00a1bc9736f")
    }
    private func raw(_ url:URL,_ payload:Data,_ owners:Owners,avio:Bool)throws {
        let stream=HTTPStream(url:url,headers:[:],configuration:.ephemeral)
        owners.stream=stream
        let transport=avio ? try XCTUnwrap(HTTPTransport(stream:stream)):nil
        owners.transport=transport
        defer{transport?.close()}
        let bytes=UnsafeMutablePointer<UInt8>.allocate(capacity:32768)
        defer{bytes.deallocate()}
        var count=0,eof=false
        var h=SHA256()
        for _ in 0..<256 {
            let n:Int
            if let transport {n=Int(avio_read(try XCTUnwrap(transport.context),bytes,32768))}
            else{n=stream.read(into:bytes,count:32768)}
            if n==0 || n == -541478725 {eof=true;break}
            guard n>0,n<=32768,count+n<=payload.count else{throw Failure.invalid}
            h.update(data:Data(bytes:bytes,count:n));count+=n
        }
        XCTAssertTrue(eof);XCTAssertFalse(stream.hasError);XCTAssertEqual(count,payload.count)
        XCTAssertEqual(h.finalize().map{String(format:"%02x",$0)}.joined(),sha(payload))
        transport?.close()
        if let transport {XCTAssertNil(transport.context)}
    }
    private func probe(_ url:URL,_ owners:Owners)throws {
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        owners.source=source
        defer{source.close()}
        let t=try XCTUnwrap(source.info.audioTracks.first)
        XCTAssertEqual(t.codec,"pcm_s16le");XCTAssertEqual(t.sampleRate,48000);XCTAssertEqual(t.channels,2)
        XCTAssertEqual(source.info.duration,4,accuracy:0.000001)
    }
    private func direct(_ url:URL,_ payload:Data,_ owners:Owners,range:Bool)throws {
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=30
        config.timeoutIntervalForResource=600
        let session=URLSession(configuration:config)
        owners.session=session
        defer{session.invalidateAndCancel()}
        for start in range ? [0,753664]:[0] {
            var req=URLRequest(url:url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("bytes=\(start)-\(start+1048575)",forHTTPHeaderField:"Range")
            let result=G0RSSFetch()
            let sem=DispatchSemaphore(value:0)
            let task=session.dataTask(with:req){data,response,error in
                result.set(data,response,error)
                sem.signal()
            }
            task.resume()
            guard sem.wait(timeout:.now()+15)==.success else{task.cancel();throw Failure.timeout}
            let v=result.get()
            if let error=v.2 {throw error}
            let data=try XCTUnwrap(v.0)
            let response=try XCTUnwrap(v.1 as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode,range ? 206:200)
            XCTAssertEqual(data,payload.subdata(in:start..<payload.count))
        }
    }
    private func replyOnly(_ endpoint:G0RSSEndpointState,_ payload:Data,range:Bool)throws {
        for start in range ? [0,753664]:[0] {
            var req=URLRequest(url:URL(string:"http://127.0.0.1/fixture.wav")!)
            req.setValue("bytes=\(start)-\(start+1048575)",forHTTPHeaderField:"Range")
            let reply=endpoint.reply(for:req)
            XCTAssertEqual(reply.status,range ? 206:200)
            var response="HTTP/1.1 \(reply.status) OK\r\nConnection: close\r\nContent-Type: application/octet-stream\r\n"
            for key in reply.headers.keys.sorted(){response+="\(key): \(reply.headers[key]!)\r\n"}
            var packet=Data((response+"\r\n").utf8)
            packet.append(reply.body)
            XCTAssertEqual(packet.suffix(reply.body.count),payload.subdata(in:start..<payload.count))
        }
    }
    private func run(_ name:String,_ route:String,_ range:Bool,_ pool:Bool)throws {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"wav",subdirectory:"Fixtures/G04B2"))
        let payload=try Data(contentsOf:url)
        XCTAssertEqual(payload.count,768078)
        let endpoint=G0RSSEndpointState()
        var server:G0RSSLoopbackServer? = route=="local" || route=="reply" ? nil : try G0RSSLoopbackServer(endpoint:endpoint)
        defer{server?.stop()}
        let remote=server?.url ?? url
        var owners=[Owners]()
        func emit(_ phase:String,_ s:Snapshot)throws {
            print("G0_4B2_MEMORY profile=\(name) phase=\(phase) rss=\(s.rss) footprint=\(s.footprint.map{String($0)} ?? "unavailable") peak=\(s.peak) liveOwners=\(owners.reduce(0){$0+$1.live})")
        }
        print("G0_4B2_PROCESS profile=\(name) pid=\(getpid()) route=\(route) range=\(range) pool=\(pool) fixtureSHA=\(sha(payload))")
        try emit("start",snapshot())
        for index in -1...20 {
            endpoint.configure(payload:payload,range:range)
            let o=Owners()
            owners.append(o)
            let before=try snapshot()
            func work()throws->Snapshot {
                switch route {
                case "local":try pcm(url,o)
                case "engine":try pcm(remote,o)
                case "stream":try raw(remote,payload,o,avio:false)
                case "avio":try raw(remote,payload,o,avio:true)
                case "probe":try probe(remote,o)
                case "direct":try direct(remote,payload,o,range:range)
                case "reply":try replyOnly(endpoint,payload,range:range)
                default:throw Failure.invalid
                }
                return try snapshot()
            }
            let inner:Snapshot
            if pool {inner=try autoreleasepool(invoking:work)}
            else {inner=try work()}
            let after=try snapshot()
            let events=endpoint.snapshot()
            if route != "local" {
                XCTAssertFalse(events.isEmpty)
                XCTAssertTrue(events.allSatisfy{$0.status==(range ? 206:200)})
            } else {XCTAssertTrue(events.isEmpty)}
            if route=="engine" || route=="direct" || route=="reply" {
                XCTAssertEqual(events.count,range ? 2:1)
                XCTAssertEqual(events.reduce(0){$0+$1.bytes},range ? 782492:768078)
            }
            print("G0_4B2_CASE profile=\(name) index=\(index) warmup=\(index<=0) rssBefore=\(before.rss) rssInner=\(inner.rss) rssAfter=\(after.rss) footprintBefore=\(before.footprint.map{String($0)} ?? "unavailable") footprintAfter=\(after.footprint.map{String($0)} ?? "unavailable") peak=\(after.peak) liveOwners=\(owners.reduce(0){$0+$1.live}) requests=\(events.count) bytes=\(events.reduce(0){$0+$1.bytes}) starts=\(events.map{$0.requestStart}.map(String.init).joined(separator:","))")
        }
        try emit("postCycles",snapshot())
        Thread.sleep(forTimeInterval:1)
        try emit("idle1s",snapshot())
        Thread.sleep(forTimeInterval:4)
        try emit("idle5s",snapshot())
        server?.stop();server=nil
        endpoint.configure(payload:Data(),range:range)
        try emit("teardown",snapshot())
        Thread.sleep(forTimeInterval:5)
        try emit("teardown5s",snapshot())
        print("G0_4B2_SUMMARY profile=\(name) measured=20 warmups=2")
    }
    func testLocalPool()throws{try run("local-pool","local",false,true)}
    func testEngine206Plain()throws{try run("engine206-plain","engine",true,false)}
    func testEngine206Pool()throws{try run("engine206-pool","engine",true,true)}
    func testEngine200Plain()throws{try run("engine200-plain","engine",false,false)}
    func testEngine200Pool()throws{try run("engine200-pool","engine",false,true)}
    func testStream206Pool()throws{try run("stream206-pool","stream",true,true)}
    func testAVIO206Pool()throws{try run("avio206-pool","avio",true,true)}
    func testProbe206Pool()throws{try run("probe206-pool","probe",true,true)}
    func testDirect206Plain()throws{try run("direct206-plain","direct",true,false)}
    func testDirect206Pool()throws{try run("direct206-pool","direct",true,true)}
    func testDirect200Pool()throws{try run("direct200-pool","direct",false,true)}
    func testReply206Pool()throws{try run("reply206-pool","reply",true,true)}
    func testReply200Pool()throws{try run("reply200-pool","reply",false,true)}
}
private final class G0RSSFetch:@unchecked Sendable {
    private let lock=NSLock()
    private var value:(Data?,URLResponse?,Error?)=(nil,nil,nil)
    func set(_ d:Data?,_ r:URLResponse?,_ e:Error?){lock.lock();value=(d,r,e);lock.unlock()}
    func get()->(Data?,URLResponse?,Error?){lock.lock();defer{lock.unlock()};return value}
}
private final class G0RSSEndpointState: @unchecked Sendable {
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

private final class G0RSSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0RSSEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b2.loopback")
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
        _ connection: NWConnection, endpoint: G0RSSEndpointState,
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


