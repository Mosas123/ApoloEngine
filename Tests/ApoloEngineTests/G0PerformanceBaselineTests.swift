import CoreMedia
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
@testable import ApoloEngine

/// Pre-fix baseline: simulator process metrics, no acoustic renderer.
final class G0PerformanceBaselineTests: XCTestCase {
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
    private func sample(_ url: URL, endpoint: G0PerfEndpointState?, expectedCodec:String, hashPCM:Bool) throws -> Result {
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
    private func report(_ name:String,_ phase:String,_ values:[UInt64]) {
        let v=values.sorted()
        XCTAssertEqual(v.count,20)
        guard v.count==20 else {return}
        print("G0_4B1_STATS profile=\(name) metric=\(phase) n=20 min=\(v[0]) p50=\(v[9]) p95=\(v[18]) max=\(v[19])")
    }
    func testBaseline() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures/G04B1")).deletingLastPathComponent()
        let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(fixtures.count,4)
        let processStart=resourceSnapshotR16()
        print("G0_4B1_PROCESS pid=\(getpid()) activeCPU=\(ProcessInfo.processInfo.activeProcessorCount) physicalMemory=\(ProcessInfo.processInfo.physicalMemory) rssStart=\(processStart.residentBytes ?? 0) maxRSSStart=\(processStart.maxRSS ?? -1)")
        var profiles=0,measured=0,warmups=0,controls=0
        for spec in fixtures {
            let local=root.appendingPathComponent(spec.file)
            let payload=try Data(contentsOf:local)
            XCTAssertEqual(sha(payload),spec.sha256)
            var reference:String?
            for mode in ["local","206","200"] {
                // Keep first round bounded: four local codecs, HTTP controls on WAV only.
                if mode != "local" && spec.codec != "pcm_s16le" {continue}
                let name=spec.file+"-"+mode
                let endpoint=mode=="local" ? nil : G0PerfEndpointState()
                let server=try endpoint.map{try G0PerfLoopbackServer(endpoint:$0)}
                defer {server?.stop()}
                let url=server?.url ?? local
                func execute(_ hash:Bool)throws->Result {
                    endpoint?.configure(payload:payload,range:mode=="206")
                    let value=try sample(url,endpoint:endpoint,expectedCodec:spec.codec,hashPCM:hash)
                    XCTAssertEqual(value.frames,spec.frames,"host decoded frame count \(name)")
                    if let endpoint {
                        let events=endpoint.snapshot()
                        XCTAssertFalse(events.isEmpty)
                        XCTAssertTrue(events.allSatisfy{$0.status == (mode=="206" ? 206 : 200)})
                    } else {XCTAssertEqual(value.requests,0)}
                    return value
                }
                let check=try execute(true);controls+=1
                if let reference {XCTAssertEqual(check.hash,reference)} else {reference=check.hash}
                print("G0_4B1_CONTROL profile=\(name) frames=\(check.frames) buffers=\(check.buffers) sha=\(check.hash) requests=\(check.requests) selectedBytes=\(check.selectedBytes)")
                for _ in 0..<2 {_ = try execute(false);warmups+=1}
                var results=[Result]()
                for index in 1...20 {
                    let value=try execute(false)
                    results.append(value);measured+=1
                    print("G0_4B1_CASE profile=\(name) index=\(index) frames=\(value.frames) buffers=\(value.buffers) openNS=\(value.openNS) adoptNS=\(value.adoptNS) firstNS=\(value.firstNS) drainNS=\(value.drainNS) closeNS=\(value.closeNS) cpuUS=\(value.cpuUS) rssBefore=\(value.rssBefore) rssAfter=\(value.rssAfter) maxRSS=\(value.maxRSS) requests=\(value.requests) selectedBytes=\(value.selectedBytes)")
                }
                let tail=try execute(true);controls+=1
                XCTAssertEqual(tail.hash,check.hash)
                XCTAssertEqual(tail.frames,check.frames)
                print("G0_4B1_CONTROL_END profile=\(name) frames=\(tail.frames) sha=\(tail.hash)")
                report(name,"openNS",results.map{$0.openNS})
                report(name,"adoptNS",results.map{$0.adoptNS})
                report(name,"firstNS",results.map{$0.firstNS})
                report(name,"startToFirstNS",results.map{$0.openNS+$0.adoptNS+$0.firstNS})
                report(name,"drainNS",results.map{$0.drainNS})
                report(name,"closeNS",results.map{$0.closeNS})
                report(name,"cpuUS",results.map{UInt64($0.cpuUS)})
                report(name,"rssAfter",results.map{$0.rssAfter})
                report(name,"requests",results.map{UInt64($0.requests)})
                report(name,"selectedBytes",results.map{UInt64($0.selectedBytes)})
                profiles+=1
            }
        }
        XCTAssertEqual(profiles,6);XCTAssertEqual(measured,120)
        XCTAssertEqual(warmups,12);XCTAssertEqual(controls,12)
        let end=resourceSnapshotR16()
        print("G0_4B1_SUMMARY profiles=\(profiles) measured=\(measured) warmups=\(warmups) controls=\(controls) rssEnd=\(end.residentBytes ?? 0) maxRSSEnd=\(end.maxRSS ?? -1)")
    }
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
private final class G0PerfEndpointState: @unchecked Sendable {
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

private final class G0PerfLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(endpoint: G0PerfEndpointState, delayMS: Int = 0) throws {
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
        _ connection: NWConnection, endpoint: G0PerfEndpointState,
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


