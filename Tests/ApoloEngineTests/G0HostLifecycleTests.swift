import AVFoundation
import Foundation
import Darwin
import XCTest
@testable import ApoloEngine

/// Real libavcodec host + Apple renderer in simulator, no audible-output claim.
/// Runner overlay adds observational snapshots and an optional bounded read gate.
final class G0HostLifecycleTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B9_EVENT \(s)")}
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
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_HOST_OVERLAY"]=="1")
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
    func testLifecycle()throws{
        print("G0_4B9_PROCESS pid=\(getpid()) scenario=Lifecycle")
        let url=try fixture(3);defer{try? FileManager.default.removeItem(at:url)}
        let e=Events(),h=host(e)
        defer{h.stop()}
        h.configure(equalizer:.flat,limiterEnabled:false,trackGainDB:0)
        h.load(url:url,httpHeaders:[:],epoch:101)
        _=try XCTUnwrap(e.wait("state=loading epoch=101"))
        _=try XCTUnwrap(e.wait("renderer.firstPCM epoch=101"))
        var from=e.all().count
        h.pause()
        _=try XCTUnwrap(e.wait("state=paused epoch=101",after:from))
        let paused=try XCTUnwrap(e.wait("g0.hostSnapshot action=pause",after:from))
        XCTAssertTrue(paused.contains("wants=false"));XCTAssertTrue(paused.contains("decoder=true"))
        from=e.all().count
        h.seek(to:1)
        _=try XCTUnwrap(e.wait("renderer.seek epoch=101",after:from))
        let seek=try XCTUnwrap(e.wait("g0.hostSnapshot action=seek",after:from))
        XCTAssertTrue(seek.contains("wants=false"))
        from=e.all().count
        h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=101",after:from))
        let stop=try XCTUnwrap(e.wait("g0.hostSnapshot action=stop",after:from))
        XCTAssertTrue(stop.contains("decoder=false"));XCTAssertTrue(stop.contains("requesting=false"))
        from=e.all().count
        h.load(url:url,httpHeaders:[:],epoch:102)
        _=try XCTUnwrap(e.wait("state=loading epoch=102",after:from))
        _=try XCTUnwrap(e.wait("renderer.firstPCM epoch=102",after:from))
        h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=102",after:from))
        print("G0_4B9_CONTROL scenario=Lifecycle load=true pause=true seek=true stop=true reload=true")
    }
    func testBlockedRead()throws{
        print("G0_4B9_PROCESS pid=\(getpid()) scenario=BlockedRead")
        let url=try fixture(3);defer{try? FileManager.default.removeItem(at:url)}
        let marker=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("APOLO_G0_HOST_GATE",marker.path,1)
        defer{unsetenv("APOLO_G0_HOST_GATE");try? FileManager.default.removeItem(at:marker)}
        let e=Events(),h=host(e)
        defer{try? Data().write(to:marker);h.stop()}
        h.load(url:url,httpHeaders:[:],epoch:201)
        _=try XCTUnwrap(e.wait("g0.hostReadEntered epoch=201"))
        let from=e.all().count,t0=DispatchTime.now().uptimeNanoseconds
        h.stop()
        let early=e.wait("state=idle epoch=201",after:from,timeout:0.15) != nil
        try Data().write(to:marker)
        _=try XCTUnwrap(e.wait("g0.hostReadReleased epoch=201",after:from))
        _=try XCTUnwrap(e.wait("state=idle epoch=201",after:from))
        let elapsed=Double(DispatchTime.now().uptimeNanoseconds-t0)/1e6
        let stop=try XCTUnwrap(e.wait("g0.hostSnapshot action=stop",after:from))
        XCTAssertFalse(early);XCTAssertTrue(stop.contains("decoder=false"))
        print("G0_4B9_CONTROL scenario=BlockedRead earlyIdle=\(early) stopped=true")
        print("G0_4B9_OBSERVATION scenario=BlockedRead stopMS=\(elapsed)")
    }
    func testPausedEOF()throws{
        print("G0_4B9_PROCESS pid=\(getpid()) scenario=PausedEOF")
        let url=try fixture(0.25);defer{try? FileManager.default.removeItem(at:url)}
        let e=Events(),h=host(e)
        defer{h.stop()}
        h.load(url:url,httpHeaders:[:],epoch:301)
        let scheduled=try XCTUnwrap(e.wait("renderer.finishScheduled epoch=301"))
        let from=e.all().count
        h.pause()
        let pause=try XCTUnwrap(e.wait("g0.hostSnapshot action=pause",after:from))
        let fired=e.wait("renderer.finishFired epoch=301",after:from,timeout:2)
        let finished=e.all().dropFirst(from).contains{$0.hasPrefix("state=finished epoch=301")}
        print("G0_4B9_OBSERVATION scenario=PausedEOF scheduled=\(scheduled) pause=\(pause) fired=\(fired ?? "none") finished=\(finished)")
        h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=301",after:from))
        print("G0_4B9_CONTROL scenario=PausedEOF scheduled=true pause=true stopped=true")
    }
}
