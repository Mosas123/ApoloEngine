import AetherLibswscale
import AetherLibavutil
import Foundation
import XCTest

/// Video primitives in the shipped library, not a playback feature of Thrum.
final class G0F07ScaleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ bytes:[UInt8])->String{
        var h:UInt64=14695981039346656037
        for b in bytes{h=(h ^ UInt64(b)) &* 1099511628211}
        return String(h,radix:16)
    }
    // Packed RGB24, with owned row padding. Independent nearest-neighbor
    // oracle only for exact integer enlargement and identity.
    private func scale(_ src:[UInt8],w:Int,h:Int,dw:Int,dh:Int,flags:Int32)throws->[UInt8]{
        let srcStride=w*3+64,dstStride=dw*3+64
        var input=[UInt8](repeating:0,count:srcStride*h+64)
        var output=[UInt8](repeating:0,count:dstStride*dh+64)
        for y in 0..<h{for x in 0..<(w*3){input[y*srcStride+x]=src[y*w*3+x]}}
        let ctx=try XCTUnwrap(sws_getContext(Int32(w),Int32(h),AV_PIX_FMT_RGB24,Int32(dw),Int32(dh),AV_PIX_FMT_RGB24,flags,nil,nil,nil))
        defer{sws_freeContext(ctx)}
        let lines=input.withUnsafeBufferPointer{sp in output.withUnsafeMutableBufferPointer{dp in
            var sources:[UnsafePointer<UInt8>?]=[sp.baseAddress,nil,nil,nil]
            var destinations:[UnsafeMutablePointer<UInt8>?]=[dp.baseAddress,nil,nil,nil]
            let ss:[Int32]=[Int32(srcStride),0,0,0],ds:[Int32]=[Int32(dstStride),0,0,0]
            return sources.withUnsafeMutableBufferPointer{s in destinations.withUnsafeMutableBufferPointer{d in ss.withUnsafeBufferPointer{sl in ds.withUnsafeBufferPointer{dl in
                sws_scale(ctx,s.baseAddress,sl.baseAddress,0,Int32(h),d.baseAddress,dl.baseAddress)
            }}}}
        }}
        XCTAssertEqual(lines,Int32(dh))
        var result=[UInt8]();result.reserveCapacity(dw*dh*3)
        for y in 0..<dh{result.append(contentsOf:output[(y*dstStride)..<(y*dstStride+dw*3)])}
        return result
    }
    func testG0F07AScale()throws{
        let formats:[(String,AVPixelFormat)]=[
            ("rgb24",AV_PIX_FMT_RGB24),("bgr24",AV_PIX_FMT_BGR24),("yuv420p",AV_PIX_FMT_YUV420P),
            ("yuv422p",AV_PIX_FMT_YUV422P),("yuv444p",AV_PIX_FMT_YUV444P),("nv12",AV_PIX_FMT_NV12),
            ("yuv420p10le",AV_PIX_FMT_YUV420P10LE),("p010le",AV_PIX_FMT_P010LE),("rgba",AV_PIX_FMT_RGBA),
            ("gray8",AV_PIX_FMT_GRAY8)
        ]
        print("G0_F07A_VERSION swscale=\(swscale_version())")
        for (name,fmt) in formats{
            print("G0_F07A_FORMAT name=\(name) input=\(sws_isSupportedInput(fmt)) output=\(sws_isSupportedOutput(fmt))")
        }
        var profiles=0,oracleProfiles=0,oracleExact=0,compared=0,constantProfiles=0,constantExact=0
        let algorithms:[(String,Int32)]=[("point",Int32(truncatingIfNeeded: SWS_POINT.rawValue)),("bilinear",Int32(truncatingIfNeeded: SWS_BILINEAR.rawValue)),("bicubic",Int32(truncatingIfNeeded: SWS_BICUBIC.rawValue)),("lanczos",Int32(truncatingIfNeeded: SWS_LANCZOS.rawValue))]
        for (w,h) in [(16,12),(31,19),(64,48)]{
            for (dw,dh) in [(w,h),(w*2,h*2),(w*3,h*3),(max(1,w/2),max(1,h/2))]{
                for (name,flags) in algorithms{
                    for constant in [false,true]{
                        profiles+=1
                        var src=[UInt8](repeating:0,count:w*h*3)
                        for y in 0..<h{for x in 0..<w{for c in 0..<3{
                            src[(y*w+x)*3+c]=constant ? [UInt8(37),109,213][c]:UInt8(truncatingIfNeeded:x*17+y*31+c*67)
                        }}}
                        let actual=try scale(src,w:w,h:h,dw:dw,dh:dh,flags:flags)
                        var maxError=0,exactCount=0
                        let oracle=(dw==w && dh==h) || (name=="point" && dw>=w && dh>=h)
                        if oracle || constant{
                            if oracle{oracleProfiles+=1}
                            if constant{constantProfiles+=1}
                            for y in 0..<dh{for x in 0..<dw{for c in 0..<3{
                                let ex=constant ? [UInt8(37),109,213][c]:src[((y*h/dh)*w+x*w/dw)*3+c]
                                let error=abs(Int(actual[(y*dw+x)*3+c])-Int(ex))
                                maxError=max(maxError,error)
                                if error==0{exactCount+=1}
                                compared+=1
                            }}}
                            if oracle && maxError==0{oracleExact+=1}
                            if constant && maxError==0{constantExact+=1}
                        }
                        print("G0_F07A_SCALE src=\(w)x\(h) dst=\(dw)x\(dh) algorithm=\(name) constant=\(constant) oracle=\(oracle || constant) compared=\((oracle || constant) ? actual.count:0) exact=\(exactCount) maxError=\(maxError) hash=\(hash(actual))")
                    }
                }
            }
        }
        print("G0_F07A_SUMMARY profiles=\(profiles) oracleProfiles=\(oracleProfiles) oracleExact=\(oracleExact) constantProfiles=\(constantProfiles) constantExact=\(constantExact) comparedBytes=\(compared)")
        XCTAssertEqual(profiles,96)
        XCTAssertEqual(oracleProfiles,36)
        XCTAssertEqual(constantProfiles,48)
        // Numerical differences are findings; no arbitrary pixel threshold.
    }
}
