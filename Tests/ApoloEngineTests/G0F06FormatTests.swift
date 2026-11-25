import AetherLibavutil
import Foundation
import XCTest
@testable import ApoloEngine

final class G0F06FormatTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func rounded(_ n:Int,_ a:Int)->Int{((n+a-1)/a)*a}
    private func describe(_ layout:inout AVChannelLayout)->String{
        var chars=[CChar](repeating:0,count:256)
        let r=chars.withUnsafeMutableBufferPointer{av_channel_layout_describe(&layout,$0.baseAddress,$0.count)}
        return r>=0 ? chars.withUnsafeBufferPointer{String(cString:$0.baseAddress!)}:"error"
    }
    func testG0F06CFormatsAndLayouts()throws{
        let formats:[(String,AVSampleFormat,AVSampleFormat,Int)]=[
            ("u8",AV_SAMPLE_FMT_U8,AV_SAMPLE_FMT_U8P,1),
            ("s16",AV_SAMPLE_FMT_S16,AV_SAMPLE_FMT_S16P,2),
            ("s32",AV_SAMPLE_FMT_S32,AV_SAMPLE_FMT_S32P,4),
            ("s64",AV_SAMPLE_FMT_S64,AV_SAMPLE_FMT_S64P,8),
            ("flt",AV_SAMPLE_FMT_FLT,AV_SAMPLE_FMT_FLTP,4),
            ("dbl",AV_SAMPLE_FMT_DBL,AV_SAMPLE_FMT_DBLP,8)
        ]
        var metadata=0,metadataExact=0,sizes=0,sizeExact=0,payloads=0,payloadExact=0,compared=0,invalid=0,invalidExact=0
        for (name,packed,planar,bps) in formats{
            for (fmt,isPlanar) in [(packed,false),(planar,true)]{
                metadata+=1
                let expectedName=name+(isPlanar ? "p":"")
                let actualName=av_get_sample_fmt_name(fmt).map{String(cString:$0)} ?? "nil"
                let meta=actualName==expectedName && av_get_sample_fmt(expectedName)==fmt
                    && av_get_bytes_per_sample(fmt)==Int32(bps)
                    && av_sample_fmt_is_planar(fmt)==(isPlanar ? 1:0)
                    && av_get_packed_sample_fmt(fmt)==packed && av_get_planar_sample_fmt(fmt)==planar
                if meta{metadataExact+=1}
                print("G0_F06C_FORMAT name=\(expectedName) actual=\(actualName) bps=\(bps) planar=\(isPlanar) exact=\(meta)")
                for ch in [1,2,3,6,8,12]{
                    for n in [1,31,32,33,257,1024]{
                        for align in [0,1,16,32,64]{
                            sizes+=1
                            let frames=align==0 ? rounded(n,32):n
                            let block=bps*(isPlanar ? 1:ch)
                            let line=rounded(frames*block,max(1,align))
                            let planes=isPlanar ? ch:1
                            var actualLine:Int32=0
                            let actual=av_samples_get_buffer_size(&actualLine,Int32(ch),Int32(n),fmt,Int32(align))
                            let ok=actual==Int32(line*planes) && actualLine==Int32(line)
                            if ok{sizeExact+=1}else{print("G0_F06C_MISMATCH kind=size fmt=\(expectedName) ch=\(ch) n=\(n) align=\(align) actual=\(actual) line=\(actualLine) expected=\(line*planes) expectedLine=\(line)")}
                        }
                    }
                    // Own all planes; never inspect unspecified padding.
                    for align in [1,32,64]{
                        payloads+=1
                        let n=257,planes=isPlanar ? ch:1,block=bps*(isPlanar ? 1:ch)
                        var a=[UnsafeMutablePointer<UInt8>?](repeating:nil,count:planes)
                        var b=[UnsafeMutablePointer<UInt8>?](repeating:nil,count:planes)
                        defer{if let p=a[0]{av_free(p)};if let p=b[0]{av_free(p)}}
                        var la:Int32=0,lb:Int32=0
                        let ra=a.withUnsafeMutableBufferPointer{av_samples_alloc($0.baseAddress,&la,Int32(ch),Int32(n),fmt,Int32(align))}
                        let rb=b.withUnsafeMutableBufferPointer{av_samples_alloc($0.baseAddress,&lb,Int32(ch),Int32(n),fmt,Int32(align))}
                        guard ra>=0,rb>=0 else{XCTFail("allocation failed");continue}
                        let silence:UInt8=name=="u8" ? 128:0
                        var initial=true,offsets=true,copy=true,overlap=true,partial=true
                        for plane in 0..<planes{
                            let x=try XCTUnwrap(a[plane]),y=try XCTUnwrap(b[plane])
                            let base=try XCTUnwrap(a[0])
                            if Int(bitPattern:x)-Int(bitPattern:base) != plane*Int(la){offsets=false}
                            for i in 0..<(n*block){
                                if x[i] != silence || y[i] != silence{initial=false}
                                x[i]=UInt8(truncatingIfNeeded:i*37+plane*13)
                                compared+=2
                            }
                        }
                        let c=b.withUnsafeMutableBufferPointer{dst in a.withUnsafeMutableBufferPointer{src in av_samples_copy(dst.baseAddress,src.baseAddress,7,3,127,Int32(ch),fmt)}}
                        for plane in 0..<planes{
                            let y=try XCTUnwrap(b[plane])
                            for i in 0..<(n*block){
                                let expected:UInt8=(i>=7*block && i<134*block) ? UInt8(truncatingIfNeeded:(i-4*block)*37+plane*13):silence
                                if y[i] != expected{copy=false}
                                compared+=1
                            }
                        }
                        let ov=a.withUnsafeMutableBufferPointer{ptr in av_samples_copy(ptr.baseAddress,ptr.baseAddress,5,0,127,Int32(ch),fmt)}
                        let sl=a.withUnsafeMutableBufferPointer{av_samples_set_silence($0.baseAddress,17,11,Int32(ch),fmt)}
                        for plane in 0..<planes{
                            let x=try XCTUnwrap(a[plane])
                            for i in 0..<(n*block){
                                let source=(i>=5*block && i<132*block) ? i-5*block:i
                                let expected:UInt8=(i>=17*block && i<28*block) ? silence:UInt8(truncatingIfNeeded:source*37+plane*13)
                                if x[i] != expected{if i>=17*block && i<28*block{partial=false}else{overlap=false}}
                                compared+=1
                            }
                        }
                        let ok=initial && offsets && copy && overlap && partial && c==0 && ov==0 && sl==0 && la==lb && ra==rb
                        if ok{payloadExact+=1}
                        print("G0_F06C_PAYLOAD format=\(expectedName) channels=\(ch) align=\(align) line=\(la) bytes=\(ra) initial=\(initial) offsets=\(offsets) copy=\(copy) overlap=\(overlap) partial=\(partial) exact=\(ok)")
                    }
                }
                for (ch,n) in [(0,1),(1,0),(-1,10),(8,Int(Int32.max))]{
                    invalid+=1
                    let v=av_samples_get_buffer_size(nil,Int32(ch),Int32(n),fmt,32)
                    if v<0{invalidExact+=1}
                    print("G0_F06C_INVALID format=\(expectedName) channels=\(ch) frames=\(n) code=\(v)")
                }
            }
        }
        // Explicit named native layouts, channel identities in mask order.
        let layouts:[(String,[AVChannel])]=[
            ("mono",[AV_CHAN_FRONT_CENTER]),("stereo",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT]),
            ("2.1",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_LOW_FREQUENCY]),
            ("3.0",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER]),
            ("quad",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_BACK_LEFT,AV_CHAN_BACK_RIGHT]),
            ("4.0",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_BACK_CENTER]),
            ("5.0",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_BACK_LEFT,AV_CHAN_BACK_RIGHT]),
            ("5.0(side)",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_SIDE_LEFT,AV_CHAN_SIDE_RIGHT]),
            ("5.1",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_BACK_LEFT,AV_CHAN_BACK_RIGHT]),
            ("5.1(side)",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_SIDE_LEFT,AV_CHAN_SIDE_RIGHT]),
            ("6.1",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_BACK_CENTER,AV_CHAN_SIDE_LEFT,AV_CHAN_SIDE_RIGHT]),
            ("6.1(back)",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_BACK_LEFT,AV_CHAN_BACK_RIGHT,AV_CHAN_BACK_CENTER]),
            ("7.1",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_BACK_LEFT,AV_CHAN_BACK_RIGHT,AV_CHAN_SIDE_LEFT,AV_CHAN_SIDE_RIGHT]),
            ("7.1(wide)",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_BACK_LEFT,AV_CHAN_BACK_RIGHT,AV_CHAN_FRONT_LEFT_OF_CENTER,AV_CHAN_FRONT_RIGHT_OF_CENTER]),
            ("5.1.2",[AV_CHAN_FRONT_LEFT,AV_CHAN_FRONT_RIGHT,AV_CHAN_FRONT_CENTER,AV_CHAN_LOW_FREQUENCY,AV_CHAN_SIDE_LEFT,AV_CHAN_SIDE_RIGHT,AV_CHAN_TOP_FRONT_LEFT,AV_CHAN_TOP_FRONT_RIGHT])
        ]
        var layoutExact=0,layoutCount=0
        for (name,ids) in layouts{
            layoutCount+=1
            var a=AVChannelLayout(),b=AVChannelLayout(),c=AVChannelLayout()
            defer{av_channel_layout_uninit(&a);av_channel_layout_uninit(&b);av_channel_layout_uninit(&c)}
            let code=av_channel_layout_from_string(&a,name)
            guard code==0 else{XCTFail("layout parse \(name)");continue}
            let desc=describe(&a)
            let parsed=av_channel_layout_from_string(&b,desc)
            let cloned=av_channel_layout_copy(&c,&a)
            var exact=a.nb_channels==Int32(ids.count) && av_channel_layout_check(&a)==1
            for (i,id) in ids.enumerated(){
                if av_channel_layout_channel_from_index(&a,UInt32(i)) != id || av_channel_layout_index_from_channel(&a,id) != Int32(i){exact=false}
            }
            let roundtrip=parsed==0 && av_channel_layout_compare(&a,&b)==0
            av_channel_layout_uninit(&a)
            let survives=cloned==0 && av_channel_layout_compare(&b,&c)==0
            let ok=exact && roundtrip && survives
            if ok{layoutExact+=1}
            print("G0_F06C_LAYOUT name=\(name) desc=\(desc) channels=\(ids.count) identities=\(exact) roundtrip=\(roundtrip) survives=\(survives) exact=\(ok)")
        }
        for ch in 1...12{
            var standard=AVChannelLayout(),engine=AVChannelLayout()
            defer{av_channel_layout_uninit(&standard);av_channel_layout_uninit(&engine)}
            av_channel_layout_default(&standard,Int32(ch))
            AudioDecoder.makeResamplerOutputLayout(channels:Int32(ch),into:&engine)
            print("G0_F06C_DEFAULT channels=\(ch) standard=\(describe(&standard)) engine=\(describe(&engine)) equal=\(av_channel_layout_compare(&standard,&engine)==0) valid=\(av_channel_layout_check(&engine))")
        }
        print("G0_F06C_SUMMARY metadata=\(metadata) metadataExact=\(metadataExact) sizes=\(sizes) sizeExact=\(sizeExact) payloads=\(payloads) payloadExact=\(payloadExact) comparedBytes=\(compared) invalid=\(invalid) invalidExact=\(invalidExact) layouts=\(layoutCount) layoutExact=\(layoutExact)")
        XCTAssertEqual(metadataExact,12)
        XCTAssertEqual(sizeExact,2160)
        XCTAssertEqual(payloadExact,216)
        XCTAssertEqual(invalidExact,48)
        XCTAssertEqual(layoutExact,15)
    }
}
