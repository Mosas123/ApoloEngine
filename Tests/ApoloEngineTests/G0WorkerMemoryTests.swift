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
final class G0WorkerMemoryTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private enum Failure:Error {case invalid,timeout,resource}
    private struct Snapshot: Sendable {
        let rss:UInt64
        let peak:Int64
        let footprint:UInt64?
    }
    private final class Owners: @unchecked Sendable {
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
            let result=G0WorkerRSSFetch()
            let sem=DispatchSemaphore(value:0)
            let task=session.dataTask(with:req){data,response,error in
                result.set(data,response,error)
                sem.signal()
            }
            task.resume()
            guard sem.wait(timeout: .now() + 15) == .success else{task.cancel();throw Failure.timeout}
            let v=result.get()
            if let error=v.2 {throw error}
            let data=try XCTUnwrap(v.0)
            let response=try XCTUnwrap(v.1 as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode,range ? 206:200)
            XCTAssertEqual(data,payload.subdata(in:start..<payload.count))
        }
    }
    // A serial async submission, not sync (which may run on the caller).
    // The second submission proves the first work item returned before the next sample.
    private func submit<T:Sendable>(_ queue:DispatchQueue,_ work:@escaping @Sendable ()throws->T)throws->T {
        let box=G0WorkerResult<T>()
        let done=DispatchSemaphore(value:0)
        queue.async {
            box.set(Result{try work()})
        }
        queue.async {done.signal()}
        guard done.wait(timeout:.now()+90) == .success else {throw Failure.timeout}
        return try box.get()
    }

    private func run(_ name:String,_ route:String,_ schedule:String,_ frequency:DispatchQueue.AutoreleaseFrequency,_ pool:Bool)throws {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"wav",subdirectory:"Fixtures/G04B21"))
        let payload=try Data(contentsOf:url)
        XCTAssertEqual(payload.count,768078)
        XCTAssertEqual(sha(payload),"a11b59d05ee2011bdd4df4b1bf10d27b371d2cb29e49683f42adea25ccc43b8b")
        let endpoint=G0WorkerRSSEndpointState()
        var server:G0WorkerRSSLoopbackServer?=try G0WorkerRSSLoopbackServer(endpoint:endpoint)
        defer{server?.stop()}
        let remote=try XCTUnwrap(server?.url)
        let queue=DispatchQueue(label:"apolo.g0.4b21.worker",qos:.userInitiated,autoreleaseFrequency:frequency)
        let owners=(-1...20).map{_ in Owners()}
        let callerThread=pthread_mach_thread_np(pthread_self())
        @Sendable func emit(_ phase:String,_ s:Snapshot) {
            print("G0_4B21_MEMORY profile=\(name) phase=\(phase) rss=\(s.rss) footprint=\(s.footprint.map{String($0)} ?? "unavailable") peak=\(s.peak) liveOwners=\(owners.reduce(0){$0+$1.live}) thread=\(pthread_mach_thread_np(pthread_self()))")
        }
        @Sendable func cycle(_ index:Int)throws {
            endpoint.configure(payload:payload,range:true)
            let o=owners[index+1]
            let before=try snapshot()
            let workerThread=pthread_mach_thread_np(pthread_self())
            if schedule != "caller" {XCTAssertNotEqual(workerThread,callerThread)}
            func work()throws->Snapshot {
                if route=="engine" {try pcm(remote,o)}
                else if route=="direct" {try direct(remote,payload,o,range:true)}
                else {throw Failure.invalid}
                return try snapshot()
            }
            let inner:Snapshot
            if pool {inner=try autoreleasepool(invoking:work)}
            else{inner=try work()}
            let after=try snapshot()
            let events=endpoint.snapshot()
            XCTAssertEqual(events.count,2)
            XCTAssertTrue(events.allSatisfy{$0.status==206})
            XCTAssertEqual(events.reduce(0){$0+$1.bytes},782492)
            XCTAssertEqual(events.map{$0.requestStart},[0,753664])
            print("G0_4B21_CASE profile=\(name) index=\(index) warmup=\(index<=0) rssBefore=\(before.rss) rssInner=\(inner.rss) rssAfter=\(after.rss) footprintBefore=\(before.footprint.map{String($0)} ?? "unavailable") footprintAfter=\(after.footprint.map{String($0)} ?? "unavailable") liveOwners=\(owners.reduce(0){$0+$1.live}) requests=2 bytes=782492 thread=\(workerThread)")
        }
        print("G0_4B21_PROCESS profile=\(name) pid=\(getpid()) route=\(route) schedule=\(schedule) pool=\(pool) callerThread=\(callerThread) fixtureSHA=\(sha(payload))")
        emit("start",try snapshot())
        if schedule=="batch" {
            try submit(queue) {
                for index in -1...20 {try cycle(index)}
                emit("beforeBatchReturn",try self.snapshot())
            }
            emit("afterBatchReturn",try snapshot())
        } else if schedule=="item" {
            for index in -1...20 {
                try submit(queue){try cycle(index)}
                emit("returned\(index)",try snapshot())
            }
        } else if schedule=="detached" {
            for index in -1...20 {
                let box=G0WorkerResult<Bool>()
                let done=DispatchSemaphore(value:0)
                Task.detached(priority:.userInitiated) {
                    defer{done.signal()}
                    box.set(Result{try cycle(index);return true})
                }
                guard done.wait(timeout:.now()+90) == .success else {throw Failure.timeout}
                _ = try box.get()
                // Signal occurs before the task returns; this snapshot is not a join.
                emit("signaled\(index)",try snapshot())
            }
        } else {
            for index in -1...20 {try cycle(index)}
        }
        emit("postCycles",try snapshot())
        // Pump the caller run loop during bounded idle; no sleep on worker.
        RunLoop.current.run(until:Date().addingTimeInterval(1))
        emit("idle1s",try snapshot())
        RunLoop.current.run(until:Date().addingTimeInterval(4))
        emit("idle5s",try snapshot())
        server?.stop();server=nil
        endpoint.configure(payload:Data(),range:true)
        emit("teardown",try snapshot())
        RunLoop.current.run(until:Date().addingTimeInterval(5))
        emit("teardown5s",try snapshot())
        print("G0_4B21_SUMMARY profile=\(name) measured=20 warmups=2")
    }
    func testEngineCallerPlain()throws{try run("engine-caller-plain","engine","caller",.inherit,false)}
    func testEngineInheritBatch()throws{try run("engine-inherit-batch","engine","batch",.inherit,false)}
    func testEngineInheritItem()throws{try run("engine-inherit-item","engine","item",.inherit,false)}
    func testEngineWorkItemBatch()throws{try run("engine-workitem-batch","engine","batch",.workItem,false)}
    func testEngineWorkItemItem()throws{try run("engine-workitem-item","engine","item",.workItem,false)}
    func testEngineNeverItem()throws{try run("engine-never-item","engine","item",.never,false)}
    func testEnginePoolBatch()throws{try run("engine-pool-batch","engine","batch",.inherit,true)}
    func testEngineDetached()throws{try run("engine-detached","engine","detached",.inherit,false)}
    func testDirectCallerPlain()throws{try run("direct-caller-plain","direct","caller",.inherit,false)}
    func testDirectInheritBatch()throws{try run("direct-inherit-batch","direct","batch",.inherit,false)}
    func testDirectInheritItem()throws{try run("direct-inherit-item","direct","item",.inherit,false)}
    func testDirectWorkItemItem()throws{try run("direct-workitem-item","direct","item",.workItem,false)}
    func testDirectNeverItem()throws{try run("direct-never-item","direct","item",.never,false)}
    func testDirectPoolBatch()throws{try run("direct-pool-batch","direct","batch",.inherit,true)}
    func testDirectDetached()throws{try run("direct-detached","direct","detached",.inherit,false)}

}
private final class G0WorkerResult<T:Sendable>: @unchecked Sendable {
    private let lock=NSLock()
    private var result:Result<T,Error>?
    func set(_ value:Result<T,Error>){lock.lock();result=value;lock.unlock()}
    func get()throws->T{lock.lock();defer{lock.unlock()};return try XCTUnwrap(result).get()}
}
private final class G0WorkerRSSFetch:@unchecked Sendable {
    private let lock=NSLock()
    private var value:(Data?,URLResponse?,Error?)=(nil,nil,nil)
    func set(_ d:Data?,_ r:URLResponse?,_ e:Error?){lock.lock();value=(d,r,e);lock.unlock()}
    func get()->(Data?,URLResponse?,Error?){lock.lock();defer{lock.unlock()};return value}
}
private final class G0WorkerRSSEndpointState: @unchecked Sendable {
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

private final class G0WorkerRSSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0WorkerRSSEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b21.loopback")
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
        _ connection: NWConnection, endpoint: G0WorkerRSSEndpointState,
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


