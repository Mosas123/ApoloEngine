import CoreMedia
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ApoloEngine

/// High-rate and conventional multichannel PCM accounting, not Atmos certification.
final class G0HighRateOwnershipTests:XCTestCase {
    override func setUpWithError()throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private enum Failure:Error{case invalid,unbounded,resource}
    private struct Fixture:Decodable {
        let file:String
        let codec:String
        let rate:Int
        let channels:Int
        let frames:Int
        let layout:String
        let sha256:String
        let reference:String
        let referenceSHA:String
        let lossless:Bool
    }
    private struct Retained {
        let buffer:CMSampleBuffer
        let address:UInt
        let bytes:Int
        let hash:String
    }
    private struct Result {
        let frames:Int
        let buffers:Int
        let hash:String
        let cpuUS:Int64
        let elapsed:UInt64
        let rssBefore:UInt64
        let rssAfter:UInt64
        let tag:UInt32
    }
    private func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func pointer(_ b:CMSampleBuffer)throws->(UnsafeMutablePointer<Int8>,Int) {
        let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(b))
        var p:UnsafeMutablePointer<Int8>?,n=0,total=0
        let status=CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:&n,totalLengthOut:&total,dataPointerOut:&p)
        guard status==0,n==total,total>0,let p else{throw Failure.invalid}
        return(p,total)
    }
    private func sample(_ url:URL,_ spec:Fixture,_ reference:Data,_ check:Bool,_ retain:Bool)throws->Result {
        let before=resourceSnapshotR16(),start=DispatchTime.now().uptimeNanoseconds
        let source=try OpenedSource.open(url:url,sessionConfiguration:.ephemeral)
        defer{source.close()}
        let track=try XCTUnwrap(source.info.audioTracks.first)
        XCTAssertEqual(track.codec,spec.codec)
        XCTAssertEqual(track.sampleRate,spec.rate);XCTAssertEqual(track.channels,spec.channels)
        let d=AudioDecoder();d.limiterEnabled=false
        defer{d.close()}
        try d.adopt(source)
        var frames=0,buffers=0,eof=false,tag:UInt32=0
        var h=SHA256(),held=[Retained](),addresses=Set<UInt>()
        var squared=0.0,maxError=0.0,compared=0
        let bpf=spec.channels*4
        for _ in 0..<4096 {
            guard let b=try d.readNextBuffer() else{eof=true;break}
            let n=CMSampleBufferGetNumSamples(b)
            guard n>0,frames+n<=spec.frames,
                  let desc=CMSampleBufferGetFormatDescription(b),
                  let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc) else{throw Failure.invalid}
            let a=asbd.pointee
            guard a.mFormatID==kAudioFormatLinearPCM,a.mSampleRate==Double(spec.rate),a.mChannelsPerFrame==UInt32(spec.channels),
                  a.mBitsPerChannel==32,a.mBytesPerFrame==UInt32(bpf),
                  (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0 else{throw Failure.invalid}
            var size=0
            let layout=try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(desc,sizeOut:&size))
            let t=layout.pointee.mChannelLayoutTag
            if buffers==0{tag=t}else{XCTAssertEqual(tag,t)}
            let (p,bytes)=try pointer(b)
            XCTAssertEqual(bytes,n*bpf)
            if check {
                let pcm=Data(bytes:p,count:bytes)
                h.update(data:pcm)
                let expected=reference.subdata(in:(frames*bpf)..<((frames+n)*bpf))
                if spec.lossless{XCTAssertEqual(pcm,expected,"independent source values/channel order")}
                else{
                    pcm.withUnsafeBytes{a in expected.withUnsafeBytes{e in
                        for i in 0..<(n*spec.channels) {
                            let x=a.loadUnaligned(fromByteOffset:i*4,as:Float.self)
                            let y=e.loadUnaligned(fromByteOffset:i*4,as:Float.self)
                            XCTAssertTrue(x.isFinite)
                            let delta=abs(Double(x)-Double(y))
                            squared+=delta*delta;maxError=max(maxError,delta);compared+=1
                        }
                    }}
                }
                if retain {
                    let addr=UInt(bitPattern:p)
                    XCTAssertTrue(addresses.insert(addr).inserted,"live blocks must not alias")
                    held.append(Retained(buffer:b,address:addr,bytes:bytes,hash:sha(pcm)))
                }
            }
            frames+=n;buffers+=1
        }
        XCTAssertTrue(eof);XCTAssertEqual(frames,spec.frames);XCTAssertNil(try d.readNextBuffer())
        d.close();source.close()
        let closed=DispatchTime.now().uptimeNanoseconds,after=resourceSnapshotR16()
        if retain {
            // All buffers remain alive after decoder/source close; verify payload and address.
            for item in held {
                let (p,n)=try pointer(item.buffer)
                XCTAssertEqual(UInt(bitPattern:p),item.address)
                XCTAssertEqual(n,item.bytes);XCTAssertEqual(sha(Data(bytes:p,count:n)),item.hash)
            }
            print("G0_4B41_HELD count=\(held.count) distinct=\(addresses.count) bytes=\(held.reduce(0){$0+$1.bytes}) afterClose=true")
        }
        if check && !spec.lossless {
            print("G0_4B41_LOSSY compared=\(compared) maxError=\(maxError) rms=\(sqrt(squared/Double(max(1,compared))))")
        }
        guard let c0=before.cpuUS,let c1=after.cpuUS,c1>=c0,let r0=before.residentBytes,let r1=after.residentBytes else{throw Failure.resource}
        return Result(frames:frames,buffers:buffers,hash:check ? h.finalize().map{String(format:"%02x",$0)}.joined():"untimed-only",cpuUS:c1-c0,elapsed:closed-start,rssBefore:r0,rssAfter:r1,tag:tag)
    }
    private func run(_ file:String)throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures/G04B41")).deletingLastPathComponent()
        let specs=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        let spec=try XCTUnwrap(specs.first{$0.file==file})
        let url=root.appendingPathComponent(file),ref=try Data(contentsOf:root.appendingPathComponent(spec.reference))
        XCTAssertEqual(sha(try Data(contentsOf:url)),spec.sha256);XCTAssertEqual(sha(ref),spec.referenceSHA)
        XCTAssertEqual(ref.count,spec.frames*spec.channels*4)
        let audit=ProcessInfo.processInfo.environment["APOLO_G0_COPY_AUDIT"]=="1"
        print("G0_4B41_PROCESS profile=\(file) pid=\(getpid()) audit=\(audit) rate=\(spec.rate) channels=\(spec.channels) layout=\(spec.layout) lossless=\(spec.lossless)")
        var referenceHash:String?
        func execute(_ index:Int,_ check:Bool)throws->Result {
            let r=try sample(url,spec,ref,check,audit)
            if check {
                if spec.lossless{XCTAssertEqual(r.hash,spec.referenceSHA)}
                if let referenceHash{XCTAssertEqual(r.hash,referenceHash)}else{referenceHash=r.hash}
            }
            print("G0_4B41_CASE profile=\(file) index=\(index) frames=\(r.frames) buffers=\(r.buffers) hash=\(r.hash) tag=\(r.tag) cpuUS=\(r.cpuUS) elapsedNS=\(r.elapsed) rssBefore=\(r.rssBefore) rssAfter=\(r.rssAfter)")
            return r
        }
        if audit{_=try execute(0,true)}
        else{
            _=try execute(-2,true);_=try execute(-1,false);_=try execute(0,false)
            var values=[Result]()
            for i in 1...10{values.append(try execute(i,false))}
            _=try execute(11,true)
            for (metric,v) in [("cpuUS",values.map{UInt64($0.cpuUS)}),("elapsedNS",values.map{$0.elapsed})]{
                let s=v.sorted()
                print("G0_4B41_STATS profile=\(file) metric=\(metric) n=10 p50=\(s[4]) p95=\(s[9]) min=\(s[0]) max=\(s[9])")
            }
        }
        print("G0_4B41_SUMMARY profile=\(file) audit=\(audit) cases=\(audit ? 1:14)")
    }
    func testWAV96()throws{try run("stereo96.wav")}
    func testWAV192()throws{try run("stereo192.wav")}
    func testFLAC96()throws{try run("stereo96.flac")}
    func testWAV51()throws{try run("surround51.wav")}
    func testFLAC71()throws{try run("surround71.flac")}
    func testEAC3()throws{try run("surround51.eac3")}
    private struct ResourceSnapshotR16 {
        let cpuUS: Int64?
        let residentBytes: UInt64?
        let maxRSS: Int64?
    }

    private func resourceSnapshotR16() -> ResourceSnapshotR16 {
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = Int64(usage.ru_utime.tv_sec) * 1_000_000
            + Int64(usage.ru_utime.tv_usec)
            + Int64(usage.ru_stime.tv_sec) * 1_000_000
            + Int64(usage.ru_stime.tv_usec)
        var basic = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ResourceSnapshotR16(
            cpuUS: usageOK ? cpu : nil,
            residentBytes: status == KERN_SUCCESS ? UInt64(basic.resident_size) : nil,
            maxRSS: usageOK ? Int64(usage.ru_maxrss) : nil
        )
    }


}
