import AVFoundation
import XCTest
@testable import ApoloEngine

final class LiveTimedMetadataTests: XCTestCase {
    func testIsolatedMetadataExperimentOnlyAttachesForHLS() {
        // The general beta must retain its safe opt-out. This experimental
        // branch intentionally enables narrow collection solely for HLS.
        XCTAssertTrue(AVPlayerHost.nativeHLSTimedMetadataEnabled)
        let hls = ApoloTrack(
            url: URL(string: "https://radio.example/live.m3u8")!,
            streamMode: .live
        )
        let hintedHLS = ApoloTrack(
            url: URL(string: "https://radio.example/opaque")!,
            sourceMIMEType: "application/vnd.apple.mpegurl; charset=utf-8",
            streamMode: .live
        )
        let mp3 = ApoloTrack(
            url: URL(string: "https://radio.example/live.mp3")!,
            streamMode: .live
        )
        let aac = ApoloTrack(
            url: URL(string: "https://radio.example/live.aac")!,
            streamMode: .live
        )
        let normalMusic = ApoloTrack(
            url: URL(string: "https://radio.example/song.m3u8")!
        )
        XCTAssertTrue(AVPlayerHost.shouldCollectNativeHLSTimedMetadata(for: hls))
        XCTAssertTrue(AVPlayerHost.shouldCollectNativeHLSTimedMetadata(for: hintedHLS))
        XCTAssertFalse(AVPlayerHost.shouldCollectNativeHLSTimedMetadata(for: mp3))
        XCTAssertFalse(AVPlayerHost.shouldCollectNativeHLSTimedMetadata(for: aac))
        XCTAssertFalse(AVPlayerHost.shouldCollectNativeHLSTimedMetadata(for: normalMusic))
    }

    func testAcceptsID3SongTitle() {
        let item = metadata(.id3MetadataTitleDescription, "Artist - Song")
        XCTAssertEqual(LiveTimedMetadata.title(in: [item]), "Artist - Song")
    }

    func testAcceptsCommonTitle() {
        let item = metadata(.commonIdentifierTitle, "On Air")
        XCTAssertEqual(LiveTimedMetadata.title(in: [item]), "On Air")
    }

    func testIgnoresAlbumArtworkAndOtherNonTitleFields() {
        let item = metadata(.id3MetadataAlbumTitle, "Station Album")
        XCTAssertNil(LiveTimedMetadata.title(in: [item]))
    }

    func testPrefersLatestRecognizedTitle() {
        let old = metadata(.id3MetadataTitleDescription, "Old Song")
        let new = metadata(.id3MetadataTitleDescription, "New Song")
        XCTAssertEqual(LiveTimedMetadata.title(in: [old, new]), "New Song")
    }

    func testSanitizesControlsAndBoundsText() {
        XCTAssertEqual(LiveTimedMetadata.sanitize("  Now\nPlaying\u{0000} "), "NowPlaying")
        XCTAssertEqual(LiveTimedMetadata.sanitize(String(repeating: "X", count: 400))?.count, 256)
        XCTAssertNil(LiveTimedMetadata.sanitize("  \n\t\u{0000} "))
    }

    func testEmptyTitleFallsBackToPreviousRecognizedTitle() {
        let valid = metadata(.id3MetadataTitleDescription, "Previous Track")
        let blank = metadata(.id3MetadataTitleDescription, "   ")
        XCTAssertEqual(LiveTimedMetadata.title(in: [valid, blank]), "Previous Track")
    }

    private func metadata(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        return item
    }
}
