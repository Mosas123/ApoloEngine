import Foundation
import XCTest
import CryptoKit
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

final class G0F09BitmapSubtitleTests: XCTestCase {
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
        let format: String
        let codec: String
        let sha256: String
        let forced: Bool
        let files: [String:String]
        let packets: [Packet]
    }
    private struct Manifest: Decodable { let fixtures: [Fixture] }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func testBitmapSubtitlePackets() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/G0F09G2")).deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.fixtures.count, 2)
        var total = 0, exact = 0, packetTotal = 0
        for spec in manifest.fixtures {
            let url = root.appendingPathComponent(spec.file)
            XCTAssertEqual(hash(try Data(contentsOf: url)), spec.sha256)
            for (name,digest) in spec.files {
                XCTAssertEqual(URL(fileURLWithPath:name).lastPathComponent,name)
                XCTAssertEqual(hash(try Data(contentsOf:root.appendingPathComponent(name))),digest)
            }
            var context: UnsafeMutablePointer<AVFormatContext>?
            defer { avformat_close_input(&context) }
            let input = spec.forced ? spec.format.withCString { av_find_input_format($0) } : nil
            if spec.forced { XCTAssertNotNil(input) }
            let open = url.path.withCString { avformat_open_input(&context, $0, input, nil) }
            print("G0_F09G2_OPEN file=\(spec.file) forced=\(spec.forced) rc=\(open)")
            XCTAssertEqual(open, 0)
            guard open >= 0, let c = context else { continue }
            let info = avformat_find_stream_info(c, nil)
            let format = String(cString: try XCTUnwrap(c.pointee.iformat).pointee.name)
            XCTAssertEqual(format, spec.format)
            XCTAssertEqual(c.pointee.nb_streams, 1)
            let st = try XCTUnwrap(c.pointee.streams[0])
            let par = try XCTUnwrap(st.pointee.codecpar)
            let codec = String(cString: avcodec_get_name(par.pointee.codec_id))
            XCTAssertEqual(codec, spec.codec)
            XCTAssertEqual(par.pointee.codec_type, AVMEDIA_TYPE_SUBTITLE)
            // Raw generic data has no codec to probe; record info status.
            if !spec.forced { XCTAssertGreaterThanOrEqual(info, 0) }
            var owned = av_packet_alloc()
            defer { av_packet_free(&owned) }
            let p = try XCTUnwrap(owned)
            var packets = [Packet]()
            var terminal: Int32 = 0
            var missingPTS = 0, missingDTS = 0
            for _ in 0..<4096 {
                let rc = av_read_frame(c, p)
                if rc < 0 { terminal = rc; break }
                defer { av_packet_unref(p) }
                let v = p.pointee
                guard v.size > 0, v.size <= 1_048_576, let bytes = v.data else { XCTFail("invalid packet"); break }
                let record = Packet(size: Int(v.size), sha256: hash(Data(bytes: bytes, count: Int(v.size))))
                packets.append(record)
                if v.pts == Int64.min { missingPTS += 1 }
                if v.dts == Int64.min { missingDTS += 1 }
                print("G0_F09G2_PACKET file=\(spec.file) index=\(packets.count) pts=\(v.pts) dts=\(v.dts) duration=\(v.duration) size=\(v.size) sha=\(record.sha256)")
            }
            let repeatEOF = av_read_frame(c, p)
            if repeatEOF >= 0 { av_packet_unref(p) }
            XCTAssertEqual(terminal, -541478725)
            XCTAssertEqual(repeatEOF, -541478725)
            XCTAssertFalse(packets.isEmpty)
            let match = packets == spec.packets
            if match { exact += 1 }
            XCTAssertEqual(packets.count, spec.packets.count)
            XCTAssertTrue(match, "synthetic packet hash/size differs from independent host oracle")
            total += 1
            packetTotal += packets.count
            let tb = st.pointee.time_base
            print("G0_F09G2_DEMUX file=\(spec.file) format=\(format) codec=\(codec) info=\(info) tb=\(tb.num)/\(tb.den) packets=\(packets.count) hostPackets=\(spec.packets.count) hostExact=\(match) missingPTS=\(missingPTS) missingDTS=\(missingDTS) terminal=\(terminal) repeat=\(repeatEOF)")
        }
        XCTAssertEqual(total, 2)
        print("G0_F09G2_SUMMARY profiles=\(total) hostExact=\(exact) packets=\(packetTotal) decoded=0")
    }
}
