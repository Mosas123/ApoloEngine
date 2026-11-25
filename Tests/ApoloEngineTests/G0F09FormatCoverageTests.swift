import AetherLibavformat
import Foundation
import XCTest

final class G0F09FormatCoverageTests:XCTestCase {
    override func setUpWithError()throws{
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    func testG0F09AFormatRegistryCoverage()throws{
        // Evidence ledger, not a new demux or mux test. A grouped name does
        // not certify every alias, codec combination, or seek/network route.
        let ledger:[(String,String,String,String)]=[
            ("aac","historical_audio","F03A.3","7139344979"),
            ("ac3","historical_audio","F08A","7153800916"),
            ("aiff","historical_audio","F01","7122490880"),
            ("ape","historical_audio","F02B","7126112825"),
            ("asf","historical_audio","F08A","7153800916"),
            ("ass","review_pending","F09","7153525598"),
            ("avi","review_pending","F09","7153525598"),
            ("data","review_pending","F09","7153525598"),
            ("dts","review_pending","F09","7153525598"),
            ("eac3","historical_audio","F08A","7153800916"),
            ("flac","historical_audio","B03/R14","7123140227"),
            ("flv","historical_audio","F08D.1","7157872761"),
            ("h264","review_pending","F09","7153525598"),
            ("hevc","review_pending","F09","7153525598"),
            ("hls","review_pending","F09","7153525598"),
            ("loas","historical_audio","F08A","7153800916"),
            ("m4v","review_pending","F09","7153525598"),
            ("matroska,webm","historical_audio","F03A.3/F08C","7155209160"),
            ("mov,mp4,m4a,3gp,3g2,mj2","historical_audio","F03A.3/F08D.2","7158785862"),
            ("mp3","historical_audio","F08D.2","7158785862"),
            ("mpc","historical_audio","F08D.3.1","7163351722"),
            ("mpc8","historical_audio","F03B.3","7141789890"),
            ("mpeg","historical_audio","F08E","7168127811"),
            ("mpegts","historical_audio","F08E","7168127811"),
            ("mpegvideo","review_pending","F09","7153525598"),
            ("ogg","historical_audio","F03A.3/F08D.1","7158392469"),
            ("rm","historical_audio","F08D.1","7157872761"),
            ("srt","review_pending","F09","7153525598"),
            ("sup","review_pending","F09","7153525598"),
            ("tak","review_pending","F09","7153525598"),
            ("truehd","review_pending","F09","7153525598"),
            ("tta","historical_audio","F02A","7123140227"),
            ("vobsub","review_pending","F09","7153525598"),
            ("wav","historical_audio","F01","7122490880"),
            ("webvtt","review_pending","F09","7153525598"),
            ("wv","historical_audio","F02A","7123140227")
        ]
        let muxExpected:Set<String>=["adts","hls","latm","mov","mp4","mpegts","webvtt"]
        let demuxExpected=Set(ledger.map{$0.0})
        var opaque:UnsafeMutableRawPointer?
        var demux=Set<String>(),mux=Set<String>()
        while let f=av_demuxer_iterate(&opaque){
            XCTAssertTrue(demux.insert(String(cString:f.pointee.name)).inserted)
        }
        opaque=nil
        while let f=av_muxer_iterate(&opaque){
            XCTAssertTrue(mux.insert(String(cString:f.pointee.name)).inserted)
        }
        for name in demuxExpected.subtracting(demux).sorted(){print("G0_F09A_MISSING type=demux name=\(name)")}
        for name in demux.subtracting(demuxExpected).sorted(){print("G0_F09A_UNMAPPED type=demux name=\(name)")}
        for name in muxExpected.subtracting(mux).sorted(){print("G0_F09A_MISSING type=mux name=\(name)")}
        for name in mux.subtracting(muxExpected).sorted(){print("G0_F09A_UNMAPPED type=mux name=\(name)")}
        var historical=0,pending=0,aliasCount=0
        for (name,category,stage,issue) in ledger{
            guard demux.contains(name) else{continue}
            let aliases=name.split(separator:",").map(String.init)
            for alias in aliases{
                let input=try XCTUnwrap(alias.withCString{av_find_input_format($0)})
                XCTAssertEqual(String(cString:input.pointee.name),name)
                aliasCount+=1
            }
            if category=="historical_audio"{historical+=1}else{pending+=1}
            print("G0_F09A_DEMUX name=\(name) category=\(category) stage=\(stage) issue=\(issue) aliases=\(aliases.count)")
        }
        for name in mux.sorted(){
            print("G0_F09A_MUX name=\(name) category=registry_only")
        }
        print("G0_F09A_SUMMARY demux=\(demux.count) mux=\(mux.count) historicalAudio=\(historical) reviewPending=\(pending) aliases=\(aliasCount) newDemux=0 newMux=0")
        XCTAssertEqual(ledger.count,36)
        XCTAssertEqual(demux,demuxExpected)
        XCTAssertEqual(mux,muxExpected)
        XCTAssertEqual(historical,21)
        XCTAssertEqual(pending,15)
        XCTAssertEqual(aliasCount,42)
    }
}
