import Foundation
import XCTest
import AetherLibavformat
import AetherLibavutil
@testable import ApoloEngine

final class G0F09LiveContractsTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    func testRingWrapAndTerminalContracts() {
        for cap in [7, 31, 257, 4096] {
            let ring = LiveAudioBuffer(capacity: cap)
            var oracle = [UInt8]()
            var sequence = 0
            var peak = 0
            var total = 0
            for i in 0..<128 {
                let count = min(cap - oracle.count, 1 + (i * 13) % cap)
                let bytes = (0..<count).map { UInt8(truncatingIfNeeded: sequence + $0) }
                sequence += count
                XCTAssertTrue(ring.append(Data(bytes)))
                oracle += bytes
                peak = max(peak, ring.bufferedBytes)
                XCTAssertEqual(ring.bufferedBytes, oracle.count)
                XCTAssertFalse(ring.append(Data(repeating: 99, count: cap - oracle.count + 1)))
                XCTAssertEqual(ring.bufferedBytes, oracle.count)
                XCTAssertFalse(ring.hasFailed)
                var output = [UInt8](repeating: 0, count: 1 + (i * 7) % cap)
                let n = output.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, count: $0.count, timeout: 0)
                }
                XCTAssertEqual(n, min(output.count, oracle.count))
                XCTAssertEqual(Array(output.prefix(n)), Array(oracle.prefix(n)))
                oracle.removeFirst(n)
                total += n
            }
            ring.close()
            var out = [UInt8](repeating: 0, count: cap)
            let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: $0.count, timeout: 0) }
            XCTAssertEqual(Array(out.prefix(n)), oracle)
            XCTAssertEqual(n, oracle.count)
            XCTAssertFalse(ring.append(Data([1])))
            XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: $0.count, timeout: 0) }, 0)
            XCTAssertFalse(ring.hasFailed)
            print("G0_F09F_RING capacity=\(cap) peak=\(peak) bytes=\(total+n) closedDrain=\(n) error=\(ring.hasFailed)")
        }
        let ring = LiveAudioBuffer(capacity: 8)
        XCTAssertTrue(ring.append(Data([1,2,3])))
        ring.fail()
        var out = [UInt8](repeating: 0, count: 8)
        let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: $0.count, timeout: 0) }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(Array(out.prefix(n)), [1,2,3])
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: $0.count, timeout: 0) }, 0)
        XCTAssertTrue(ring.hasFailed)
        let empty = LiveAudioBuffer(capacity: 8)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { empty.read(into: $0.baseAddress!, count: $0.count, timeout: 0) }, 0)
        XCTAssertTrue(empty.hasFailed)
        print("G0_F09F_TERMINAL failureDrain=3 timeoutZeroFailed=true")
    }

    func testICYFragmentationMatrix() {
        func block(_ text: String) -> Data {
            let bytes = Data(text.utf8)
            let units = (bytes.count + 15) / 16
            return Data([UInt8(units)]) + bytes + Data(repeating: 0, count: units * 16 - bytes.count)
        }
        let first = Data([0,1,2,3]), second = Data([4,5,6,7]), third = Data([8,9,10,11]), fourth = Data([12,13,14,15])
        let wire = first + block("StreamTitle='A';") + second + Data([0]) + third + block("streamtitle=\"Bé\";") + fourth
        for step in 1...wire.count {
            var parser = ICYMetadataParser(interval: 4)
            var audio = Data()
            var titles = [String]()
            for offset in stride(from: 0, to: wire.count, by: step) {
                let r = parser.consume(Data(wire[offset..<min(wire.count, offset+step)]))
                audio += r.audio
                titles += r.titles
            }
            XCTAssertEqual(audio, first+second+third+fourth)
            XCTAssertEqual(titles, ["A","Bé"])
        }
        var passthrough = ICYMetadataParser(interval: 0)
        XCTAssertEqual(passthrough.consume(wire).audio, wire)
        var truncated = ICYMetadataParser(interval: 4)
        let partial = truncated.consume(first + Data([2]) + Data("StreamTitle='".utf8))
        XCTAssertEqual(partial.audio, first)
        XCTAssertTrue(partial.titles.isEmpty)
        print("G0_F09F_ICY profiles=\(wire.count) audioBytes=16 titles=2 passthrough=true truncatedTitleCount=0")
    }

    func testLiveAVIOContracts() throws {
        for mode in ["cleanEnd","networkLoss","icy","403","503","html","playlist","overflow"] {
            let state = F09FLiveState(mode: mode)
            F09FLiveProtocol.install(state)
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [F09FLiveProtocol.self]
            let token = LiveStreamCancellation()
            let stream = LiveHTTPStream(url: try XCTUnwrap(URL(string: "https://f09f.invalid/stream")), headers: [:],
                capacity: 128, configuration: c,
                onICYTitle: { state.title($0) },
                onHTTPStatus: { token.recordHTTPStatus($0); state.status($0) })
            token.register(stream)
            let transport = try XCTUnwrap(LiveHTTPTransport(stream: stream))
            defer { transport.close(); token.cancel() }
            let ctx = try XCTUnwrap(transport.context)
            XCTAssertEqual(ctx.pointee.seekable, 0)
            var bytes = [UInt8](repeating: 0, count: 64)
            var payload = Data()
            var codes = [Int32]()
            for _ in 0..<8 {
                let rc = bytes.withUnsafeMutableBufferPointer { avio_read(ctx, $0.baseAddress!, 64) }
                codes.append(rc)
                if rc <= 0 { break }
                payload.append(contentsOf: bytes.prefix(Int(rc)))
            }
            let again = bytes.withUnsafeMutableBufferPointer { avio_read(ctx, $0.baseAddress!, 64) }
            let seek = avio_seek(ctx, 0, 0x10000)
            let snap = state.snapshot()
            print("G0_F09F_AVIO mode=\(mode) codes=\(codes) repeat=\(again) sizeQuery=\(seek) bytes=\(payload.count) hex=\(payload.map { String(format: "%02x", $0) }.joined()) error=\(stream.hasError) terminal=\(token.terminalHTTPStatus ?? 0) status=\(snap.status) titles=\(snap.titles) requests=\(snap.requests) range=\(snap.range) icyHeader=\(snap.icy) buffered=\(stream.bufferedBytes)")
            XCTAssertEqual(codes.last, -5)
            XCTAssertEqual(again, -5)
            XCTAssertLessThan(seek, 0)
            XCTAssertTrue(stream.hasError)
            XCTAssertEqual(snap.requests, 1)
            XCTAssertFalse(snap.range)
            XCTAssertTrue(snap.icy)
            XCTAssertLessThanOrEqual(stream.bufferedBytes, stream.capacity)
            if mode == "cleanEnd" || mode == "networkLoss" { XCTAssertEqual(payload, Data((0..<16).map { UInt8($0) })) }
            else if mode == "icy" {
                XCTAssertEqual(payload, Data("abcdefgh".utf8))
                XCTAssertEqual(snap.titles, ["A"])
            } else { XCTAssertTrue(payload.isEmpty) }
            XCTAssertEqual(token.terminalHTTPStatus, mode == "403" ? 403 : nil)
        }
        print("G0_F09F_AVIO_SUMMARY profiles=8")
    }
}

private final class F09FLiveState: @unchecked Sendable {
    let mode: String
    private let lock = NSLock()
    private var requests = 0
    private var range = false
    private var icy = false
    private var storedStatus = 0
    private var titles = [String]()
    init(mode: String) { self.mode = mode }
    func request(_ r: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        range = r.value(forHTTPHeaderField: "Range") != nil
        icy = r.value(forHTTPHeaderField: "Icy-MetaData") == "1"
    }
    func status(_ n: Int) { lock.lock(); storedStatus = n; lock.unlock() }
    func title(_ t: String) { lock.lock(); titles.append(t); lock.unlock() }
    func snapshot() -> (requests: Int, range: Bool, icy: Bool, status: Int, titles: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (requests,range,icy,storedStatus,titles)
    }
}

private final class F09FLiveProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: F09FLiveState?
    static func install(_ state: F09FLiveState) { lock.lock(); current = state; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09f.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let s = Self.current; Self.lock.unlock()
        guard let s, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        s.request(request)
        let code = s.mode == "403" ? 403 : s.mode == "503" ? 503 : 200
        var headers = ["Content-Type": s.mode == "html" ? "text/html" : s.mode == "playlist" ? "application/vnd.apple.mpegurl" : "audio/mpeg"]
        if s.mode == "icy" { headers["icy-metaint"] = "4" }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if s.mode == "icy" {
            for part in [Data("abcd".utf8), Data([1]), Data("StreamTitle='A';".utf8), Data("efgh".utf8)] {
                client?.urlProtocol(self, didLoad: part)
            }
        } else if s.mode == "overflow" {
            client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 129))
        } else if s.mode == "cleanEnd" || s.mode == "networkLoss" {
            client?.urlProtocol(self, didLoad: Data((0..<16).map { UInt8($0) }))
        }
        if s.mode == "networkLoss" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
