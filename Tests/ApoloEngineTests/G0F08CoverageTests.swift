import AetherLibavcodec
import AetherLibavutil
import Foundation
import XCTest

final class G0F08CoverageTests:XCTestCase{
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    func testG0F08FAudioRegistryCoverage()throws{
        // Historical evidence ledger, not a rerun of the referenced experiments.
        // bridge = actual CoreMedia path exercised within stated scope.
        // raw_only = explicitly selected native decoder, not actual bridge.
        // lifecycle_only = registration/incomplete context observation only.
        let ledger:[(String,String,String,String)]=[
            ("aac","bridge","F03A.3","7139344979"),
            ("aac_latm","bridge","F08A","7153800916"),
            ("ac3","bridge","F08A","7153800916"),
            ("adpcm_swf","bridge","F08D.1","7157872761"),
            ("alac","bridge","F02A","7123140227"),
            ("amrnb","bridge","F08D.2","7158785862"),
            ("amrwb","bridge","F08D.2","7158785862"),
            ("ape","bridge","F02B","7126112825"),
            ("atrac3","lifecycle_only","F08D.3.2","7167729776"),
            ("cook","lifecycle_only","F08D.3.2","7167729776"),
            ("dca","bridge","F08C","7155209160"),
            ("eac3","bridge","F08A","7153800916"),
            ("flac","bridge","B03/R14","7123140227"),
            ("mlp","bridge","F08C","7155209160"),
            ("mp1","bridge","F08D.2","7158785862"),
            ("mp2","bridge","F08D.1","7157872761"),
            ("mp3","raw_only","F08D.2","7158785862"),
            ("mp3float","bridge","F08D.2","7158785862"),
            ("mpc7","bridge","F08D.3.1","7163351722"),
            ("mpc8","bridge","F03B.3","7141789890"),
            ("nellymoser","bridge","F08D.1","7157872761"),
            ("opus","bridge","F03A.3","7139344979"),
            ("pcm_alaw","bridge","F08B","7154815913"),
            ("pcm_bluray","bridge","F08E","7168127811"),
            ("pcm_dvd","bridge","F08E","7168127811"),
            ("pcm_f32be","bridge","F08B","7154815913"),
            ("pcm_f32le","bridge","F08B","7154815913"),
            ("pcm_f64be","bridge","F08B","7154815913"),
            ("pcm_f64le","bridge","F08B","7154815913"),
            ("pcm_mulaw","bridge","F08B","7154815913"),
            ("pcm_s16be","bridge","F01","7122490880"),
            ("pcm_s16le","bridge","F01","7122490880"),
            ("pcm_s24be","bridge","F01","7122490880"),
            ("pcm_s24le","bridge","F01","7122490880"),
            ("pcm_s32be","bridge","F08B","7154815913"),
            ("pcm_s32le","bridge","F08B","7154815913"),
            ("pcm_s8","bridge","F08B","7154815913"),
            ("pcm_u8","bridge","F08B","7154815913"),
            ("ralf","lifecycle_only","F08D.3.2","7167729776"),
            ("real_144","bridge","F08D.1","7157872761"),
            ("real_288","lifecycle_only","F08D.3.2","7167729776"),
            ("sipr","lifecycle_only","F08D.3.2","7167729776"),
            ("speex","bridge","F08D.1","7157872761"),
            ("tak","lifecycle_only","F08D.3.2","7167729776"),
            ("truehd","bridge","F08C","7155209160"),
            ("tta","bridge","F02A","7123140227"),
            ("vorbis","bridge","F03B.3","7141789890"),
            ("wavpack","bridge","F02A","7123140227"),
            ("wmalossless","lifecycle_only","F08D.3.2","7167729776"),
            ("wmapro","lifecycle_only","F08D.3.2","7167729776"),
            ("wmav1","bridge","F08A","7153800916"),
            ("wmav2","bridge","F08A","7153800916"),
            ("wmavoice","lifecycle_only","F08D.3.2","7167729776")
        ]
        let expected=Set(ledger.map{$0.0})
        XCTAssertEqual(ledger.count,53)
        XCTAssertEqual(expected.count,ledger.count)
        var opaque:UnsafeMutableRawPointer?
        var actual=Set<String>()
        var entries=0
        while let c=av_codec_iterate(&opaque){
            if c.pointee.type==AVMEDIA_TYPE_AUDIO && av_codec_is_decoder(c) != 0{
                entries+=1
                let name=String(cString:c.pointee.name)
                XCTAssertTrue(actual.insert(name).inserted)
            }
        }
        let missing=expected.subtracting(actual).sorted()
        let unmapped=actual.subtracting(expected).sorted()
        for name in missing{print("G0_F08F_MISSING name=\(name)")}
        for name in unmapped{print("G0_F08F_UNMAPPED name=\(name)")}
        var bridge=0,rawOnly=0,lifecycleOnly=0
        for (name,status,stage,issue) in ledger{
            guard actual.contains(name) else{continue}
            let codec=try XCTUnwrap(avcodec_find_decoder_by_name(name))
            let selected=try XCTUnwrap(avcodec_find_decoder(codec.pointee.id))
            switch status{
            case "bridge":bridge+=1
            case "raw_only":rawOnly+=1
            case "lifecycle_only":lifecycleOnly+=1
            default:XCTFail("Unclassified codec \(name)")
            }
            print("G0_F08F_ENTRY name=\(name) category=\(status) stage=\(stage) issue=\(issue) default=\(String(cString:selected.pointee.name))")
        }
        print("G0_F08F_SUMMARY entries=\(entries) bridge=\(bridge) rawOnly=\(rawOnly) lifecycleOnly=\(lifecycleOnly) missing=\(missing.count) unmapped=\(unmapped.count) newDecodes=0")
        XCTAssertEqual(entries,53)
        XCTAssertEqual(actual,expected)
        XCTAssertEqual(bridge,43)
        XCTAssertEqual(rawOnly,1)
        XCTAssertEqual(lifecycleOnly,9)
    }
}
