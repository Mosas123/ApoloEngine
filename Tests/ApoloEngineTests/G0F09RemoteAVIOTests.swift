import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import CryptoKit
import Foundation
import XCTest
@testable import ApoloEngine

final class G0F09RemoteAVIOTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [F09ERangeProtocol.self]
        c.urlCache = nil
        return c
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private struct Packet: Equatable {
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let pos: Int64
        let size: Int32
        let digest: String
    }
    private struct Result {
        let packets: [Packet]
        let container: String
        let eof: Int32
    }
    private func read(_ url: URL, seek: Int64? = nil) throws -> Result {
        let source = try OpenedSource.open(url: url, sessionConfiguration: config())
        var owned = source.takeFormatContext()
        defer { avformat_close_input(&owned); source.close() }
        let c = try XCTUnwrap(owned)
        if let seek {
            let rc = av_seek_frame(c, 0, seek, 0)
            print("G0_F09E_SEEK rc=\(rc) wanted=\(seek)")
            if rc < 0 { return Result(packets: [], container: source.info.container, eof: rc) }
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let p = try XCTUnwrap(packet)
        var rows: [Packet] = []
        var terminal: Int32 = 0
        for _ in 0..<(seek == nil ? 4096 : 4) {
            let rc = av_read_frame(c, p)
            if rc < 0 { terminal = rc; break }
            defer { av_packet_unref(p) }
            let v = p.pointee
            guard v.size > 0, v.size <= 1048576, let bytes = v.data else {
                XCTFail("invalid packet"); break
            }
            rows.append(Packet(pts: v.pts, dts: v.dts, duration: v.duration,
                               pos: v.pos, size: v.size,
                               digest: hash(Data(bytes: bytes, count: Int(v.size)))))
        }
        if seek == nil {
            XCTAssertEqual(terminal, -541478725)
            XCTAssertEqual(av_read_frame(c, p), -541478725)
            XCTAssertFalse(rows.isEmpty)
        }
        return Result(packets: rows, container: source.info.container, eof: terminal)
    }
    func testF09ERemoteDemux() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/G0F09B")).deletingLastPathComponent()
        var profiles = 0
        var matched = 0
        for file in ["dts.dts", "truehd.truehd", "avi.avi"] {
            let local = root.appendingPathComponent(file)
            let bytes = try Data(contentsOf: local)
            let reference = try read(local)
            for mode in ["range", "short", "full"] {
                F09ERangeProtocol.configure(bytes, mode: mode)
                let url = try XCTUnwrap(URL(string: "https://f09e.invalid/" + file))
                let remote = try read(url)
                let exact = reference.packets == remote.packets
                let payloadExact = reference.packets.map { $0.digest } == remote.packets.map { $0.digest }
                XCTAssertEqual(reference.container, remote.container)
                // Preserve a negative parity observation rather than hiding it.
                profiles += 1
                if exact { matched += 1 }
                let requests = F09ERangeProtocol.snapshot()
                XCTAssertFalse(requests.isEmpty)
                print("G0_F09E_DEMUX file=\(file) mode=\(mode) sha=\(hash(bytes)) local=\(reference.packets.count) remote=\(remote.packets.count) exact=\(exact) payloadExact=\(payloadExact) eof=\(remote.eof) requests=\(requests.map(String.init).joined(separator: ","))")
                if !exact {
                    for (index, pair) in zip(reference.packets, remote.packets).enumerated() where pair.0 != pair.1 {
                        print("G0_F09E_DIFF file=\(file) mode=\(mode) index=\(index) local=\(pair.0) remote=\(pair.1)")
                    }
                }
                if file == "avi.avi" {
                    for ms in [250, 990] {
                        let target = Int64(ms) * 48
                        let a = try read(local, seek: target)
                        F09ERangeProtocol.configure(bytes, mode: mode)
                        let b = try read(url, seek: target)
                        print("G0_F09E_AVI file=\(file) mode=\(mode) ms=\(ms) exact=\(a.packets == b.packets) local=\(a.packets) remote=\(b.packets) localTerminal=\(a.eof) remoteTerminal=\(b.eof)")
                    }
                }
            }
        }
        XCTAssertEqual(profiles, 9)
        print("G0_F09E_DEMUX_SUMMARY profiles=\(profiles) exact=\(matched) decoded=0")
    }
    func testF09EByteTransport() throws {
        let boundary = 1 << 20
        var seed: UInt64 = 0x123456789abcdef
        var bytes = Data()
        for _ in 0..<(boundary + 257) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            bytes.append(UInt8(truncatingIfNeeded: seed))
        }
        let url = try XCTUnwrap(URL(string: "https://f09e.invalid/bytes"))
        for mode in ["range", "short", "full", "retry"] {
            F09ERangeProtocol.configure(bytes, mode: mode)
            let stream = HTTPStream(url: url, headers: [:], configuration: config())
            XCTAssertEqual(stream.seek(offset: 0, whence: 0x10000), Int64(bytes.count))
            for (start, wanted) in [(0, 32768), (boundary - 31, 100), (boundary, 257), (17, 33001), (bytes.count - 7, 20), (bytes.count, 1)] {
                XCTAssertEqual(stream.seek(offset: Int64(start), whence: 0), Int64(start))
                var got = Data()
                for _ in 0..<128 {
                    let left = wanted - got.count
                    if left <= 0 { break }
                    var buffer = [UInt8](repeating: 0, count: left)
                    let n = buffer.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: left) }
                    guard n > 0 else { break }
                    XCTAssertLessThanOrEqual(n, left)
                    got.append(contentsOf: buffer.prefix(n))
                }
                let expected = bytes.subdata(in: start..<min(start + wanted, bytes.count))
                XCTAssertEqual(got, expected)
                XCTAssertFalse(stream.hasError)
                print("G0_F09E_BYTES mode=\(mode) offset=\(start) wanted=\(wanted) actual=\(got.count) exact=\(got == expected) sha=\(hash(got))")
            }
            XCTAssertEqual(stream.seek(offset: 1, whence: 2), -1)
            XCTAssertEqual(stream.seek(offset: -1, whence: 0), -1)
            let requests = F09ERangeProtocol.snapshot()
            if mode == "retry" { XCTAssertGreaterThanOrEqual(requests.filter { $0 == 0 }.count, 2) }
            print("G0_F09E_REQUESTS mode=\(mode) offsets=\(requests.map(String.init).joined(separator: ","))")
        }
        F09ERangeProtocol.configure(bytes, mode: "malformed")
        let bad = HTTPStream(url: url, headers: [:], configuration: config())
        var scratch = [UInt8](repeating: 0, count: 8)
        let n = scratch.withUnsafeMutableBufferPointer { bad.read(into: $0.baseAddress!, count: 8) }
        XCTAssertEqual(n, 0)
        XCTAssertTrue(bad.hasError)
        print("G0_F09E_MALFORMED read=\(n) error=\(bad.hasError)")
    }
}

private final class F09ERangeProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var mode = "range"
    nonisolated(unsafe) private static var offsets: [Int] = []
    static func configure(_ data: Data, mode: String) {
        lock.lock(); defer { lock.unlock() }
        payload = data; self.mode = mode; offsets = []
    }
    static func snapshot() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return offsets
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f09e.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let range = request.value(forHTTPHeaderField: "Range"),
              range.hasPrefix("bytes=") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let bounds = range.dropFirst(6).split(separator: "-")
        guard bounds.count == 2, let start = Int(bounds[0]), let requestedEnd = Int(bounds[1]), start >= 0, requestedEnd >= start else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        Self.lock.lock()
        let data = Self.payload
        let mode = Self.mode
        let first = Self.offsets.isEmpty
        Self.offsets.append(start)
        Self.lock.unlock()
        var status = 206
        var body = Data()
        var headers: [String: String] = [:]
        if mode == "retry" && first { status = 503 }
        else if mode == "full" { status = 200; body = data }
        else if start >= data.count { status = 416; headers["Content-Range"] = "bytes */\(data.count)" }
        else {
            let end = min(requestedEnd, data.count - 1, mode == "short" ? start + 16383 : requestedEnd)
            body = data.subdata(in: start..<(end + 1))
            let declaredStart = mode == "malformed" ? start + 1 : start
            headers["Content-Range"] = "bytes \(declaredStart)-\(end)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        headers["Accept-Ranges"] = mode == "full" ? "none" : "bytes"
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
