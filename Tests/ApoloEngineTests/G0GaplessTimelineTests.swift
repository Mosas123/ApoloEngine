import AVFoundation
import Foundation
import Darwin
import XCTest
@testable import ApoloEngine

/// Real libavcodec host + Apple renderer in simulator, no audible-output claim.
/// Runner overlay observes PCM at enqueue, not physical rendered audio.
final class G0GaplessTimelineTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B93_EVENT \(s)")}
        func all()->[String]{lock.lock();defer{lock.unlock()};return entries}
        func wait(_ prefix:String,after:Int=0,timeout:Double=12)->String?{
            let deadline=DispatchTime.now().uptimeNanoseconds+UInt64(timeout*1e9)
            repeat{
                if let event=all().dropFirst(after).first(where:{$0.hasPrefix(prefix)}){return event}
                RunLoop.current.run(until:Date().addingTimeInterval(0.01))
            }while DispatchTime.now().uptimeNanoseconds<deadline
            return nil
        }
    }
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_GAPLESS_OVERLAY"]=="1")
    }
    private func fixture(_ seconds:Double,track:Int=0)throws->URL{
        let rate=48000,n=Int(seconds*Double(rate))
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func integer<T:FixedWidthInteger>(_ x:T){var v=x.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");integer(UInt32(36+n*4));ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2))
        integer(UInt32(rate));integer(UInt32(rate*4));integer(UInt16(4));integer(UInt16(16));ascii("data");integer(UInt32(n*4))
        for i in 0..<n{
            integer(word(i,0,track));integer(word(i,1,track))
        }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try data.write(to:url);return url
    }
    private func host(_ events:Events)->LibavcodecAudioHost{
        let diagnostics=AudioDiagnostics()
        diagnostics.setHandler{events.add($0)}
        return LibavcodecAudioHost(onState:{state,epoch in events.add("state=\(state) epoch=\(epoch)")},onTime:{_,_ in},onTrackChange:{_,epoch in events.add("trackChange epoch=\(epoch)")},diagnostics:diagnostics)
    }
    private func word(_ index:Int,_ channel:Int,_ track:Int)->Int16{
        Int16(channel==0 ? index%16384-8192 : (track==0 ? 4096 : -4096)+(index/16384)*256)
    }
    private func hash(_ start:Int,_ count:Int,_ track:Int)->UInt64{
        var h:UInt64=14695981039346656037
        for i in start..<(start+count){
            for c in 0..<2{
                let f=Float(word(i,c,track))/32768
                h=(h ^ UInt64(f.bitPattern)) &* 1099511628211
            }
        }
        return h
    }
    private func fields(_ event:String)->[String:String]{
        Dictionary(uniqueKeysWithValues:event.split(separator:" ").compactMap{part in
            let v=part.split(separator:"=",maxSplits:1)
            return v.count==2 ? (String(v[0]),String(v[1])):nil
        })
    }
    private func int(_ f:[String:String],_ k:String)throws->Int{try XCTUnwrap(f[k].flatMap(Int.init))}
    private func run(_ name:String)throws{
        print("G0_4B93_PROCESS pid=\(getpid()) scenario=\(name)")
        let a=try fixture(0.5),b=try fixture(0.75,track:1)
        defer{try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let e=Events(),h=host(e)
        defer{h.stop()}
        h.configure(equalizer:.flat,limiterEnabled:false,trackGainDB:0)
        h.load(url:a,httpHeaders:[:],epoch:601)
        _=try XCTUnwrap(e.wait("renderer.finishScheduled epoch=601"))
        var from=0
        if name=="Seek"{
            from=e.all().count
            h.seek(to:0.1)
            _=try XCTUnwrap(e.wait("renderer.seek epoch=601",after:from))
            _=try XCTUnwrap(e.wait("renderer.finishScheduled epoch=601",after:from))
        }else if name=="Successor"{
            from=e.all().count
            h.enqueueNext(ApoloTrack(url:b))
            _=try XCTUnwrap(e.wait("trackChange epoch=601",after:from))
            _=try XCTUnwrap(e.wait("renderer.finishScheduled epoch=601",after:from))
            from=0
        }
        let stopFrom=e.all().count
        h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=601",after:stopFrom))
        let records=e.all().dropFirst(from).filter{$0.hasPrefix("g0.gaplessPCM ")}
        XCTAssertFalse(records.isEmpty)
        var counts=[0,0],starts=[-1,-1],lastSource=[-1,-1],lastPTS=[Int?](repeating:nil,count:2)
        var ptsJumps=[0,0],sourceJumps=[0,0],firstPTS=[-1,-1],checked=0,exact=0
        var boundaryGap:Int?=nil
        for line in records{
            let f=fields(line)
            let n=try int(f,"frames"),pts=try int(f,"pts"),trackStart=try int(f,"trackStart")
            let left=try int(f,"lastL"),right=try int(f,"lastR")
            let track=right>=0 ? 0:1
            let group=(right-(track==0 ? 4096 : -4096))/256
            let last=group*16384+left+8192,start=last-n+1
            XCTAssertGreaterThan(n,0)
            guard start>=0,last<(track==0 ? 24000:36000) else{throw NSError(domain:"G0SourceIndex",code:1)}
            let skip=name=="Seek" && counts[track]==0 ? 144:0
            guard n>skip else{throw NSError(domain:"G0Ramp",code:2)}
            let expected=hash(start+skip,n-skip,track)
            let actual=try XCTUnwrap(f[skip==0 ? "hash":"suffix"].flatMap(UInt64.init))
            checked+=(n-skip)*2
            if expected==actual{exact+=(n-skip)*2}
            XCTAssertEqual(actual,expected,"independent source PCM at inferred index, excluding first seek ramp")
            if counts[track]==0{
                starts[track]=start;firstPTS[track]=pts
                if track==1,let previous=lastPTS[0]{boundaryGap=pts-previous}
            }else{
                if lastSource[track]+1 != start{sourceJumps[track]+=1}
                if lastPTS[track] != pts{ptsJumps[track]+=1}
            }
            lastSource[track]=last;lastPTS[track]=pts+n;counts[track]+=n
            print("G0_4B93_BUFFER scenario=\(name) track=\(track) sourceStart=\(start) pts=\(pts) frames=\(n) trackStart=\(trackStart) exact=\(actual==expected)")
        }
        if name != "Seek"{
            XCTAssertEqual(counts[0],24000);XCTAssertEqual(starts[0],0);XCTAssertEqual(firstPTS[0],0)
            XCTAssertEqual(lastPTS[0],24000);XCTAssertEqual(sourceJumps[0],0);XCTAssertEqual(ptsJumps[0],0)
        }
        if name=="Successor"{
            XCTAssertEqual(counts[1],36000);XCTAssertEqual(starts[1],0)
            XCTAssertEqual(sourceJumps[1],0);XCTAssertEqual(ptsJumps[1],0)
        }else{XCTAssertEqual(counts[1],0)}
        XCTAssertEqual(checked,exact)
        print("G0_4B93_CONTROL scenario=\(name) exact=true scalars=\(exact) counts=\(counts.map(String.init).joined(separator:",")) sourceStarts=\(starts.map(String.init).joined(separator:",")) sourceEnds=\(lastSource.map{String($0+1)}.joined(separator:",")) firstPTS=\(firstPTS.map(String.init).joined(separator:",")) endPTS=\(lastPTS.map{$0.map(String.init) ?? "none"}.joined(separator:",")) sourceJumps=\(sourceJumps.map(String.init).joined(separator:",")) ptsJumps=\(ptsJumps.map(String.init).joined(separator:","))")
        print("G0_4B93_OBSERVATION scenario=\(name) boundaryGap=\(boundaryGap.map(String.init) ?? "none")")
    }
    func testNormal()throws{try run("Normal")}
    func testSeek()throws{try run("Seek")}
    func testSuccessor()throws{try run("Successor")}
}
