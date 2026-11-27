import Foundation
import Network
import Darwin
import XCTest
import AetherLibavformat
@testable import ApoloEngine

/// Real loopback HTTP Range + unchanged host/AVIO. The only runner patch
/// exposes cancellation of the existing URLSession for the isolated AVIO test.
final class G0HTTPHostCancelTests:XCTestCase{
    private final class Events:@unchecked Sendable{
        private let lock=NSLock()
        private var entries=[String]()
        func add(_ s:String){lock.lock();entries.append(s);lock.unlock();print("G0_4B91_EVENT \(s)")}
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
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_HTTP_OVERLAY"]=="1")
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
    private func host(_ events:Events)->LibavcodecAudioHost{
        let diagnostics=AudioDiagnostics()
        diagnostics.setHandler{events.add($0)}
        return LibavcodecAudioHost(onState:{state,epoch in events.add("state=\(state) epoch=\(epoch)")},onTime:{_,_ in},onTrackChange:{_,epoch in events.add("trackChange epoch=\(epoch)")},diagnostics:diagnostics)
    }
    private func runHost(_ name:String,refill:Bool)throws{
        print("G0_4B91_PROCESS pid=\(getpid()) scenario=\(name)")
        let server=RangeServer(fixture())
        defer{server.release();server.close()}
        let url=try server.start(),e=Events(),h=host(e)
        defer{server.release();h.stop()}
        let epoch:UInt64=refill ? 402:401
        let startCount:Int
        if refill{
            let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
            startCount=server.snapshot().1
            server.arm()
            h.load(source:source,epoch:epoch)
        }else{
            startCount=0
            server.arm()
            h.load(url:url,httpHeaders:[:],epoch:epoch)
        }
        XCTAssertEqual(server.held.wait(timeout:.now()+25),.success,"real Range request held")
        let (offset,requests)=server.snapshot()
        guard let offset else{throw NSError(domain:"G0MissingRange",code:2)}
        XCTAssertGreaterThan(requests,startCount)
        let firstPCM=e.all().contains{$0.hasPrefix("renderer.firstPCM epoch=\(epoch)")}
        if refill{XCTAssertTrue(firstPCM,"refill must be after initial PCM")}
        else{XCTAssertFalse(firstPCM)}
        let from=e.all().count,t0=DispatchTime.now().uptimeNanoseconds
        h.stop()
        let early=e.wait("state=idle epoch=\(epoch)",after:from,timeout:0.25) != nil
        server.release()
        _=try XCTUnwrap(e.wait("state=idle epoch=\(epoch)",after:from,timeout:20))
        let elapsed=Double(DispatchTime.now().uptimeNanoseconds-t0)/1e6
        XCTAssertFalse(early)
        print("G0_4B91_CONTROL scenario=\(name) held=true firstPCMBefore=\(firstPCM) earlyIdle=\(early) stopped=true")
        print("G0_4B91_OBSERVATION scenario=\(name) offset=\(offset) requests=\(requests) probeRequests=\(startCount) stopMS=\(elapsed)")
    }
    func testOpenStop()throws{try runHost("OpenStop",refill:false)}
    func testRefillStop()throws{try runHost("RefillStop",refill:true)}
    func testDirectAVIOCancel()throws{
        print("G0_4B91_PROCESS pid=\(getpid()) scenario=DirectAVIOCancel")
        let server=RangeServer(fixture())
        defer{server.release();server.close()}
        let url=try server.start()
        server.arm()
        let stream=HTTPStream(url:url,headers:[:],configuration:.ephemeral)
        let transport=try XCTUnwrap(HTTPTransport(stream:stream))
        let done=DispatchSemaphore(value:0),result=ReadResult()
        DispatchQueue.global(qos:.userInitiated).async{
            defer{transport.close();done.signal()}
            guard let ctx=transport.context else{result.set(-999);return}
            var bytes=[UInt8](repeating:0,count:4096)
            let n=bytes.withUnsafeMutableBufferPointer{avio_read(ctx,$0.baseAddress,Int32($0.count))}
            result.set(n)
        }
        guard server.held.wait(timeout:.now()+10) == .success else{
            server.release();_ = done.wait(timeout:.now()+15)
            XCTFail("AVIO request not held");return
        }
        let t0=DispatchTime.now().uptimeNanoseconds
        // This diagnostic-only overlay cancels URLSession, not the AVIO owner.
        // AVIO is freed only by the worker after avio_read returns.
#if G0_HTTP_CANCEL_OVERLAY
        stream.g0InvalidateSession()
#else
        server.release();_ = done.wait(timeout:.now()+15)
        throw XCTSkip("runner-only overlay required")
#endif
        let woke=done.wait(timeout:.now()+3) == .success
        let elapsed=Double(DispatchTime.now().uptimeNanoseconds-t0)/1e6
        server.release()
        if !woke{_ = done.wait(timeout:.now()+15)}
        let code=result.get() ?? -999
        XCTAssertTrue(woke)
        XCTAssertEqual(code,-5)
        XCTAssertTrue(stream.hasError)
        print("G0_4B91_CONTROL scenario=DirectAVIOCancel held=true woke=\(woke) code=\(code) hasError=\(stream.hasError)")
        print("G0_4B91_OBSERVATION scenario=DirectAVIOCancel wakeMS=\(elapsed)")
    }
}
