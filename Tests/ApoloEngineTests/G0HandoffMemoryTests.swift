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
final class G0HandoffMemoryTests: XCTestCase, @unchecked Sendable {
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
    // All decoder and digest mutations occur on the serial queue.
    private final class TrackState: @unchecked Sendable {
        var decoder:AudioDecoder?
        var frames=0
        var buffers=0
        var digest=SHA256()
        var eof=false
        func close(){decoder?.close();decoder=nil}
    }
    private func submit<T:Sendable>(_ queue:DispatchQueue,_ work:@escaping @Sendable ()throws->T)async throws->T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result=Result{try work()}
                // A second serial item resumes after the first returns.
                queue.async {continuation.resume(with:result)}
            }
        }
    }
    private func adopt(_ source:OpenedSource,_ state:TrackState,_ owners:Owners)throws {
        defer{source.close()}
        let t=try XCTUnwrap(source.info.audioTracks.first)
        XCTAssertEqual(t.codec,"pcm_s16le");XCTAssertEqual(t.sampleRate,48000);XCTAssertEqual(t.channels,2)
        let decoder=AudioDecoder()
        owners.decoder=decoder
        decoder.limiterEnabled=false
        do {try decoder.adopt(source)}
        catch {decoder.close();throw error}
        state.decoder=decoder
    }
    private func readOne(_ s:TrackState)throws->Bool {
        let decoder=try XCTUnwrap(s.decoder)
        guard let b=try decoder.readNextBuffer() else {
            s.eof=true
            XCTAssertNil(try decoder.readNextBuffer())
            return false
        }
        let n=CMSampleBufferGetNumSamples(b)
        guard n>0,s.frames+n<=192000,s.buffers<256,
              let desc=CMSampleBufferGetFormatDescription(b),
              let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let block=CMSampleBufferGetDataBuffer(b) else{throw Failure.invalid}
        let a=asbd.pointee
        guard a.mSampleRate==48000,a.mChannelsPerFrame==2,a.mFormatID==kAudioFormatLinearPCM,
              a.mBitsPerChannel==32,a.mBytesPerFrame==8,
              (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0,
              CMBlockBufferGetDataLength(block)==n*8 else{throw Failure.invalid}
        var bytes=Data(count:n*8)
        let rc=bytes.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
        guard rc==0 else{throw Failure.invalid}
        s.digest.update(data:bytes);s.frames+=n;s.buffers+=1
        return true
    }
    private func finish(_ s:TrackState)throws->Int {
        XCTAssertTrue(s.eof)
        XCTAssertEqual(s.frames,192000)
        XCTAssertEqual(s.buffers,47)
        XCTAssertEqual(s.digest.finalize().map{String(format:"%02x",$0)}.joined(),"846a78fdbfec935e92d9397bc2f6957f76022f66b7d4162868c4b00a1bc9736f")
        s.close()
        return s.frames
    }
    private func openAndAdopt(_ url:URL,_ state:TrackState,_ o:Owners,_ queue:DispatchQueue,_ mode:String)async throws {
        if mode=="queueOpen" {
            try await submit(queue) {
                let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
                o.source=source
                try self.adopt(source,state,o)
            }
        } else {
            let source=try await Task.detached(priority:.userInitiated) {
                try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
            }.value
            o.source=source
            try await submit(queue){try self.adopt(source,state,o)}
        }
    }
    private func cycle(_ url:URL,_ o:Owners,_ queue:DispatchQueue,_ mode:String)async throws->(Int,Int,Snapshot,Snapshot) {
        if mode=="discard" {
            let source=try await Task.detached(priority:.userInitiated) {
                try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
            }.value
            o.source=source
            let opened=try snapshot()
            XCTAssertEqual(source.info.audioTracks.first?.codec,"pcm_s16le")
            XCTAssertEqual(source.info.duration,4,accuracy:0.000001)
            source.close()
            return (0,0,opened,try snapshot())
        }
        let state=TrackState()
        // Close on its owning queue even on a diagnostic error.
        do {
            try await openAndAdopt(url,state,o,queue,mode)
            let adopted=try snapshot()
            if mode=="burst" {
                try await submit(queue) {
                    for _ in 0..<256 {if try self.readOne(state) == false {return}}
                    throw Failure.invalid
                }
            } else {
                var ended=false
                for _ in 0..<256 {
                    let more=try await submit(queue){try self.readOne(state)}
                    if !more {ended=true;break}
                }
                guard ended else{throw Failure.invalid}
            }
            let drained=try snapshot()
            let frames=try await submit(queue){try self.finish(state)}
            return (frames,state.buffers,adopted,drained)
        } catch {
            try? await submit(queue){state.close()}
            throw error
        }
    }
    private func run(_ name:String,_ mode:String,_ range:Bool,_ local:Bool=false)async throws {
        let file=try XCTUnwrap(Bundle.module.url(forResource:"source",withExtension:"wav",subdirectory:"Fixtures/G04B22"))
        let payload=try Data(contentsOf:file)
        XCTAssertEqual(payload.count,768078)
        XCTAssertEqual(sha(payload),"a11b59d05ee2011bdd4df4b1bf10d27b371d2cb29e49683f42adea25ccc43b8b")
        let endpoint=G0HandoffRSSEndpointState()
        var server:G0HandoffRSSLoopbackServer?=local ? nil:try G0HandoffRSSLoopbackServer(endpoint:endpoint)
        defer{server?.stop()}
        let url=server?.url ?? file
        let queue=DispatchQueue(label:"apolo.g0.4b22.host",qos:.userInitiated)
        let owners=(-1...20).map{_ in Owners()}
        func emit(_ phase:String,_ s:Snapshot){
            print("G0_4B22_MEMORY profile=\(name) phase=\(phase) rss=\(s.rss) footprint=\(s.footprint.map{String($0)} ?? "unavailable") peak=\(s.peak) liveOwners=\(owners.reduce(0){$0+$1.live})")
        }
        print("G0_4B22_PROCESS profile=\(name) pid=\(getpid()) route=\(mode) range=\(range) local=\(local) fixtureSHA=\(sha(payload))")
        emit("start",try snapshot())
        for index in -1...20 {
            endpoint.configure(payload:payload,range:range)
            let before=try snapshot()
            let o=owners[index+1]
            let (frames,buffers,adopted,drained)=try await cycle(url,o,queue,mode)
            let after=try snapshot()
            let events=endpoint.snapshot()
            let expected=local ? 0 : (range && mode != "discard" ? 2 : 1)
            XCTAssertEqual(events.count,expected)
            XCTAssertTrue(events.allSatisfy{$0.status==(range ? 206:200)})
            XCTAssertEqual(events.reduce(0){$0+$1.bytes},local ? 0:(expected==2 ? 782492:768078))
            XCTAssertEqual(events.map{$0.requestStart},local ? []:(expected==2 ? [0,753664]:[0]))
            print("G0_4B22_CASE profile=\(name) index=\(index) warmup=\(index<=0) rssBefore=\(before.rss) rssAdopted=\(adopted.rss) rssDrained=\(drained.rss) rssAfter=\(after.rss) footprintBefore=\(before.footprint.map{String($0)} ?? "unavailable") footprintAfter=\(after.footprint.map{String($0)} ?? "unavailable") peak=\(after.peak) liveOwners=\(owners.reduce(0){$0+$1.live}) frames=\(frames) buffers=\(buffers) requests=\(events.count) bytes=\(events.reduce(0){$0+$1.bytes})")
        }
        emit("postCycles",try snapshot())
        try await Task.sleep(for:.seconds(1))
        emit("idle1s",try snapshot())
        try await Task.sleep(for:.seconds(4))
        emit("idle5s",try snapshot())
        server?.stop();server=nil
        endpoint.configure(payload:Data(),range:range)
        emit("teardown",try snapshot())
        try await Task.sleep(for:.seconds(5))
        emit("teardown5s",try snapshot())
        print("G0_4B22_SUMMARY profile=\(name) measured=20 warmups=2")
    }
    func testSplit206()async throws{try await run("split206","split",true)}
    func testBurst206()async throws{try await run("burst206","burst",true)}
    func testSplit200()async throws{try await run("split200","split",false)}
    func testBurst200()async throws{try await run("burst200","burst",false)}
    func testLocalSplit()async throws{try await run("local-split","split",false,true)}
    func testDiscard206()async throws{try await run("discard206","discard",true)}
    func testQueueOpen206()async throws{try await run("queue-open206","queueOpen",true)}
}
private final class G0HandoffRSSEndpointState: @unchecked Sendable {
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

private final class G0HandoffRSSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0HandoffRSSEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b22.loopback")
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
        _ connection: NWConnection, endpoint: G0HandoffRSSEndpointState,
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


