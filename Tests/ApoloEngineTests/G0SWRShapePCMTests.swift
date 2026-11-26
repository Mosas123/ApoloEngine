import Foundation
import Darwin
import CryptoKit
import XCTest
import AetherLibavutil
import AetherLibswresample
@testable import ApoloEngine

/// Synthetic AVFrames with owned FFmpeg storage. Never send a changed
/// signature to an old SWR. Compare native per-phase and fixed-output policies.
final class G0SWRShapePCMTests:XCTestCase{
    private enum LabError:Error{case invalid(String)}
    private struct Spec{
        let mask:UInt64
        let fmt:AVSampleFormat
        var key:String{"\(mask):\(fmt.rawValue)"}
    }
    private let n=257
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ pcm:[Float])->String{
        let bits=pcm.map{$0.bitPattern.littleEndian}
        return bits.withUnsafeBytes{SHA256.hash(data:Data($0))}.map{String(format:"%02x",$0)}.joined()
    }
    private func layout(_ mask:UInt64)throws->AVChannelLayout{
        var l=AVChannelLayout()
        guard av_channel_layout_from_mask(&l,mask)>=0,l.nb_channels>0,l.nb_channels<=8 else{throw LabError.invalid("layout")}
        return l
    }
    private func names(_ l:inout AVChannelLayout)->String{
        (0..<Int(l.nb_channels)).map{String(av_channel_layout_channel_from_index(&l,UInt32($0)).rawValue)}.joined(separator:",")
    }
    private func signal(_ ch:Int,_ phase:Int)->[Float]{
        (0..<n).flatMap{i in (0..<ch).map{c in
            // First ch frames: one isolated impulse per input channel.
            if i<ch{return i==c ? Float(0.25):0}
            if c==ch-1{return 0}
            return Float(((i*7+c*13+phase*17)%127)-63)/256
        }}
    }
    private func withFrame<T>(_ s:Spec,_ phase:Int,_ body:(UnsafeMutablePointer<AVFrame>,[Float])throws->T)throws->T{
        var owner=av_frame_alloc()
        defer{av_frame_free(&owner)}
        let f=try XCTUnwrap(owner)
        f.pointee.sample_rate=48000
        f.pointee.format=s.fmt.rawValue
        f.pointee.nb_samples=Int32(n)
        guard av_channel_layout_from_mask(&f.pointee.ch_layout,s.mask)>=0,
              av_frame_get_buffer(f,32)>=0,let planes=f.pointee.extended_data else{throw LabError.invalid("frame allocation")}
        let ch=Int(f.pointee.ch_layout.nb_channels),width=Int(av_get_bytes_per_sample(s.fmt))
        let planar=av_sample_fmt_is_planar(s.fmt) != 0
        let values=signal(ch,phase)
        guard width>0,ch>0,ch<=8,(0..<(planar ? ch:1)).allSatisfy({planes[$0] != nil}) else{throw LabError.invalid("planes")}
        for i in 0..<n{
            for c in 0..<ch{
                let x=values[i*ch+c]
                let p=UnsafeMutableRawPointer(planes[planar ? c:0]!)
                let off=(planar ? i:i*ch+c)*width
                switch s.fmt{
                case AV_SAMPLE_FMT_S16,AV_SAMPLE_FMT_S16P:p.storeBytes(of:Int16(x*32768),toByteOffset:off,as:Int16.self)
                case AV_SAMPLE_FMT_S32,AV_SAMPLE_FMT_S32P:p.storeBytes(of:Int32(Double(x)*2147483648),toByteOffset:off,as:Int32.self)
                case AV_SAMPLE_FMT_FLT,AV_SAMPLE_FMT_FLTP:p.storeBytes(of:x,toByteOffset:off,as:Float.self)
                case AV_SAMPLE_FMT_DBL,AV_SAMPLE_FMT_DBLP:p.storeBytes(of:Double(x),toByteOffset:off,as:Double.self)
                default:throw LabError.invalid("format")
                }
            }
        }
        return try body(f,values)
    }
    private func initContext(_ context:inout OpaquePointer?,frame:UnsafeMutablePointer<AVFrame>,outMask:UInt64)throws{
        var out=try layout(outMask)
        defer{av_channel_layout_uninit(&out)}
        let fmt=AVSampleFormat(rawValue:frame.pointee.format)
        guard swr_alloc_set_opts2(&context,&out,AV_SAMPLE_FMT_FLT,48000,&frame.pointee.ch_layout,fmt,48000,0,nil)>=0,
              let c=context,swr_init(c)>=0 else{throw LabError.invalid("SWR init")}
    }
    private func convert(_ context:OpaquePointer,_ f:UnsafeMutablePointer<AVFrame>,outCh:Int,block:Int)throws->[Float]{
        let fmt=AVSampleFormat(rawValue:f.pointee.format),width=Int(av_get_bytes_per_sample(fmt))
        let planar=av_sample_fmt_is_planar(fmt) != 0,ch=Int(f.pointee.ch_layout.nb_channels)
        let planes=try XCTUnwrap(f.pointee.extended_data)
        var ptrs=[UnsafePointer<UInt8>?](repeating:nil,count:planar ? ch:1)
        var output=[Float](),cursor=0
        while cursor<n{
            let count=min(block,n-cursor)
            for p in ptrs.indices{ptrs[p]=UnsafePointer(planes[p]!.advanced(by:cursor*width*(planar ? 1:ch)))}
            var dst=[Float](repeating:0,count:(count+64)*outCh)
            let got=dst.withUnsafeMutableBytes{raw -> Int32 in
                var out:UnsafeMutablePointer<UInt8>?=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
                return ptrs.withUnsafeBufferPointer{src in
                    withUnsafeMutablePointer(to:&out){swr_convert(context,$0,Int32(count+64),src.baseAddress,Int32(count))}
                }
            }
            guard got>=0,got<=Int32(count+64) else{throw LabError.invalid("convert")}
            output.append(contentsOf:dst.prefix(Int(got)*outCh));cursor+=count
        }
        return output
    }
    private func flush(_ c:OpaquePointer,outCh:Int)throws->[Float]{
        var result=[Float]()
        for _ in 0..<32{
            var dst=[Float](repeating:0,count:256*outCh)
            let got=dst.withUnsafeMutableBytes{raw -> Int32 in
                var out:UnsafeMutablePointer<UInt8>?=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
                return withUnsafeMutablePointer(to:&out){swr_convert(c,$0,256,nil,0)}
            }
            guard got>=0,got<=256 else{throw LabError.invalid("flush")}
            result.append(contentsOf:dst.prefix(Int(got)*outCh))
            if got==0{return result}
        }
        throw LabError.invalid("flush bound")
    }
    private func run(_ name:String,_ specs:[Spec])throws{
        print("G0_4B84_PROCESS pid=\(getpid()) scenario=\(name)")
        for fixed in [false,true]{
            var context:OpaquePointer?
            defer{swr_free(&context)}
            var oldKey:String?
            for (phase,s) in specs.enumerated(){
                let outMask=fixed ? specs[0].mask:s.mask
                var output=try layout(outMask)
                defer{av_channel_layout_uninit(&output)}
                let outCh=Int(output.nb_channels)
                let outIDs=names(&output)
                try withFrame(s,phase){f,expected in
                    let key="\(s.key):\(outMask)"
                    if let oldKey{XCTAssertNotEqual(key,oldKey)}
                    if let c=context{
                        // Old phase already fully drained; verify no residual.
                        XCTAssertTrue(try flush(c,outCh:outCh).isEmpty)
                        swr_free(&context)
                    }
                    try initContext(&context,frame:f,outMask:outMask)
                    oldKey=key
                    let c=try XCTUnwrap(context)
                    var pcm=try convert(c,f,outCh:outCh,block:31)
                    let tail=try flush(c,outCh:outCh)
                    pcm.append(contentsOf:tail)
                    var fresh:OpaquePointer?
                    defer{swr_free(&fresh)}
                    try initContext(&fresh,frame:f,outMask:outMask)
                    let ref=try XCTUnwrap(fresh)
                    var reference=try convert(ref,f,outCh:outCh,block:n)
                    reference.append(contentsOf:try flush(ref,outCh:outCh))
                    XCTAssertEqual(pcm.count,n*outCh)
                    XCTAssertEqual(pcm.count,reference.count)
                    XCTAssertTrue(pcm.allSatisfy{$0.isFinite})
                    XCTAssertTrue(tail.isEmpty)
                    let delta=zip(pcm,reference).reduce(0.0){max($0,abs(Double($1.0)-Double($1.1)))}
                    XCTAssertLessThanOrEqual(delta,1e-6)
                    let identity=s.mask==outMask
                    let exact=hash(pcm)==hash(expected)
                    if identity{XCTAssertTrue(exact,"identity conversion")}
                    // Impulse rows record where each input semantic channel
                    // goes under default SWR rematrix; no spatial assertion.
                    let inCh=Int(f.pointee.ch_layout.nb_channels)
                    let inIDs=names(&f.pointee.ch_layout)
                    let matrix=(0..<inCh).map{i in
                        (0..<outCh).map{j in String(format:"%.8f",Double(pcm[i*outCh+j])*4)}.joined(separator:",")
                    }.joined(separator:";")
                    print("G0_4B84_CONTROL scenario=\(name) policy=\(fixed ? "fixed":"native") phase=\(phase) fmt=\(s.fmt.rawValue) inIDs=\(inIDs) outIDs=\(outIDs) frames=\(pcm.count/outCh) hash=\(hash(pcm)) freshHash=\(hash(reference)) delta=\(delta) identity=\(identity) exactIdentity=\(exact) tail=\(tail.count/outCh) matrix=\(matrix)")
                }
            }
        }
        print("G0_4B84_SUMMARY controls=6")
    }
    func testPacking()throws{try run("Packing",[Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:3,fmt:AV_SAMPLE_FMT_FLT),Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP)])}
    func testS16()throws{try run("S16",[Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:3,fmt:AV_SAMPLE_FMT_S16P),Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP)])}
    func testS32()throws{try run("S32",[Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:3,fmt:AV_SAMPLE_FMT_S32),Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP)])}
    func testDouble()throws{try run("Double",[Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:3,fmt:AV_SAMPLE_FMT_DBLP),Spec(mask:3,fmt:AV_SAMPLE_FMT_FLTP)])}
    func testLayout()throws{try run("Layout",[Spec(mask:0x3f,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:0x60f,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:0x3f,fmt:AV_SAMPLE_FMT_FLTP)])}
    func testMixed()throws{try run("Mixed",[Spec(mask:0x60f,fmt:AV_SAMPLE_FMT_FLTP),Spec(mask:0x3f,fmt:AV_SAMPLE_FMT_S32P),Spec(mask:0x60f,fmt:AV_SAMPLE_FMT_FLTP)])}
}
