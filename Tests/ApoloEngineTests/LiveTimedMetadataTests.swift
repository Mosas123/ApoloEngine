import AVFoundation
import XCTest
@testable import ApoloEngine

final class LiveTimedMetadataTests: XCTestCase {
    func testDeviceBetaDoesNotAttachUnsafeNativeMetadataOutput() {
        // Physical iOS 27.0.1 crash stack points into AVFCore's
        // AVPlayerItemMetadataOutput private callback. ICY metadata remains
        // available on the separate FFmpeg transport.
        XCTAssertFalse(AVPlayerHost.nativeHLSTimedMetadataEnabled)
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
