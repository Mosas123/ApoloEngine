import AetherLibavutil
import AetherLibswresample
import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import ApoloEngine

/// G0 4B.6: default linked SWR only, same semantic layout in/out.
/// Preallocated input/output; no decoder, DSP, renderer or production modifications.
final class G0SWRCostTests: XCTestCase {
    private enum LabError: Error { case setup, convert, bounds }
    private struct Result {
        let pcm: [Float]
        let elapsed: UInt64
        let cpu: Int64
        let initNS: UInt64
        let drainNS: UInt64
        let tail: Int
        let maxDelay: Int64
        let calls: Int
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func cpu() throws -> Int64 {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { throw LabError.setup }
        return Int64(u.ru_utime.tv_sec)*1000000+Int64(u.ru_utime.tv_usec)+Int64(u.ru_stime.tv_sec)*1000000+Int64(u.ru_stime.tv_usec)
    }
    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format:"%02x",$0) }.joined()
    }
    private func convert(_ bytes: [UInt8], inRate: Int32, outRate: Int32, ch: Int,
                         planar: Bool, integer: Bool, block: Int) throws -> Result {
        let frames = Int(inRate), width = integer ? 2 : 4
        let capacity = Int(outRate)+4096
        var dst = [Float](repeating:0,count:capacity*ch)
        var srcPtrs = [UnsafePointer<UInt8>?](repeating:nil,count:planar ? ch : 1)
        var input = AVChannelLayout(), output = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels:Int32(ch),into:&input)
        AudioDecoder.makeResamplerOutputLayout(channels:Int32(ch),into:&output)
        defer { av_channel_layout_uninit(&input); av_channel_layout_uninit(&output) }
        var context: OpaquePointer?
        defer { swr_free(&context) }
        let format = integer ? AV_SAMPLE_FMT_S16 : (planar ? AV_SAMPLE_FMT_FLTP : AV_SAMPLE_FMT_FLT)
        let initStart = DispatchTime.now().uptimeNanoseconds
        guard swr_alloc_set_opts2(&context,&output,AV_SAMPLE_FMT_FLT,outRate,&input,format,inRate,0,nil)>=0,
              let swr=context,swr_init(swr)>=0 else { throw LabError.setup }
        let initNS = DispatchTime.now().uptimeNanoseconds-initStart
        var written=0, cursor=0, tail=0, calls=0
        var maxDelay:Int64=0
        var drainNS:UInt64=0
        let c0=try cpu(), t0=DispatchTime.now().uptimeNanoseconds
        try bytes.withUnsafeBytes { raw in
            let base=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
            try dst.withUnsafeMutableBytes { out in
                let dest=out.baseAddress!.assumingMemoryBound(to:UInt8.self)
                func invoke(_ src: UnsafePointer<UnsafePointer<UInt8>?>?, _ count:Int32) throws -> Int {
                    guard written<capacity else { throw LabError.bounds }
                    var ptr:UnsafeMutablePointer<UInt8>?=dest.advanced(by:written*ch*4)
                    let got=withUnsafeMutablePointer(to:&ptr) { swr_convert(swr,$0,Int32(capacity-written),src,count) }
                    guard got>=0,Int(got)<=capacity-written else { throw LabError.convert }
                    written += Int(got); calls += 1
                    maxDelay=max(maxDelay,swr_get_delay(swr,Int64(inRate)))
                    return Int(got)
                }
                while cursor<frames {
                    let n=min(block,frames-cursor)
                    for p in srcPtrs.indices {
                        let offset=planar ? (p*frames+cursor)*width : cursor*ch*width
                        srcPtrs[p]=base.advanced(by:offset)
                    }
                    _ = try srcPtrs.withUnsafeBufferPointer { try invoke($0.baseAddress,Int32(n)) }
                    cursor += n
                }
                let drainStart=DispatchTime.now().uptimeNanoseconds
                var drained=false
                for _ in 0..<32 {
                    let n=try invoke(nil,0)
                    tail += n
                    if n==0 { drained=true;break }
                }
                drainNS=DispatchTime.now().uptimeNanoseconds-drainStart
                guard drained else { throw LabError.bounds }
            }
        }
        let elapsed=DispatchTime.now().uptimeNanoseconds-t0, c1=try cpu()
        let pcm=Array(dst.prefix(written*ch))
        guard abs(written-Int(outRate))<=1,pcm.allSatisfy({$0.isFinite}) else { throw LabError.bounds }
        return Result(pcm:pcm,elapsed:elapsed,cpu:c1-c0,initNS:initNS,drainNS:drainNS,tail:tail,maxDelay:maxDelay,calls:calls)
    }
    private func run(_ inRate:Int32,_ outRate:Int32,_ ch:Int,planar:Bool=false,integer:Bool=false) throws {
        let frames=Int(inRate)
        var signal=[Float](repeating:0,count:frames*ch)
        for f in 0..<frames {
            for c in 0..<ch {
                let x=Float(0.4*sin(2*Double.pi*Double(997+43*c)*Double(f)/Double(inRate)))
                signal[f*ch+c]=c==ch-1 ? 0 : x
            }
        }
        let ints=integer ? signal.map{Int16(($0*32768).rounded())} : []
        let ordered=planar ? (0..<ch).flatMap{ c in (0..<frames).map{signal[$0*ch+c]} } : signal
        let bytes=integer ? ints.withUnsafeBytes{Array($0)} : ordered.withUnsafeBytes{Array($0)}
        let label="in=\(inRate) out=\(outRate) channels=\(ch) planar=\(planar) integer=\(integer)"
        print("G0_4B6_PROCESS pid=\(getpid()) \(label)")
        let reference=try convert(bytes,inRate:inRate,outRate:outRate,ch:ch,planar:planar,integer:integer,block:1024)
        let refHash=hash(reference.pcm)
        for block in [256,1024,4096] {
            let control=try convert(bytes,inRate:inRate,outRate:outRate,ch:ch,planar:planar,integer:integer,block:block)
            XCTAssertEqual(control.pcm.count,reference.pcm.count)
            let partition=zip(control.pcm,reference.pcm).reduce(0.0){max($0,abs(Double($1.0)-Double($1.1)))}
            XCTAssertLessThanOrEqual(partition,1e-6)
            let silent=stride(from:ch-1,to:control.pcm.count,by:ch).reduce(0.0){max($0,abs(Double(control.pcm[$1])))}
            XCTAssertEqual(silent,0)
            let outputFrames=control.pcm.count/ch
            if inRate==outRate {
                let expected=integer ? ints.map{Float($0)/32768} : signal
                XCTAssertEqual(hash(control.pcm),hash(expected))
            }
            let digest=hash(control.pcm)
            print("G0_4B6_CONTROL \(label) block=\(block) frames=\(outputFrames) hash=\(digest) referenceHash=\(refHash) partition=\(partition) silent=\(silent) tail=\(control.tail) maxDelay=\(control.maxDelay) calls=\(control.calls)")
            var elapsed=[UInt64](), cpus=[Int64](), inits=[UInt64](), drains=[UInt64]()
            for index in -1...10 {
                let r=try convert(bytes,inRate:inRate,outRate:outRate,ch:ch,planar:planar,integer:integer,block:block)
                XCTAssertEqual(hash(r.pcm),digest)
                XCTAssertEqual(r.tail,control.tail)
                if index>0 { elapsed.append(r.elapsed);cpus.append(r.cpu);inits.append(r.initNS);drains.append(r.drainNS) }
                print("G0_4B6_CASE \(label) block=\(block) index=\(index) elapsedNS=\(r.elapsed) cpuUS=\(r.cpu) initNS=\(r.initNS) drainNS=\(r.drainNS)")
            }
            print("G0_4B6_STATS \(label) block=\(block) n=10 p50NS=\(elapsed.sorted()[4]) p95NS=\(elapsed.sorted()[9]) cpuP50US=\(cpus.sorted()[4]) initP50NS=\(inits.sorted()[4]) drainP50NS=\(drains.sorted()[4])")
        }
        print("G0_4B6_SUMMARY controls=3 measured=30 warmups=6")
    }
    func test48S16Stereo()throws{try run(48000,48000,2,integer:true)}
    func test96PlanarEight()throws{try run(96000,96000,8,planar:true)}
    func test44To48Stereo()throws{try run(44100,48000,2)}
    func test48To96Six()throws{try run(48000,96000,6,planar:true)}
    func test96To48Eight()throws{try run(96000,48000,8)}
    func test192To48Stereo()throws{try run(192000,48000,2)}
}
