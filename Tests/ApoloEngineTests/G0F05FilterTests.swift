import AetherLibavfilter
import AetherLibavutil
import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import ApoloEngine

/// F05A: compiled filter registration and minimal audio graph contract.
final class G0F05FilterTests: XCTestCase {
    private enum LabError: Error { case setup, frame, graph, bound }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private let audio = [
        "abuffer","abuffersink","aformat","aresample","dialoguenhance","pan",
        "acompressor","alimiter","equalizer","superequalizer","firequalizer",
        "bass","treble","loudnorm","dynaudnorm","crossfeed","highpass","lowpass"
    ]
    private let video = [
        "buffer","buffersink","format","scale","zscale","tonemap","colorspace",
        "bwdif","yadif","idet","fieldmatch","decimate","yadif_videotoolbox","hwupload"
    ]

    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }

    private func bypass(rate: Int32, channels: Int, withFormat: Bool) throws -> (Int,Int,Bool,String) {
        var graphOwner = avfilter_graph_alloc()
        var inputOwner = av_frame_alloc(), outputOwner = av_frame_alloc()
        defer {
            av_frame_free(&inputOwner); av_frame_free(&outputOwner)
            avfilter_graph_free(&graphOwner)
        }
        guard let graph = graphOwner, let input = inputOwner, let output = outputOwner,
              let srcFilter = avfilter_get_by_name("abuffer"),
              let sinkFilter = avfilter_get_by_name("abuffersink")
        else { throw LabError.setup }
        let layout = channels == 1 ? "mono" : "stereo"
        let args = "time_base=1/\(rate):sample_rate=\(rate):sample_fmt=flt:channel_layout=\(layout)"
        var src: UnsafeMutablePointer<AVFilterContext>?
        var sink: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&src,srcFilter,"source",args,nil,graph) >= 0,
              avfilter_graph_create_filter(&sink,sinkFilter,"sink",nil,nil,graph) >= 0,
              let source=src, let target=sink else { throw LabError.graph }
        if withFormat {
            var middle: UnsafeMutablePointer<AVFilterContext>?
            guard let f=avfilter_get_by_name("aformat"),
                  avfilter_graph_create_filter(&middle,f,"pin",
                    "sample_fmts=flt:sample_rates=\(rate):channel_layouts=\(layout)",nil,graph) >= 0,
                  let m=middle, avfilter_link(source,0,m,0)>=0,
                  avfilter_link(m,0,target,0)>=0 else { throw LabError.graph }
        } else {
            guard avfilter_link(source,0,target,0)>=0 else { throw LabError.graph }
        }
        guard avfilter_graph_config(graph,nil)>=0 else { throw LabError.graph }
        let tb=av_buffersink_get_time_base(target)
        guard tb.num==1,tb.den==rate else { throw LabError.graph }
        var actual:[Float]=[], expected:[Float]=[]
        var cursor=0, outputFrames=0, buffers=0, timingExact=true
        let origin:Int64=12345
        let eof:Int32 = -541_478_725, again = -Int32(EAGAIN)
        func drain() throws -> Int32 {
            for _ in 0..<64 {
                let rc=av_buffersink_get_frame(target,output)
                if rc==eof || rc==again { return rc }
                guard rc>=0 else { throw LabError.frame }
                defer { av_frame_unref(output) }
                let f=output.pointee, n=Int(f.nb_samples)
                guard n>0,n<=1024,f.sample_rate==rate,
                      f.format==AV_SAMPLE_FMT_FLT.rawValue,
                      f.ch_layout.nb_channels==Int32(channels),
                      let planes=f.extended_data,let bytes=planes[0],
                      actual.count+n*channels<=4096 else { throw LabError.bound }
                if f.pts != origin+Int64(outputFrames) { timingExact=false }
                let p=UnsafeRawPointer(bytes)
                for i in 0..<(n*channels) {
                    let v=p.loadUnaligned(fromByteOffset:i*4,as:Float.self)
                    guard v.isFinite else { throw LabError.frame }
                    actual.append(v)
                }
                outputFrames += n; buffers += 1
            }
            throw LabError.bound
        }
        for n in [1,7,31,218] {
            input.pointee.nb_samples=Int32(n)
            input.pointee.format=AV_SAMPLE_FMT_FLT.rawValue
            input.pointee.sample_rate=rate
            input.pointee.pts=origin+Int64(cursor)
            av_channel_layout_default(&input.pointee.ch_layout,Int32(channels))
            guard av_frame_get_buffer(input,0)>=0,
                  let planes=input.pointee.extended_data,let bytes=planes[0] else { throw LabError.frame }
            let p=UnsafeMutableRawPointer(bytes)
            for i in 0..<n {
                for c in 0..<channels {
                    let v=Float((cursor+i)*113+c*997-15000)/32768
                    expected.append(v)
                    p.storeBytes(of:v,toByteOffset:(i*channels+c)*4,as:Float.self)
                }
            }
            guard av_buffersrc_add_frame_flags(source,input,0)>=0 else { throw LabError.frame }
            av_frame_unref(input)
            _=try drain()
            cursor += n
        }
        guard av_buffersrc_add_frame_flags(source,nil,0)>=0,
              try drain()==eof,try drain()==eof else { throw LabError.graph }
        let exact=actual.count==expected.count && zip(actual,expected).allSatisfy { $0.0.bitPattern==$0.1.bitPattern }
        return (actual.count,buffers,exact && timingExact && outputFrames==257,hash(actual))
    }

    func testG0F05AInventoryAndBypass() throws {
        var opaque: UnsafeMutableRawPointer?
        var names=Set<String>()
        for _ in 0..<4096 {
            guard let f=av_filter_iterate(&opaque) else { break }
            names.insert(String(cString:f.pointee.name))
        }
        let expected=Set(audio+video)
        let missing=expected.subtracting(names).sorted()
        let extra=names.subtracting(expected).sorted()
        print("G0_F05A_INVENTORY version=\(avfilter_version()) registered=\(names.count) audioPresent=\(audio.filter { names.contains($0) }.count) videoPresent=\(video.filter { names.contains($0) }.count) missing=\(missing.joined(separator:",")) extra=\(extra.joined(separator:",")) names=\(names.sorted().joined(separator:","))")
        for n in (audio+video).sorted() {
            let found=n.withCString { avfilter_get_by_name($0) != nil }
            print("G0_F05A_FILTER name=\(n) registered=\(names.contains(n)) lookup=\(found)")
            XCTAssertEqual(found,names.contains(n))
        }
        var attempted=0, exact=0, values=0, errors=0
        for rate:Int32 in [44100,48000,96000,192000] {
            for ch in [1,2] {
                for pin in [false,true] {
                    attempted += 1
                    do {
                        let (n,buffers,ok,digest)=try bypass(rate:rate,channels:ch,withFormat:pin)
                        if ok { exact += 1; values += n }
                        print("G0_F05A_CASE rate=\(rate) channels=\(ch) aformat=\(pin) scalarValues=\(n) buffers=\(buffers) pcmAndPTSExact=\(ok) pcmSHA256=\(digest) eof=true")
                    } catch {
                        errors += 1
                        print("G0_F05A_ERROR rate=\(rate) channels=\(ch) aformat=\(pin) error=\(error)")
                    }
                }
            }
        }
        print("G0_F05A_SUMMARY attempted=\(attempted) exact=\(exact) comparedValues=\(values) missingDeclared=\(missing.count) errors=\(errors)")
        XCTAssertEqual(attempted,16)
        XCTAssertEqual(exact,16)
        XCTAssertEqual(errors,0)
        // A missing declared filter is an inventory observation; some
        // hardware filters can be conditional by platform.
    }
}
