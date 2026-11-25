import AetherLibavfilter
import AetherLibavutil
import Foundation
import Darwin
import XCTest

final class G0F07ColorTests: XCTestCase {
    private enum LabError:Error{case setup,frame,drain}
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func hash(_ samples:[UInt16])->String{
        var h:UInt64=14695981039346656037
        for v in samples{h=(h ^ UInt64(v & 255)) &* 1099511628211;h=(h ^ UInt64(v >> 8)) &* 1099511628211}
        return String(h,radix:16)
    }
    private func bounds(_ depth:Int,_ full:Bool,_ plane:Int)->(Int,Int){
        let s=1 << (depth-8)
        return full ? (0,(1 << depth)-1):(16*s,(plane==0 ? 235:240)*s)
    }
    private func expected(_ v:Int,_ from:Int,_ to:Int,_ inputFull:Bool,_ outputFull:Bool,_ plane:Int)->Int{
        let (lo,hi)=bounds(from,inputFull,plane), (ol,oh)=bounds(to,outputFull,plane)
        if plane==0{
            return min(oh,max(ol,Int((Double(v-lo)*Double(oh-ol)/Double(hi-lo)+Double(ol)).rounded())))
        }
        // Explicit centered chroma reference; implementation rounding and
        // full-range endpoint conventions may differ. Measure, don't certify.
        let center=1 << (from-1),outCenter=1 << (to-1)
        let value=Double(v-center)*Double(oh-ol)/Double(hi-lo)+Double(outCenter)
        return min(oh,max(ol,Int(value.rounded())))
    }
    private func run(w:Int,h:Int,sub:Bool,from:Int,to:Int,inputFull:Bool,outputFull:Bool,filter:String,constant:Bool)throws->(samples:[UInt16],reference:[UInt16],pts:[Int64],ranges:[Int32]){
        let inName=(sub ? "yuv420p":"yuv444p")+(from==10 ? "10le":"")
        let outName=(sub ? "yuv420p":"yuv444p")+(to==10 ? "10le":"")
        let infmt=av_get_pix_fmt(inName),outfmt=av_get_pix_fmt(outName)
        var owner=avfilter_graph_alloc(),fi=av_frame_alloc(),fo=av_frame_alloc()
        defer{av_frame_free(&fi);av_frame_free(&fo);avfilter_graph_free(&owner)}
        guard let g=owner,let input=fi,let output=fo else{throw LabError.setup}
        g.pointee.nb_threads=1
        avfilter_graph_set_auto_convert(g,UInt32.max)
        func node(_ f:String,_ n:String,_ options:String?)throws->UnsafeMutablePointer<AVFilterContext>{
            var p:UnsafeMutablePointer<AVFilterContext>?
            guard let kind=avfilter_get_by_name(f) else{throw LabError.setup}
            let rc:Int32
            if let options{rc=options.withCString{a in n.withCString{avfilter_graph_create_filter(&p,kind,$0,a,nil,g)}}}
            else{rc=n.withCString{avfilter_graph_create_filter(&p,kind,$0,nil,nil,g)}}
            guard rc>=0,let p else{print("G0_F07B_SETUP filter=\(f) code=\(rc)");throw LabError.setup}
            return p
        }
        let ri=inputFull ? "full":"limited",ro=outputFull ? "full":"limited"
        let src=try node("buffer","src","video_size=\(w)x\(h):pix_fmt=\(infmt.rawValue):time_base=1/1000:pixel_aspect=1/1")
        let options=filter=="zscale"
            ? "w=\(w):h=\(h):rangein=\(ri):range=\(ro):matrixin=709:matrix=709:dither=none"
            : "w=\(w):h=\(h):in_range=\(ri):out_range=\(ro):in_color_matrix=bt709:out_color_matrix=bt709:flags=bilinear+accurate_rnd"
        let effect=try node(filter,"effect",options)
        let pin=try node("format","pin","pix_fmts=\(outName)")
        let sink=try node("buffersink","sink",nil)
        guard avfilter_link(src,0,effect,0)>=0,avfilter_link(effect,0,pin,0)>=0,
              avfilter_link(pin,0,sink,0)>=0,avfilter_graph_config(g,nil)>=0 else{throw LabError.setup}
        var samples:[UInt16]=[],reference:[UInt16]=[],pts:[Int64]=[],ranges:[Int32]=[]
        let eof:Int32 = -541478725, again = -Int32(EAGAIN)
        func drain()throws->Int32{
            for _ in 0..<8{
                let rc=av_buffersink_get_frame(sink,output)
                if rc==eof || rc==again{return rc}
                guard rc>=0 else{throw LabError.drain}
                defer{av_frame_unref(output)}
                guard output.pointee.width==Int32(w),output.pointee.height==Int32(h),output.pointee.format==outfmt.rawValue,pts.count<2 else{throw LabError.frame}
                pts.append(output.pointee.pts)
                ranges.append(Int32(output.pointee.color_range.rawValue))
                for plane in 0..<3{
                    let pw=plane>0 && sub ? w/2:w,ph=plane>0 && sub ? h/2:h
                    let data:[UnsafeMutablePointer<UInt8>?]=[output.pointee.data.0,output.pointee.data.1,output.pointee.data.2]
                    let lines=[output.pointee.linesize.0,output.pointee.linesize.1,output.pointee.linesize.2]
                    guard let base=data[plane],Int(lines[plane])>=pw*(to==10 ? 2:1) else{throw LabError.frame}
                    for y in 0..<ph{for x in 0..<pw{
                        let p=base.advanced(by:y*Int(lines[plane])+x*(to==10 ? 2:1))
                        samples.append(to==10 ? UInt16(p[0]) | UInt16(p[1])<<8:UInt16(p[0]))
                    }}
                }
            }
            throw LabError.drain
        }
        for frame in 0..<2{
            input.pointee.width=Int32(w);input.pointee.height=Int32(h);input.pointee.format=infmt.rawValue
            input.pointee.pts=12345+Int64(frame*40)
            input.pointee.color_range=inputFull ? AVCOL_RANGE_JPEG:AVCOL_RANGE_MPEG
            input.pointee.colorspace=AVCOL_SPC_BT709
            input.pointee.color_primaries=AVCOL_PRI_BT709
            input.pointee.color_trc=AVCOL_TRC_BT709
            guard av_frame_get_buffer(input,32)>=0 else{throw LabError.frame}
            for plane in 0..<3{
                let pw=plane>0 && sub ? w/2:w,ph=plane>0 && sub ? h/2:h
                let data:[UnsafeMutablePointer<UInt8>?]=[input.pointee.data.0,input.pointee.data.1,input.pointee.data.2]
                let lines=[input.pointee.linesize.0,input.pointee.linesize.1,input.pointee.linesize.2]
                guard let base=data[plane] else{throw LabError.frame}
                let (lo,hi)=bounds(from,inputFull,plane)
                for y in 0..<ph{for x in 0..<pw{
                    let v=constant ? (plane==0 ? (lo+hi)/2 : (1 << (from-1))) : lo+(x*17+y*31+plane*53+frame*19)%(hi-lo+1)
                    let p=base.advanced(by:y*Int(lines[plane])+x*(from==10 ? 2:1))
                    p[0]=UInt8(truncatingIfNeeded:v)
                    if from==10{p[1]=UInt8(truncatingIfNeeded:v>>8)}
                    reference.append(UInt16(expected(v,from,to,inputFull,outputFull,plane)))
                }}
            }
            guard av_buffersrc_add_frame_flags(src,input,0)>=0 else{throw LabError.frame}
            av_frame_unref(input)
            _=try drain()
        }
        guard av_buffersrc_add_frame_flags(src,nil,0)>=0,try drain()==eof,try drain()==eof,samples.count==reference.count,pts==[12345,12385] else{throw LabError.drain}
        return(samples,reference,pts,ranges)
    }
    func testG0F07BColor()throws{
        var attempted=0,observed=0,compared=0,exactProfiles=0,rangeExact=0,errors=0
        for (w,h) in [(32,24),(64,48)]{
            for sub in [true,false]{
                for (from,to) in [(8,8),(8,10),(10,8)]{
                    for (inputFull,outputFull) in [(false,false),(true,true),(false,true),(true,false)]{
                        for filter in ["scale","zscale"]{
                            for constant in [true,false]{
                                attempted+=1
                                do{
                                    let r=try run(w:w,h:h,sub:sub,from:from,to:to,inputFull:inputFull,outputFull:outputFull,filter:filter,constant:constant)
                                    var maxError=0,exact=0,sum:Int64=0
                                    for (a,b) in zip(r.samples,r.reference){
                                        let e=abs(Int(a)-Int(b));maxError=max(maxError,e);sum+=Int64(e);if e==0{exact+=1}
                                    }
                                    let expectedRange=Int32((outputFull ? AVCOL_RANGE_JPEG:AVCOL_RANGE_MPEG).rawValue)
                                    let rangeOK=r.ranges.allSatisfy{$0==expectedRange}
                                    if rangeOK{rangeExact+=1}
                                    if maxError==0{exactProfiles+=1}
                                    compared+=r.samples.count;observed+=1
                                    print("G0_F07B_COLOR size=\(w)x\(h) sub420=\(sub) from=\(from) to=\(to) fullIn=\(inputFull) fullOut=\(outputFull) filter=\(filter) constant=\(constant) count=\(r.samples.count) exact=\(exact) maxError=\(maxError) sumError=\(sum) rangeOK=\(rangeOK) pts=\(r.pts.map(String.init).joined(separator:",")) hash=\(hash(r.samples))")
                                }catch{
                                    errors+=1
                                    print("G0_F07B_ERROR size=\(w)x\(h) sub420=\(sub) from=\(from) to=\(to) fullIn=\(inputFull) fullOut=\(outputFull) filter=\(filter) constant=\(constant) error=\(error)")
                                }
                            }
                        }
                    }
                }
            }
        }
        print("G0_F07B_SUMMARY attempted=\(attempted) observed=\(observed) compared=\(compared) exactProfiles=\(exactProfiles) rangeExact=\(rangeExact) errors=\(errors)")
        XCTAssertEqual(attempted,192);XCTAssertEqual(observed,192);XCTAssertEqual(errors,0)
    }
}
