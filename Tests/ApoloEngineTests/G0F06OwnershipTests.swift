import AetherLibavutil
import Foundation
import XCTest

private let g0BufferRelease: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?) -> Void = { opaque, data in
    if let opaque {
        opaque.assumingMemoryBound(to: Int32.self).pointee += 1
    }
    if let data { av_free(data) }
}

/// F06B.1: reference lifetimes, writable copies and exact payloads.
/// No deliberately invalid pointers or concurrent frees.
final class G0F06OwnershipTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }
    private func byte(_ i:Int,_ seed:Int)->UInt8 { UInt8(truncatingIfNeeded:i &* 37 &+ seed &* 19) }
    private func matches(_ p:UnsafePointer<UInt8>?,_ n:Int,_ seed:Int)->Bool {
        guard let p else{return false}
        for i in 0..<n{if p[i] != byte(i,seed){return false}}
        return true
    }
    func testG0F06B1Ownership()throws{
        var attempted=0,observed=0,passed=0,bytes=0
        for n in [1,7,31,257,4096,32768,65537,1048576]{
            for order in 0..<3{
                attempted+=1
                let releases=UnsafeMutablePointer<Int32>.allocate(capacity:1)
                releases.initialize(to:0)
                defer{releases.deinitialize(count:1);releases.deallocate()}
                let raw=try XCTUnwrap(av_malloc(n))
                let data=raw.assumingMemoryBound(to:UInt8.self)
                for i in 0..<n{data[i]=byte(i,order)}
                var a=av_buffer_create(data,n,g0BufferRelease,UnsafeMutableRawPointer(releases),0)
                // Ownership of data transfers only on success.
                if a==nil{av_free(raw);XCTFail("buffer create");continue}
                defer{av_buffer_unref(&a)}
                var b=av_buffer_ref(a)
                defer{av_buffer_unref(&b)}
                var c=av_buffer_ref(a)
                defer{av_buffer_unref(&c)}
                let aa=try XCTUnwrap(a),bb=try XCTUnwrap(b),cc=try XCTUnwrap(c)
                let initial=av_buffer_get_ref_count(aa)==3 && av_buffer_is_writable(aa)==0
                    && aa.pointee.data==bb.pointee.data && aa.pointee.data==cc.pointee.data
                let copy=av_buffer_make_writable(&b)
                let writable=try XCTUnwrap(b)
                let preserved=matches(writable.pointee.data,n,order)
                let separate=writable.pointee.data != aa.pointee.data && av_buffer_get_ref_count(aa)==2
                    && av_buffer_get_ref_count(writable)==1 && av_buffer_is_writable(writable)==1
                writable.pointee.data[0] ^= 0xff
                let isolated=matches(aa.pointee.data,n,order) && matches(cc.pointee.data,n,order)
                var early:Int32=0,final:Int32=0,remaining=false
                if order==0{
                    av_buffer_unref(&a);early=releases.pointee
                    remaining=matches(c?.pointee.data,n,order)
                    av_buffer_unref(&c);final=releases.pointee
                    av_buffer_unref(&b)
                }else if order==1{
                    av_buffer_unref(&c);early=releases.pointee
                    remaining=matches(a?.pointee.data,n,order)
                    av_buffer_unref(&a);final=releases.pointee
                    av_buffer_unref(&b)
                }else{
                    av_buffer_unref(&b);early=releases.pointee
                    av_buffer_unref(&a);remaining=matches(c?.pointee.data,n,order)
                    av_buffer_unref(&c);final=releases.pointee
                }
                av_buffer_unref(&a);av_buffer_unref(&b);av_buffer_unref(&c)
                let ok=initial && copy==0 && preserved && separate && isolated && remaining && early==0 && final==1
                    && releases.pointee==1 && a==nil && b==nil && c==nil
                observed+=1;if ok{passed+=1};bytes+=n*4
                print("G0_F06B1_BUFFER size=\(n) order=\(order) initial=\(initial) copyCode=\(copy) preserved=\(preserved) separate=\(separate) isolated=\(isolated) remaining=\(remaining) earlyRelease=\(early) finalRelease=\(final) exact=\(ok)")
            }
        }
        var frameCount=0,frameExact=0,frameValues=0
        for rate in [44100,48000,96000,192000]{
            for channels in [1,2,6,8]{
                for planar in [false,true]{
                    attempted+=1;frameCount+=1
                    var a=av_frame_alloc()
                    defer{av_frame_free(&a)}
                    let src=try XCTUnwrap(a)
                    src.pointee.format=Int32((planar ? AV_SAMPLE_FMT_FLTP : AV_SAMPLE_FMT_FLT).rawValue)
                    src.pointee.sample_rate=Int32(rate)
                    src.pointee.nb_samples=257
                    src.pointee.pts=12345
                    av_channel_layout_default(&src.pointee.ch_layout,Int32(channels))
                    guard av_frame_get_buffer(src,0)==0 else{XCTFail("frame buffer");continue}
                    let planes=planar ? channels:1
                    let count=planar ? 257:257*channels
                    guard let ext=src.pointee.extended_data else{XCTFail("extended data");continue}
                    for p in 0..<planes{
                        let raw=try XCTUnwrap(ext[p])
                        let samples=UnsafeMutableRawPointer(raw).assumingMemoryBound(to:Float.self)
                        for i in 0..<count{samples[i]=Float((i+p*17)%127-63)/64}
                    }
                    var b=av_frame_clone(src)
                    defer{av_frame_free(&b)}
                    let clone=try XCTUnwrap(b)
                    let shared=av_frame_is_writable(src)==0 && av_frame_is_writable(clone)==0
                    let code=av_frame_make_writable(clone)
                    guard code==0,let dst=clone.pointee.extended_data else{XCTFail("frame writable");continue}
                    var payload=true,distinct=true
                    for p in 0..<planes{
                        let x=try XCTUnwrap(ext[p]),y=try XCTUnwrap(dst[p])
                        if x==y{distinct=false}
                        let sx=UnsafeMutableRawPointer(x).assumingMemoryBound(to:Float.self)
                        let sy=UnsafeMutableRawPointer(y).assumingMemoryBound(to:Float.self)
                        for i in 0..<count{if sx[i].bitPattern != sy[i].bitPattern{payload=false}}
                        sy[0]=0.75
                        if sx[0].bitPattern != (Float((p*17)%127-63)/64).bitPattern{payload=false}
                    }
                    let meta=clone.pointee.pts==12345 && clone.pointee.nb_samples==257
                        && clone.pointee.sample_rate==Int32(rate) && clone.pointee.format==src.pointee.format
                        && av_channel_layout_compare(&src.pointee.ch_layout,&clone.pointee.ch_layout)==0
                    av_frame_unref(src)
                    let reset=src.pointee.nb_samples==0
                    var surviving=true
                    for p in 0..<planes{
                        let y=try XCTUnwrap(dst[p])
                        let sy=UnsafeMutableRawPointer(y).assumingMemoryBound(to:Float.self)
                        for i in 0..<count{
                            let expected:Float=i==0 ? 0.75:Float((i+p*17)%127-63)/64
                            if sy[i].bitPattern != expected.bitPattern{surviving=false}
                        }
                    }
                    av_frame_free(&a);av_frame_free(&b);av_frame_free(&a);av_frame_free(&b)
                    let ok=shared && distinct && payload && meta && reset && surviving && a==nil && b==nil
                    observed+=1;if ok{passed+=1;frameExact+=1};frameValues+=257*channels*2
                    print("G0_F06B1_FRAME rate=\(rate) channels=\(channels) planar=\(planar) shared=\(shared) distinct=\(distinct) payload=\(payload) meta=\(meta) reset=\(reset) surviving=\(surviving) exact=\(ok)")
                }
            }
        }
        print("G0_F06B1_SUMMARY attempted=\(attempted) observed=\(observed) passed=\(passed) bufferBytes=\(bytes) frameCount=\(frameCount) frameExact=\(frameExact) frameValues=\(frameValues)")
        XCTAssertEqual(attempted,56)
        XCTAssertEqual(observed,56)
        XCTAssertEqual(passed,56)
    }
}
