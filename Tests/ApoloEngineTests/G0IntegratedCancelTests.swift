import Foundation
import Network
import Darwin
import XCTest
import AetherLibavformat
@testable import ApoloEngine

/// Real HTTP host cancellation with a runner-only per-load cancellation token.
final class G0IntegratedCancelTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B96_EVENT \(s)")}
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
    private final class RangeServer:@unchecked Sendable{
        let queue=DispatchQueue(label:"g0.4b91.http")
        let ready=DispatchSemaphore(value:0)
        let held=DispatchSemaphore(value:0)
        private let lock=NSLock()
        private let payload:Data
        private var listener:NWListener?
        private var connections=[NWConnection]()
        private var pending:(NWConnection,Data)?
        private var armed=false
        private var blockedStart:Int?
        private var requestCount=0
        private var released=false
        private var closed=false
        init(_ payload:Data){self.payload=payload}
        func start()throws->URL{
            let params=NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
            let l=try NWListener(using:params)
            listener=l
            l.stateUpdateHandler={ [weak self] s in if case .ready=s{self?.ready.signal()} }
            l.newConnectionHandler={ [weak self] c in self?.accept(c) }
            l.start(queue:queue)
            guard ready.wait(timeout:.now()+5) == .success else{throw NSError(domain:"G0Listener",code:1)}
            return try XCTUnwrap(URL(string:"http://127.0.0.1:\(try XCTUnwrap(l.port?.rawValue))/fixture.wav"))
        }
        func arm(){lock.lock();armed=true;lock.unlock()}
        func snapshot()->(Int?,Int){lock.lock();defer{lock.unlock()};return(blockedStart,requestCount)}
        private func accept(_ c:NWConnection){
            lock.lock()
            if closed{lock.unlock();c.cancel();return}
            connections.append(c);lock.unlock()
            c.stateUpdateHandler={ [weak self,weak c] s in
                if case .ready=s,let self,let c{self.receive(c,Data())}
            }
            c.start(queue:queue)
        }
        private func receive(_ c:NWConnection,_ prefix:Data){
            c.receive(minimumIncompleteLength:1,maximumLength:4096){[weak self,weak c] data,_,complete,error in
                guard let self,let c,error==nil,let data else{return}
                let request=prefix+data
                if request.range(of:Data([13,10,13,10]))==nil{
                    if !complete && request.count<16384{self.receive(c,request)}
                    return
                }
                self.respond(c,request)
            }
        }
        private func respond(_ c:NWConnection,_ request:Data){
            let lines=String(decoding:request,as:UTF8.self).components(separatedBy:"\r\n")
            guard let range=lines.first(where:{$0.lowercased().hasPrefix("range:")}),
                  let value=range.split(separator:"=").last else{c.cancel();return}
            let parts=value.split(separator:"-")
            guard parts.count==2,let lo=Int(parts[0]),let requestedEnd=Int(parts[1]),lo>=0,lo<payload.count,requestedEnd>=lo else{c.cancel();return}
            let hi=min(requestedEnd,payload.count-1)
            let response=Data("HTTP/1.1 206 Partial Content\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Range: bytes \(lo)-\(hi)/\(payload.count)\r\nContent-Length: \(hi-lo+1)\r\nConnection: close\r\n\r\n".utf8)+payload.subdata(in:lo..<(hi+1))
            lock.lock();requestCount+=1
            if armed && !released && pending==nil{
                pending=(c,response);blockedStart=lo
                lock.unlock();held.signal();return
            }
            lock.unlock();send(c,response)
        }
        private func send(_ c:NWConnection,_ data:Data){
            c.send(content:data,completion:.contentProcessed{[weak c] _ in
                c?.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed{_ in})
            })
        }
        func release(){
            lock.lock();released=true;let p=pending;pending=nil;lock.unlock()
            if let p{send(p.0,p.1)}
        }
        func close(){
            lock.lock();closed=true;let cs=connections;connections.removeAll();pending=nil;lock.unlock()
            listener?.cancel()
            for c in cs{c.cancel()}
        }
    }
    private final class ReadResult:@unchecked Sendable{
        private let lock=NSLock()
        private var count:Int32?
        func set(_ n:Int32){lock.lock();count=n;lock.unlock()}
        func get()->Int32?{lock.lock();defer{lock.unlock()};return count}
    }
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_INTEGRATED_CANCEL"]=="1")
    }
    private func fixture()->Data{
        let rate=48000,n=rate*20
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func integer<T:FixedWidthInteger>(_ x:T){var v=x.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");integer(UInt32(36+n*4));ascii("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2))
        integer(UInt32(rate));integer(UInt32(rate*4));integer(UInt16(4));integer(UInt16(16));ascii("data");integer(UInt32(n*4))
        for i in 0..<n{
            integer(Int16((i%127)*32-2016));integer(Int16((i%97)*32-1536))
        }
        return data
    }
    private func host(_ events:Events,_ diagnostics:AudioDiagnostics)->LibavcodecAudioHost{
        diagnostics.setHandler{events.add($0)}
        return LibavcodecAudioHost(onState:{state,epoch in events.add("state=\(state) epoch=\(epoch)")},onTime:{_,_ in},onTrackChange:{_,epoch in events.add("trackChange epoch=\(epoch)")},diagnostics:diagnostics)
    }
    private func run(_ name:String)throws{
#if G0_INTEGRATED_CANCEL
        print("G0_4B96_PROCESS pid=\(getpid()) scenario=\(name)")
        let server=RangeServer(fixture())
        defer{server.release();server.close()}
        let url=try server.start(),e=Events(),d=AudioDiagnostics(),h=host(e,d)
        defer{server.release();h.stop()}
        let refill=name != "OpenStop",reload=name=="Reload"
        let epoch:UInt64=801
        let probe:Int
        if refill{
            let token=G0FiniteCancellation()
            let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral,diagnostics:d,g0FiniteCancellation:token)
            probe=server.snapshot().1
            h.g0Attach(token)
            server.arm()
            h.load(source:source,epoch:epoch)
        }else{
            probe=0;server.arm()
            h.load(url:url,httpHeaders:[:],epoch:epoch)
        }
        guard server.held.wait(timeout:.now()+25) == .success else{throw NSError(domain:"G0Held",code:1)}
        let (offset,requests)=server.snapshot()
        XCTAssertGreaterThan(requests,probe)
        let first=e.all().contains{$0.hasPrefix("renderer.firstPCM epoch=801")}
        XCTAssertEqual(first,refill)
        let second=RangeServer(fixture())
        defer{second.close()}
        let nextURL=try second.start()
        let from=e.all().count,t0=DispatchTime.now().uptimeNanoseconds
        if reload{h.load(url:nextURL,httpHeaders:[:],epoch:802)}
        else{h.stop();if name=="StopTwice"{h.stop()}}
        let expected=reload ? "renderer.firstPCM epoch=802":"state=idle epoch=801"
        let woke=e.wait(expected,after:from,timeout:3) != nil
        let ms=Double(DispatchTime.now().uptimeNanoseconds-t0)/1e6
        let captured=Array(e.all().dropFirst(from))
        let cancel=captured.firstIndex{$0.hasPrefix("g0.cancelSession")}
        let returned=captured.firstIndex{$0.hasPrefix("g0.cancelRequestReturned")}
        let closed=captured.firstIndex{$0.hasPrefix("g0.cancelOwnerClose")}
        server.release()
        if !woke{_ = e.wait(expected,after:from,timeout:20)}
        XCTAssertTrue(woke,"command must finish before server release")
        let c=try XCTUnwrap(cancel),r=try XCTUnwrap(returned),o=try XCTUnwrap(closed)
        XCTAssertLessThan(c,r);XCTAssertLessThan(r,o)
        let failures=captured.filter{$0.hasPrefix("state=failed")}
        var stale=0
        if reload{
            let new=try XCTUnwrap(e.all().firstIndex{$0.hasPrefix("renderer.firstPCM epoch=802")})
            RunLoop.current.run(until:Date().addingTimeInterval(0.3))
            stale=e.all().dropFirst(new+1).filter{$0.hasPrefix("state=") && $0.hasSuffix("epoch=801")}.count
            XCTAssertEqual(stale,0)
            XCTAssertGreaterThan(second.snapshot().1,0)
        }
        let stopFrom=e.all().count
        h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=\(reload ? 802:801)",after:stopFrom))
        print("G0_4B96_CONTROL scenario=\(name) held=true firstPCMBefore=\(first) woke=true ordered=true stale=\(stale) stopped=true")
        print("G0_4B96_OBSERVATION scenario=\(name) offset=\(offset ?? -1) requests=\(requests) probe=\(probe) commandMS=\(ms) oldFailures=\(failures.count) failures=\(failures.joined(separator:";"))")
#else
        throw XCTSkip("runner-only cancellation overlay")
#endif
    }
    func testOpenStop()throws{try run("OpenStop")}
    func testRefillStop()throws{try run("RefillStop")}
    func testReload()throws{try run("Reload")}
    func testStopTwice()throws{try run("StopTwice")}
}
