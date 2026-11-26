import Foundation
import XCTest
import CryptoKit
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import ApoloEngine

final class G0F09LiveTimestampTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private struct Packet: Equatable {
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let size: Int32
        let digest: String
    }
    private struct Scan {
        let rows: [Packet]
        let tb: String
        let terminal: Int32
        let repeatTerminal: Int32
        let avioError: Int32
        let seekable: Int32
        let container: String
    }
    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func scan(_ url: URL, live: Bool) throws -> Scan {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [F09F4Protocol.self]
        config.urlCache = nil
        let token = LiveStreamCancellation()
        let source = try OpenedSource.open(url: url, sessionConfiguration: config, isLive: live, liveCancellation: live ? token : nil)
        var owned = source.takeFormatContext()
        defer { avformat_close_input(&owned); source.close(); token.cancel() }
        let c = try XCTUnwrap(owned)
        let audioIndex = try XCTUnwrap(source.info.audioTracks.first?.index)
        let st = try XCTUnwrap(c.pointee.streams[audioIndex])
        let tb = st.pointee.time_base
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let p = try XCTUnwrap(packet)
        var rows = [Packet]()
        var terminal: Int32 = 0
        for _ in 0..<4096 {
            let rc = av_read_frame(c, p)
            if rc < 0 { terminal = rc; break }
            defer { av_packet_unref(p) }
            let v = p.pointee
            if Int(v.stream_index) != audioIndex { continue }
            guard v.size > 0, v.size <= 1_048_576, let bytes = v.data else {
                XCTFail("invalid packet"); break
            }
            rows.append(Packet(pts: v.pts, dts: v.dts, duration: v.duration,
                               size: v.size, digest: hash(Data(bytes: bytes, count: Int(v.size)))))
        }
        let again = av_read_frame(c, p)
        if again >= 0 { av_packet_unref(p) }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThan(terminal, 0)
        XCTAssertLessThan(again, 0)
        return Scan(rows: rows, tb: "\(tb.num)/\(tb.den)", terminal: terminal,
                    repeatTerminal: again, avioError: c.pointee.pb?.pointee.error ?? 0,
                    seekable: c.pointee.pb?.pointee.seekable ?? -1, container: source.info.container)
    }

    func testFreshLiveSessionTimestamps() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/G0F09F4")).deletingLastPathComponent()
        var profiles = 0
        var matchedPackets = 0
        for format in ["ogg", "aac", "mp3"] {
            var priorA: [Packet]?
            for (ordinal, label) in ["a","b","a"].enumerated() {
                let file = root.appendingPathComponent("\(label).\(format)")
                let data = try Data(contentsOf: file)
                XCTAssertLessThan(data.count, 128 * 1024)
                let local = try scan(file, live: false)
                let key = "\(format)-\(ordinal)"
                // Each new connection gets an entire independent encoded stream.
                F09F4Protocol.install(key, data, format: format, chunk: [97, 4096, 16384][ordinal])
                defer { F09F4Protocol.remove(key) }
                let url = try XCTUnwrap(URL(string: "https://f09f4.invalid/" + key))
                let live = try scan(url, live: true)
                let snap = F09F4Protocol.snapshot(key)
                let payloadExact = local.rows.map { $0.digest } == live.rows.map { $0.digest }
                let exact = local.rows == live.rows && local.tb == live.tb
                let missing = live.rows.filter { $0.pts == Int64.min || $0.dts == Int64.min }.count
                let discontinuities = zip(live.rows.dropLast(), live.rows.dropFirst()).filter { a,b in
                    a.pts != Int64.min && b.pts != Int64.min && a.duration > 0 && b.pts != a.pts + a.duration
                }.count
                let regressions = zip(live.rows.dropLast(), live.rows.dropFirst()).filter { a,b in
                    a.pts != Int64.min && b.pts != Int64.min && b.pts < a.pts
                }.count
                print("G0_F09F4_SESSION format=\(format) ordinal=\(ordinal) label=\(label) sha=\(hash(data)) bytes=\(data.count) localCount=\(local.rows.count) liveCount=\(live.rows.count) payloadExact=\(payloadExact) timestampExact=\(exact) localTB=\(local.tb) liveTB=\(live.tb) firstPTS=\(live.rows.first?.pts ?? Int64.min) lastPTS=\(live.rows.last?.pts ?? Int64.min) missing=\(missing) discontinuities=\(discontinuities) regressions=\(regressions) localTerminal=\(local.terminal) liveTerminal=\(live.terminal) repeated=\(live.repeatTerminal) avioError=\(live.avioError) seekable=\(live.seekable) requests=\(snap.requests) range=\(snap.range) sent=\(snap.sent)")
                XCTAssertEqual(local.container, live.container)
                XCTAssertEqual(live.seekable, 0)
                XCTAssertTrue(payloadExact)
                XCTAssertEqual(snap.requests, 1)
                XCTAssertFalse(snap.range)
                XCTAssertEqual(snap.sent, data.count)
                // Observe differences instead of equating nonseekable probing
                // with local seekable demux semantics.
                for (index, packet) in live.rows.enumerated() {
                    print("G0_F09F4_PACKET format=\(format) ordinal=\(ordinal) index=\(index) pts=\(packet.pts) dts=\(packet.dts) duration=\(packet.duration) size=\(packet.size) sha=\(packet.digest)")
                }
                if ordinal == 0 { priorA = live.rows }
                if ordinal == 2 {
                    XCTAssertEqual(live.rows, try XCTUnwrap(priorA), "fresh identical session should reset demux timeline regardless of chunk size")
                }
                profiles += 1
                if payloadExact { matchedPackets += live.rows.count }
            }
        }
        print("G0_F09F4_SUMMARY profiles=\(profiles) payloadMatchedPackets=\(matchedPackets) decoded=0")
        XCTAssertEqual(profiles, 9)
    }
}

private final class F09F4Protocol: URLProtocol {
    private struct Entry {
        let data: Data
        let format: String
        let chunk: Int
        var requests = 0
        var range = false
        var sent = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    static func install(_ key: String, _ data: Data, format: String, chunk: Int) {
        lock.lock(); entries[key] = Entry(data: data, format: format, chunk: chunk); lock.unlock()
    }
    static func remove(_ key: String) { lock.lock(); entries.removeValue(forKey: key); lock.unlock() }
    static func snapshot(_ key: String) -> (requests: Int, range: Bool, sent: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key] else { return (0,false,0) }
        return (e.requests,e.range,e.sent)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09f4.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.lastPathComponent
        Self.lock.lock()
        guard var entry = Self.entries[key] else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        entry.requests += 1
        entry.range = request.value(forHTTPHeaderField: "Range") != nil
        Self.entries[key] = entry
        Self.lock.unlock()
        let mime = entry.format == "ogg" ? "audio/ogg" : entry.format == "aac" ? "audio/aac" : "audio/mpeg"
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":mime]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: entry.data.count, by: entry.chunk) {
            let part = entry.data.subdata(in: offset..<min(offset + entry.chunk, entry.data.count))
            client?.urlProtocol(self, didLoad: part)
            Self.lock.lock(); Self.entries[key]?.sent += part.count; Self.lock.unlock()
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
