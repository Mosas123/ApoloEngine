import AVFoundation
import Foundation
import Darwin
import XCTest
@testable import ApoloEngine

/// Real libavcodec host + Apple renderer in simulator, no audible-output claim.
/// Observes actual synchronizer clock at successor handoff; no acoustic claim.
final class G0RendererClockTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B94_EVENT \(s)")}
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
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_CLOCK_OVERLAY"]=="1")
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
    private func run(_ name:String)throws{
        print("G0_4B94_PROCESS pid=\(getpid()) scenario=\(name)")
        let early=name=="Early",paused=name=="LatePaused"
        let a=try fixture(early ? 3:0.5),b=try fixture(0.75)
        defer{try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let e=Events(),h=host(e)
        defer{h.stop()}
        h.configure(equalizer:.flat,limiterEnabled:false,trackGainDB:0)
        h.load(url:a,httpHeaders:[:],epoch:701)
        _=try XCTUnwrap(e.wait("renderer.firstPCM epoch=701"))
        if !early{
            _=try XCTUnwrap(e.wait("renderer.finishScheduled epoch=701"))
        }
        if paused{
            h.pause()
            _=try XCTUnwrap(e.wait("g0.clockPause epoch=701"))
        }
        let from=e.all().count
        h.enqueueNext(ApoloTrack(url:b))
        _=try XCTUnwrap(e.wait("trackChange epoch=701",after:from))
        let successor=try XCTUnwrap(e.wait("g0.clockSuccessor epoch=701",after:from))
        let boundary=try XCTUnwrap(e.wait("g0.clockBoundary epoch=701",after:from))
        let command=try XCTUnwrap(e.wait("g0.clockNext epoch=701",after:from))
        XCTAssertTrue(command.contains("requesting=\(early)"),"early must be before decoder EOF")
        XCTAssertTrue(boundary.contains("wants=\(!paused)"))
        let stopFrom=e.all().count
        h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=701",after:stopFrom))
        print("G0_4B94_CONTROL scenario=\(name) early=\(early) paused=\(paused) successor=true boundary=true stopped=true")
        print("G0_4B94_OBSERVATION scenario=\(name) command=\(command) successor=\(successor) boundary=\(boundary)")
    }
    func testEarly()throws{try run("Early")}
    func testLate()throws{try run("Late")}
    func testLatePaused()throws{try run("LatePaused")}
}
