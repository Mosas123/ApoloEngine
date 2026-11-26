import Foundation
import XCTest
import CryptoKit
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

final class G0F09HEVCPacketTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private struct Packet: Decodable, Equatable {
        let size: Int
        let sha256: String
    }
    private struct Fixture: Decodable {
        let file: String
        let sha256: String
        let packets: [Packet]
    }
    private struct Manifest: Decodable { let fixtures: [Fixture] }
    private struct NAL: Equatable {
        let type: Int
        let size: Int
        let sha: String
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    // Annex B scanner, independent of libavformat. Normalize start-code
    // width and trailing zero bytes; record raw equality separately.
    private func nals(_ data: Data) -> [NAL] {
        let b = [UInt8](data)
        var starts = [(prefix: Int, payload: Int)]()
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i+1] == 0 {
                if i+3 < b.count && b[i+2] == 0 && b[i+3] == 1 {
                    starts.append((i,i+4)); i += 4; continue
                }
                if b[i+2] == 1 {
                    starts.append((i,i+3)); i += 3; continue
                }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            var end = index+1 < starts.count ? starts[index+1].prefix : b.count
            while end > start.payload && b[end-1] == 0 { end -= 1 }
            guard end-start.payload >= 2 else { return nil }
            return NAL(type: Int((b[start.payload] >> 1) & 63),
                       size: end-start.payload, sha: hash(Data(b[start.payload..<end])))
        }
    }
    private func firstDifference(_ a: Data, _ b: Data) -> Int {
        for (i,pair) in zip(a,b).enumerated() where pair.0 != pair.1 { return i }
        return a.count == b.count ? -1 : min(a.count,b.count)
    }
    func testHEVCAnnexBPacketization() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures/G0F09G")).deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:root.appendingPathComponent("manifest.json")))
        let spec = try XCTUnwrap(manifest.fixtures.first { $0.file == "video.hevc" })
        let url = root.appendingPathComponent(spec.file)
        let source = try Data(contentsOf:url)
        XCTAssertEqual(hash(source),spec.sha256)
        let host = try Data(contentsOf:root.appendingPathComponent("host-hevc.concat"))
        let hostPackets = try JSONDecoder().decode([Packet].self,from:Data(contentsOf:root.appendingPathComponent("host-hevc-packets.json")))
        let hostOriginal = hostPackets == spec.packets
        let sourceNAL = nals(source)
        let hostNAL = nals(host)
        XCTAssertFalse(sourceNAL.isEmpty)
        print("G0_F09G1_VERSION avformat=\(avformat_version()) avcodec=\(avcodec_version())")
        print("G0_F09G1_REFERENCE sourceBytes=\(source.count) sourceSHA=\(hash(source)) hostBytes=\(host.count) hostSHA=\(hash(host)) hostOriginal=\(hostOriginal) hostRawExact=\(host == source) hostNALExact=\(hostNAL == sourceNAL) sourceNALs=\(sourceNAL.count) hostNALs=\(hostNAL.count) firstDiff=\(firstDifference(source,host))")
        for (name, rows) in [("source",sourceNAL),("host",hostNAL)] {
            for (i,nal) in rows.enumerated() {
                print("G0_F09G1_NAL mode=\(name) index=\(i) type=\(nal.type) size=\(nal.size) sha=\(nal.sha)")
            }
        }
        for mode in ["autoInfo","forcedInfo","forcedNoInfo"] {
            var context: UnsafeMutablePointer<AVFormatContext>?
            defer { avformat_close_input(&context) }
            let input = mode == "autoInfo" ? nil : "hevc".withCString { av_find_input_format($0) }
            if mode != "autoInfo" { XCTAssertNotNil(input) }
            let rc = url.path.withCString { avformat_open_input(&context,$0,input,nil) }
            XCTAssertEqual(rc,0)
            let c = try XCTUnwrap(context)
            let info = mode == "forcedNoInfo" ? -999 : avformat_find_stream_info(c,nil)
            if mode != "forcedNoInfo" { XCTAssertGreaterThanOrEqual(info,0) }
            var owner = av_packet_alloc()
            defer { av_packet_free(&owner) }
            let packet = try XCTUnwrap(owner)
            var got = Data(), rows = [Packet]()
            var terminal: Int32 = 0
            for _ in 0..<4096 {
                let read = av_read_frame(c,packet)
                if read < 0 { terminal = read; break }
                defer { av_packet_unref(packet) }
                let p = packet.pointee
                guard p.size > 0, p.size <= 1_048_576, let ptr = p.data else { XCTFail("invalid packet"); break }
                let bytes = Data(bytes:ptr,count:Int(p.size))
                let record = Packet(size:bytes.count,sha256:hash(bytes))
                rows.append(record)
                got.append(bytes)
                let index = rows.count-1
                let hostMatch = index < hostPackets.count && record == hostPackets[index]
                print("G0_F09G1_PACKET mode=\(mode) index=\(index) pos=\(p.pos) pts=\(p.pts) dts=\(p.dts) duration=\(p.duration) size=\(p.size) sha=\(record.sha256) hostMatch=\(hostMatch)")
            }
            let repeatEOF = av_read_frame(c,packet)
            if repeatEOF >= 0 { av_packet_unref(packet) }
            XCTAssertEqual(terminal,-541478725)
            XCTAssertEqual(repeatEOF,-541478725)
            XCTAssertFalse(rows.isEmpty)
            let nal = nals(got)
            for (i,n) in nal.enumerated() {
                print("G0_F09G1_NAL mode=\(mode) index=\(i) type=\(n.type) size=\(n.size) sha=\(n.sha)")
            }
            print("G0_F09G1_RESULT mode=\(mode) info=\(info) packets=\(rows.count) bytes=\(got.count) sha=\(hash(got)) hostPacketExact=\(rows == hostPackets) originalPacketExact=\(rows == spec.packets) sourceRawExact=\(got == source) hostRawExact=\(got == host) sourceNALExact=\(nal == sourceNAL) hostNALExact=\(nal == hostNAL) nals=\(nal.count) sourceFirstDiff=\(firstDifference(source,got)) hostFirstDiff=\(firstDifference(host,got)) terminal=\(terminal) repeat=\(repeatEOF)")
            // Preserve observations: do not assume identical FFmpeg
            // distributions packetize identically or alter media payload.
        }
        print("G0_F09G1_SUMMARY profiles=3 decoded=0")
    }
}
