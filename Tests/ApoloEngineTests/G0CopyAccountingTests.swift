import CoreMedia
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
@testable import ApoloEngine

/// Pre-fix baseline: simulator process metrics, no acoustic renderer.
final class G0CopyAccountingTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private enum Failure: Error { case invalidFixture, invalidPCM, unbounded, resourceUnavailable }
    private struct Fixture: Decodable {
        let file: String
        let codec: String
        let frames: Int
        let sha256: String
    }
    private struct Result {
        let frames: Int
        let buffers: Int
        let hash: String
        let openNS: UInt64
        let adoptNS: UInt64
        let firstNS: UInt64
        let drainNS: UInt64
        let closeNS: UInt64
        let cpuUS: Int64
        let rssBefore: UInt64
        let rssAfter: UInt64
        let maxRSS: Int64
        let requests: Int
        let selectedBytes: Int
    }
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func sha(_ data: Data) -> String {
        SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    private func sample(_ url: URL, endpoint: G0CopyEndpointState?, expectedCodec:String, hashPCM:Bool) throws -> Result {
        let before=resourceSnapshotR16()
        guard let cpu0=before.cpuUS,let rss0=before.residentBytes else {throw Failure.resourceUnavailable}
        let start=now()
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer {source.close()}
        let opened=now()
        let track=try XCTUnwrap(source.info.audioTracks.first)
        XCTAssertEqual(track.codec,expectedCodec)
        XCTAssertEqual(track.sampleRate,48000)
        XCTAssertEqual(track.channels,2)
        let decoder=AudioDecoder()
        decoder.limiterEnabled=false
        defer {decoder.close()}
        try decoder.adopt(source)
        let adopted=now()
        var frames=0,buffers=0
        var hasher=SHA256()
        var first:UInt64?
        var reachedEOF=false
        for _ in 0..<4096 {
            guard let b=try decoder.readNextBuffer() else {
                reachedEOF=true
                break
            }
            if first==nil {first=now()}
            let n=CMSampleBufferGetNumSamples(b)
            guard n>0,frames+n<=48000*12 else {throw Failure.invalidPCM}
            guard let d=CMSampleBufferGetFormatDescription(b),
                  let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(d),
                  let block=CMSampleBufferGetDataBuffer(b) else {throw Failure.invalidPCM}
            let a=asbd.pointee
            guard a.mSampleRate==48000,a.mChannelsPerFrame==2,a.mFormatID==kAudioFormatLinearPCM,
                  a.mBitsPerChannel==32,a.mBytesPerFrame==8,
                  (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0,
                  CMBlockBufferGetDataLength(block)==n*8 else {throw Failure.invalidPCM}
            // Hash only untimed correctness controls. Timed trials do not copy PCM.
            if hashPCM {
                var bytes=Data(count:n*8)
                let rc=bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)
                }
                guard rc==0 else {throw Failure.invalidPCM}
                hasher.update(data:bytes)
            }
            frames+=n;buffers+=1
        }
        let drained=now()
        guard reachedEOF,let first,frames>0 else {throw Failure.unbounded}
        XCTAssertNil(try decoder.readNextBuffer())
        let closing=now()
        decoder.close()
        source.close()
        let closed=now()
        let after=resourceSnapshotR16()
        guard let cpu1=after.cpuUS,let rss1=after.residentBytes,let peak=after.maxRSS,cpu1>=cpu0 else {throw Failure.resourceUnavailable}
        let events=endpoint?.snapshot() ?? []
        let digest=hashPCM ? hasher.finalize().map{String(format:"%02x",$0)}.joined() : "untimed-only"
        return Result(frames:frames,buffers:buffers,hash:digest,
            openNS:opened-start,adoptNS:adopted-opened,firstNS:first-adopted,
            drainNS:drained-first,closeNS:closed-closing,cpuUS:cpu1-cpu0,
            rssBefore:rss0,rssAfter:rss1,maxRSS:peak,requests:events.count,
            selectedBytes:events.reduce(0){$0+$1.bytes})
    }
    private func run(_ filename:String,_ mode:String)throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures/G04B4")).deletingLastPathComponent()
        let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        let spec=try XCTUnwrap(fixtures.first{$0.file==filename})
        let file=root.appendingPathComponent(filename),payload=try Data(contentsOf:file)
        XCTAssertEqual(sha(payload),spec.sha256)
        let expected=["source.wav":"846a78fdbfec935e92d9397bc2f6957f76022f66b7d4162868c4b00a1bc9736f","source.flac":"846a78fdbfec935e92d9397bc2f6957f76022f66b7d4162868c4b00a1bc9736f","source.opus":"c835c557fffaf9b8bdd7a300f0e147bd95809c3026cab9c4a59f757a5a990e32","source.m4a":"f13f1351aa44a820498b0ca56fdb5cd5635d18b3ffcbb2f19f144e917a46e128"]
        let expectedFrames=filename=="source.m4a" ? 192512:192000
        let audit=ProcessInfo.processInfo.environment["APOLO_G0_COPY_AUDIT"]=="1"
        let ep=mode=="local" ? nil:G0CopyEndpointState()
        let server=try ep.map{try G0CopyLoopbackServer(endpoint:$0)}
        defer{server?.stop()}
        let url=server?.url ?? file
        let name=filename+"-"+mode
        print("G0_4B4_PROCESS profile=\(name) pid=\(getpid()) audit=\(audit) sha=\(spec.sha256)")
        func execute(_ index:Int,_ hash:Bool)throws->Result {
            ep?.configure(payload:payload,range:mode=="206")
            print("G0_4B4_BEGIN profile=\(name) index=\(index)")
            let v=try sample(url,endpoint:ep,expectedCodec:spec.codec,hashPCM:hash)
            XCTAssertEqual(v.frames,expectedFrames)
            if hash{XCTAssertEqual(v.hash,expected[filename])}
            let events=ep?.snapshot() ?? []
            if mode=="local"{XCTAssertTrue(events.isEmpty)}
            else{XCTAssertFalse(events.isEmpty);XCTAssertTrue(events.allSatisfy{$0.status==(mode=="206" ? 206:200)})}
            print("G0_4B4_CASE profile=\(name) index=\(index) frames=\(v.frames) buffers=\(v.buffers) hash=\(v.hash) openNS=\(v.openNS) adoptNS=\(v.adoptNS) firstNS=\(v.firstNS) drainNS=\(v.drainNS) closeNS=\(v.closeNS) cpuUS=\(v.cpuUS) rssBefore=\(v.rssBefore) rssAfter=\(v.rssAfter) maxRSS=\(v.maxRSS) requests=\(v.requests) selectedBytes=\(v.selectedBytes)")
            return v
        }
        if audit {
            _=try execute(0,true)
        }else{
            _=try execute(-2,true);_=try execute(-1,false);_=try execute(0,false)
            var samples=[Result]()
            for i in 1...10 {samples.append(try execute(i,false))}
            _=try execute(11,true)
            for (metric,values) in [("cpuUS",samples.map{UInt64($0.cpuUS)}),("startToEOFNS",samples.map{$0.openNS+$0.adoptNS+$0.firstNS+$0.drainNS})]{
                let sorted=values.sorted()
                print("G0_4B4_STATS profile=\(name) metric=\(metric) n=10 min=\(sorted[0]) p50=\(sorted[4]) p95=\(sorted[9]) max=\(sorted[9])")
            }
        }
        print("G0_4B4_SUMMARY profile=\(name) audit=\(audit) cases=\(audit ? 1:14)")
    }
    func testWAV()throws{try run("source.wav","local")}
    func testFLAC()throws{try run("source.flac","local")}
    func testOpus()throws{try run("source.opus","local")}
    func testAAC()throws{try run("source.m4a","local")}
    func testHTTP206()throws{try run("source.wav","206")}
    func testHTTP200()throws{try run("source.wav","200")}
    private struct ResourceSnapshotR16 {
        let cpuUS: Int64?
        let residentBytes: UInt64?
        let maxRSS: Int64?
    }

    private func resourceSnapshotR16() -> ResourceSnapshotR16 {
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = Int64(usage.ru_utime.tv_sec) * 1_000_000
            + Int64(usage.ru_utime.tv_usec)
            + Int64(usage.ru_stime.tv_sec) * 1_000_000
            + Int64(usage.ru_stime.tv_usec)
        var basic = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ResourceSnapshotR16(
            cpuUS: usageOK ? cpu : nil,
            residentBytes: status == KERN_SUCCESS ? UInt64(basic.resident_size) : nil,
            maxRSS: usageOK ? Int64(usage.ru_maxrss) : nil
        )
    }


}
private final class G0CopyEndpointState: @unchecked Sendable {
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

private final class G0CopyLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0CopyEndpointState, delayMS: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "apolo.g0.4b1.loopback")
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
        _ connection: NWConnection, endpoint: G0CopyEndpointState,
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


