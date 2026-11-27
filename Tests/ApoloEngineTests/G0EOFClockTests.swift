import AVFoundation
import Foundation
import Darwin
import XCTest
@testable import ApoloEngine

/// Real libavcodec host + Apple renderer in simulator, no audible-output claim.
/// Runner overlay records clock, timer tokens and successor transitions only.
final class G0EOFClockTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B92_EVENT \(s)")}
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
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_EOF_OVERLAY"]=="1")
    }
    private func fixture(_ seconds:Double)throws->URL{
        let rate=48000,n=Int(seconds*Double(rate))
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func integer<T:FixedWidthInteger>(_ x:T){var v=x.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");integer(UInt32(36+n*4));ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2))
        integer(UInt32(rate));integer(UInt32(rate*4));integer(UInt16(4));integer(UInt16(16));ascii("data");integer(UInt32(n*4))
        for i in 0..<n{
            integer(Int16(4096*sin(Double(i)*2*Double.pi*997/Double(rate))))
            integer(Int16(2048*sin(Double(i)*2*Double.pi*1237/Double(rate))))
        }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try data.write(to:url);return url
    }
    private func host(_ events:Events)->LibavcodecAudioHost{
        let diagnostics=AudioDiagnostics()
        diagnostics.setHandler{events.add($0)}
        return LibavcodecAudioHost(onState:{state,epoch in events.add("state=\(state) epoch=\(epoch)")},onTime:{_,_ in},onTrackChange:{_,epoch in events.add("trackChange epoch=\(epoch)")},diagnostics:diagnostics)
    }
    private func settle(_ seconds:Double){
        let deadline=DispatchTime.now().uptimeNanoseconds+UInt64(seconds*1e9)
        while DispatchTime.now().uptimeNanoseconds<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    }
    private func field(_ event:String,_ key:String)->String?{
        event.split(separator:" ").first{$0.hasPrefix(key+"=")}.map{String($0.dropFirst(key.count+1))}
    }
    private func schedule(_ e:Events,epoch:UInt64,after:Int=0)throws->String{
        try XCTUnwrap(e.wait("renderer.finishScheduled epoch=\(epoch)",after:after))
    }
    private func fired(_ e:Events,epoch:UInt64,after:Int=0)->[String]{
        e.all().dropFirst(after).filter{$0.hasPrefix("renderer.finishFired epoch=\(epoch)")}
    }
    private func run(_ name:String)throws{
        print("G0_4B92_PROCESS pid=\(getpid()) scenario=\(name)")
        let short=try fixture(0.5),long=try fixture(3)
        defer{try? FileManager.default.removeItem(at:short);try? FileManager.default.removeItem(at:long)}
        let e=Events(),h=host(e),epoch:UInt64=501
        defer{h.stop()}
        h.configure(equalizer:.flat,limiterEnabled:false,trackGainDB:0)
        h.load(url:short,httpHeaders:[:],epoch:epoch)
        let scheduled=try schedule(e,epoch:epoch)
        let token=try XCTUnwrap(field(scheduled,"token"))
        let from=e.all().count
        if name=="Normal"{
            let finish=try XCTUnwrap(e.wait("renderer.finishFired epoch=501",after:from))
            _=try XCTUnwrap(e.wait("state=finished epoch=501",after:from))
            print("G0_4B92_OBSERVATION scenario=\(name) scheduled=\(scheduled) fired=\(finish)")
        }else if name=="PauseResume"{
            h.pause()
            let paused=try XCTUnwrap(e.wait("g0.eofSnapshot action=pause",after:from))
            XCTAssertTrue(paused.contains("wants=false"))
            settle(1.2)
            let during=fired(e,epoch:epoch,after:from)
            let countBefore=e.all().count
            let before=h.currentTime
            h.play()
            let played=try XCTUnwrap(e.wait("g0.eofSnapshot action=play",after:countBefore))
            settle(1.4)
            let after=h.currentTime
            let resumed=fired(e,epoch:epoch,after:countBefore)
            print("G0_4B92_OBSERVATION scenario=\(name) paused=\(paused) during=\(during.joined(separator:";")) play=\(played) resumed=\(resumed.joined(separator:";")) before=\(before) after=\(after)")
        }else if name=="Seek"{
            h.seek(to:0.10)
            let seek=try XCTUnwrap(e.wait("g0.eofSnapshot action=seek",after:from))
            XCTAssertNotEqual(field(seek,"token"),token)
            let invalid=try XCTUnwrap(e.wait("g0.eofInvalidated scheduledEpoch=501 scheduledToken=\(token) ",after:from))
            let newSchedule=try schedule(e,epoch:epoch,after:from)
            let newToken=try XCTUnwrap(field(newSchedule,"token"))
            XCTAssertNotEqual(newToken,token)
            let finish=try XCTUnwrap(e.wait("renderer.finishFired epoch=501",after:from))
            _=try XCTUnwrap(e.wait("state=finished epoch=501",after:from))
            print("G0_4B92_OBSERVATION scenario=\(name) seek=\(seek) invalid=\(invalid) scheduled=\(newSchedule) fired=\(finish)")
        }else if name=="Stop"{
            h.stop()
            let stopped=try XCTUnwrap(e.wait("g0.eofSnapshot action=stop",after:from))
            XCTAssertTrue(stopped.contains("decoder=false"))
            _=try XCTUnwrap(e.wait("g0.eofInvalidated scheduledEpoch=501 scheduledToken=\(token) ",after:from))
            XCTAssertTrue(fired(e,epoch:epoch,after:from).isEmpty)
            print("G0_4B92_OBSERVATION scenario=\(name) stop=\(stopped) stale=false")
        }else if name=="Reload"{
            h.load(url:long,httpHeaders:[:],epoch:502)
            _=try XCTUnwrap(e.wait("renderer.firstPCM epoch=502",after:from))
            let invalid=try XCTUnwrap(e.wait("g0.eofInvalidated scheduledEpoch=501 scheduledToken=\(token) ",after:from))
            XCTAssertTrue(fired(e,epoch:epoch,after:from).isEmpty)
            print("G0_4B92_OBSERVATION scenario=\(name) invalid=\(invalid) stale=false")
        }else if name=="Successor"{
            h.enqueueNext(ApoloTrack(url:long))
            _=try XCTUnwrap(e.wait("trackChange epoch=501",after:from))
            let next=try XCTUnwrap(e.wait("g0.eofSuccessor epoch=501",after:from))
            _=try XCTUnwrap(e.wait("g0.eofInvalidated scheduledEpoch=501 scheduledToken=\(token) ",after:from))
            XCTAssertTrue(fired(e,epoch:epoch,after:from).isEmpty)
            print("G0_4B92_OBSERVATION scenario=\(name) next=\(next) stale=false")
        }
        let stopFrom=e.all().count
        h.stop()
        _=try XCTUnwrap(e.wait("g0.eofSnapshot action=stop",after:stopFrom))
        print("G0_4B92_CONTROL scenario=\(name) scheduled=true exercised=true stopped=true")
    }
    func testNormal()throws{try run("Normal")}
    func testPauseResume()throws{try run("PauseResume")}
    func testSeek()throws{try run("Seek")}
    func testStop()throws{try run("Stop")}
    func testReload()throws{try run("Reload")}
    func testSuccessor()throws{try run("Successor")}
}
