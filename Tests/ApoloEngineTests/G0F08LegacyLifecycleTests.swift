import AetherLibavcodec
import AetherLibavutil
import Darwin
import Foundation
import XCTest

final class G0F08LegacyLifecycleTests:XCTestCase{
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    func testG0F08D32LegacyLifecycle()throws{
        // These are deliberately incomplete contexts, not valid codec fixtures.
        // No extradata or compressed bytes are supplied; no successful decoding
        // or full malformed-input coverage is inferred from this experiment.
        let profiles:[(String,Int32,Int32)]=[
            ("atrac3",44100,2),("cook",44100,2),("ralf",44100,2),
            ("real_288",8000,1),("sipr",8000,1),("tak",44100,2),
            ("wmalossless",44100,2),("wmapro",44100,2),("wmavoice",16000,1)
        ]
        let eof:Int32 = -541478725
        var registered=0,attempted=0,opened=0,rejected=0,freed=0,unexpectedPCM=0
        for (name,rate,channels) in profiles{
            let codec=try XCTUnwrap(avcodec_find_decoder_by_name(name))
            XCTAssertEqual(String(cString:codec.pointee.name),name)
            XCTAssertEqual(codec.pointee.type,AVMEDIA_TYPE_AUDIO)
            XCTAssertNotEqual(av_codec_is_decoder(codec),0)
            let defaultCodec=try XCTUnwrap(avcodec_find_decoder(codec.pointee.id))
            let defaultName=String(cString:defaultCodec.pointee.name)
            registered+=1
            print("G0_F08D32_REGISTRY name=\(name) id=\(codec.pointee.id.rawValue) default=\(defaultName)")
            for mode in ["empty","nominal"]{
                for iteration in 0..<4{
                    attempted+=1
                    var owner=avcodec_alloc_context3(codec)
                    var frameOwner=av_frame_alloc()
                    defer{av_frame_free(&frameOwner);avcodec_free_context(&owner)}
                    let ctx=try XCTUnwrap(owner)
                    let frame=try XCTUnwrap(frameOwner)
                    ctx.pointee.thread_count=1
                    if mode=="nominal"{
                        ctx.pointee.sample_rate=rate
                        av_channel_layout_default(&ctx.pointee.ch_layout,channels)
                        ctx.pointee.pkt_timebase=AVRational(num:1,den:rate)
                    }
                    XCTAssertNil(ctx.pointee.extradata)
                    XCTAssertEqual(ctx.pointee.extradata_size,0)
                    let rc=avcodec_open2(ctx,codec,nil)
                    var before:Int32?,sent:Int32?,after:Int32?,againAfter:Int32?
                    if rc>=0{
                        opened+=1
                        XCTAssertNotEqual(avcodec_is_open(ctx),0)
                        // Receive before sending anything: no audio is expected.
                        let r=avcodec_receive_frame(ctx,frame)
                        before=r
                        if r>=0{unexpectedPCM+=1;av_frame_unref(frame)}
                        // Legal EOF signal, not an invalid compressed packet.
                        let s=avcodec_send_packet(ctx,nil)
                        sent=s
                        if s>=0 || s==eof{
                            let d=avcodec_receive_frame(ctx,frame)
                            after=d
                            if d>=0{unexpectedPCM+=1;av_frame_unref(frame)}
                            if d==eof{againAfter=avcodec_receive_frame(ctx,frame)}
                        }
                    }else{
                        rejected+=1
                    }
                    av_frame_free(&frameOwner)
                    avcodec_free_context(&owner)
                    let cleared=owner==nil && frameOwner==nil
                    if cleared{freed+=1}
                    XCTAssertTrue(cleared)
                    print("G0_F08D32_CASE codec=\(name) mode=\(mode) iteration=\(iteration) open=\(rc) before=\(before.map(String.init) ?? "na") sendEOF=\(sent.map(String.init) ?? "na") after=\(after.map(String.init) ?? "na") repeatEOF=\(againAfter.map(String.init) ?? "na") freed=\(cleared)")
                    // Report actual return codes without assuming open must fail.
                    if let before{XCTAssertLessThan(before,0)}
                    if let after{XCTAssertLessThan(after,0)}
                    if let againAfter{XCTAssertEqual(againAfter,eof)}
                }
            }
        }
        print("G0_F08D32_SUMMARY registered=\(registered) attempted=\(attempted) opened=\(opened) rejected=\(rejected) freed=\(freed) unexpectedPCM=\(unexpectedPCM) compressedFixtures=0")
        XCTAssertEqual(registered,9)
        XCTAssertEqual(attempted,72)
        XCTAssertEqual(opened+rejected,attempted)
        XCTAssertEqual(freed,attempted)
        XCTAssertEqual(unexpectedPCM,0)
    }
}
