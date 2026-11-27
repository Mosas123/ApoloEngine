import Foundation
import Network
import Darwin
import XCTest
import AetherLibavformat
@testable import ApoloEngine

/// Real HTTP host cancellation with a runner-only per-load cancellation token.
final class G0CancelSemanticsTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B97_EVENT \(s)")}
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
        func release(fail:Bool=false){
            lock.lock();released=true;let p=pending;pending=nil;lock.unlock()
            if let p{send(p.0,fail ? Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8):p.1)}
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
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_CANCEL_SEMANTICS"]=="1")
    }
    private func fixture(seconds:Double=20)->Data{
        let rate=48000,n=Int(Double(rate)*seconds)
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
#if G0_CANCEL_SEMANTICS
        print("G0_4B97_PROCESS pid=\(getpid()) scenario=\(name)")
        let e=Events(),d=AudioDiagnostics(),h=host(e,d)
        let server=RangeServer(fixture())
        defer{server.release();server.close();h.stop()}
        let url=try server.start()
        if name=="PreCancelled"{
            let token=G0FiniteCancellation()
            token.cancel()
            XCTAssertTrue(token.isCancelled)
            do{
                let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral,diagnostics:d,g0FiniteCancellation:token)
                source.close();XCTFail("cancelled registration must reject open")
            }catch{XCTAssertEqual((error as? URLError)?.code,.cancelled)}
            XCTAssertEqual(server.snapshot().1,0)
            XCTAssertNotNil(e.wait("g0.registrationRejected",timeout:1))
            print("G0_4B97_CONTROL scenario=\(name) rejected=true requests=0")
            print("G0_4B97_OBSERVATION scenario=\(name) cancelledBeforeRegister=true")
            return
        }
        if name=="NaturalEOF"{
            let local=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
            try fixture(seconds:0.5).write(to:local)
            defer{try? FileManager.default.removeItem(at:local)}
            h.load(url:local,httpHeaders:[:],epoch:901)
            _=try XCTUnwrap(e.wait("state=finished epoch=901",timeout:12))
            let before=e.all()
            XCTAssertEqual(before.filter{$0.hasPrefix("state=finished")}.count,1)
            XCTAssertFalse(before.contains{$0.hasPrefix("state=failed") || $0.hasPrefix("g0.suppressed")})
            let from=before.count;h.stop()
            _=try XCTUnwrap(e.wait("state=idle epoch=901",after:from))
            print("G0_4B97_CONTROL scenario=\(name) finished=1 failed=0 stopped=true")
            print("G0_4B97_OBSERVATION scenario=\(name) naturalEOF=true")
            return
        }
        let refill=name=="RefillStop" || name=="RefillFailure" || name=="Reload"
        let failure=name.hasSuffix("Failure"),reload=name=="Reload"
        if refill{
            let token=G0FiniteCancellation()
            let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral,diagnostics:d,g0FiniteCancellation:token)
            h.g0Attach(token);server.arm();h.load(source:source,epoch:901)
        }else{server.arm();h.load(url:url,httpHeaders:[:],epoch:901)}
        guard server.held.wait(timeout:.now()+25) == .success else{throw NSError(domain:"G0Held",code:1)}
        let first=e.all().contains{$0.hasPrefix("renderer.firstPCM epoch=901")}
        XCTAssertEqual(first,refill)
        let second=RangeServer(fixture())
        defer{second.close()}
        let nextURL=try second.start()
        let from=e.all().count,t0=DispatchTime.now().uptimeNanoseconds
        if failure{server.release(fail:true)}
        else if reload{h.load(url:nextURL,httpHeaders:[:],epoch:902)}
        else{h.stop()}
        let expected=failure ? "state=failed":(reload ? "renderer.firstPCM epoch=902":"state=idle epoch=901")
        let woke=e.wait(expected,after:from,timeout:failure ? 12:3) != nil
        let ms=Double(DispatchTime.now().uptimeNanoseconds-t0)/1e6
        if !failure{server.release()}
        XCTAssertTrue(woke)
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        let captured=Array(e.all().dropFirst(from))
        let failed=captured.filter{$0.hasPrefix("state=failed") && $0.hasSuffix("epoch=901")}
        let finished=captured.filter{$0.hasPrefix("state=finished") && $0.hasSuffix("epoch=901")}
        let suppressed=captured.filter{$0.hasPrefix("g0.suppressed")}
        XCTAssertEqual(failed.count,failure ? 1:0)
        XCTAssertTrue(finished.isEmpty)
        if failure{
            XCTAssertTrue(suppressed.isEmpty)
            XCTAssertTrue(captured.contains{$0.hasPrefix("http.range ") && $0.contains("status=403")})
            XCTAssertFalse(captured.contains{$0.hasPrefix("g0.cancelSession")})
        }else{
            XCTAssertFalse(suppressed.isEmpty)
            let c=try XCTUnwrap(captured.firstIndex{$0.hasPrefix("g0.cancelSession")})
            let r=try XCTUnwrap(captured.firstIndex{$0.hasPrefix("g0.cancelRequestReturned")})
            let o=try XCTUnwrap(captured.firstIndex{$0.hasPrefix("g0.cancelOwnerClose")})
            XCTAssertLessThan(c,r);XCTAssertLessThan(r,o)
        }
        if reload{
            let new=try XCTUnwrap(captured.firstIndex{$0.hasPrefix("renderer.firstPCM epoch=902")})
            XCTAssertFalse(captured.dropFirst(new+1).contains{$0.hasPrefix("state=") && $0.hasSuffix("epoch=901")})
            XCTAssertGreaterThan(second.snapshot().1,0)
        }
        let stopFrom=e.all().count;h.stop()
        _=try XCTUnwrap(e.wait("state=idle epoch=\(reload ? 902:901)",after:stopFrom))
        print("G0_4B97_CONTROL scenario=\(name) held=true firstPCMBefore=\(first) failed=\(failed.count) finished=\(finished.count) suppressed=\(!suppressed.isEmpty) completed=true stopped=true")
        print("G0_4B97_OBSERVATION scenario=\(name) commandMS=\(ms) suppressedCount=\(suppressed.count) errors=\(failed.joined(separator:";"))")
#else
        throw XCTSkip("runner-only semantic overlay")
#endif
    }
    func testOpenStop()throws{try run("OpenStop")}
    func testRefillStop()throws{try run("RefillStop")}
    func testReload()throws{try run("Reload")}
    func testOpenFailure()throws{try run("OpenFailure")}
    func testRefillFailure()throws{try run("RefillFailure")}
    func testNaturalEOF()throws{try run("NaturalEOF")}
    func testPreCancelled()throws{try run("PreCancelled")}
}
