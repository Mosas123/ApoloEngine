import Foundation
import XCTest
@testable import ApoloEngine

final class LiveStationPlaylistTests: XCTestCase {
    private let base = URL(string: "https://station.example/radio/listen.m3u?token=secret")!

    func testPlaylistRecognitionIsExplicitAndDoesNotStealHLS() {
        XCTAssertTrue(LiveStationPlaylist.isPlaylist(base))
        XCTAssertTrue(LiveStationPlaylist.isPlaylist(
            URL(string: "https://radio.example/list.pls")!
        ))
        XCTAssertTrue(LiveStationPlaylist.isPlaylist(
            URL(string: "https://radio.example/listen")!,
            hint: "audio/x-scpls; charset=UTF-8"
        ))
        XCTAssertFalse(LiveStationPlaylist.isPlaylist(
            URL(string: "https://radio.example/master.m3u8")!,
            hint: "application/vnd.apple.mpegurl"
        ))
        XCTAssertFalse(LiveStationPlaylist.isPlaylist(
            URL(string: "https://radio.example/listen.mp3")!
        ))
        XCTAssertFalse(LiveStationPlaylist.isPlaylist(
            URL(fileURLWithPath: "/tmp/list.m3u")
        ))
    }

    func testM3UParsesCommentsAndRelativeStations() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1,First Station
        https://cdn.example/stream.ogg?token=xyz
        # some comment
        /fallback.mp3

        """
        let entries = try LiveStationPlaylist.entries(
            from: Data(text.utf8), url: base
        )
        XCTAssertEqual(entries.map(\.absoluteString), [
            "https://cdn.example/stream.ogg?token=xyz",
            "https://station.example/fallback.mp3",
        ])
    }

    func testPLSUsesNumericFileOrderNotMetadataOrder() throws {
        let text = """
        [playlist]
        Title2=Second
        File2=https://radio.example/second.mp3
        NumberOfEntries=2
        File1=https://radio.example/first.opus
        Version=2
        """
        let entries = try LiveStationPlaylist.entries(
            from: Data(text.utf8),
            url: URL(string: "https://station.example/list.pls")!
        )
        XCTAssertEqual(entries.map(\.lastPathComponent), ["first.opus", "second.mp3"])
    }

    func testDiscardsNonHTTPAndEmbeddedCredentials() throws {
        let text = """
        #EXTM3U
        file:///etc/passwd
        ftp://example.com/stream
        https://user:password@other.example/stream
        https://radio.example/stream.mp3
        """
        let entries = try LiveStationPlaylist.entries(
            from: Data(text.utf8), url: base
        )
        XCTAssertEqual(entries.map(\.absoluteString), [
            "https://radio.example/stream.mp3",
        ])
    }

    func testRejectsEmptyAndHLSMediaManifests() {
        XCTAssertThrowsError(try LiveStationPlaylist.entries(
            from: Data("#EXTM3U\n#EXTINF:-1,Bad\nfile:///tmp/a".utf8),
            url: base
        )) { error in
            XCTAssertEqual(error as? LiveStationPlaylist.Failure, .noPlayableEntry)
        }
        XCTAssertThrowsError(try LiveStationPlaylist.entries(
            from: Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment001.ts".utf8),
            url: base
        )) { error in
            XCTAssertEqual(error as? LiveStationPlaylist.Failure, .hlsManifest)
        }
    }

    func testOriginControlsHeaderForwarding() {
        let same = URL(string: "https://STATION.example:443/stream.mp3")!
        let otherHost = URL(string: "https://cdn.example/stream.mp3")!
        let otherScheme = URL(string: "http://station.example/stream.mp3")!
        let otherPort = URL(string: "https://station.example:8443/stream.mp3")!
        XCTAssertTrue(LiveStationPlaylist.sameOrigin(base, same))
        XCTAssertFalse(LiveStationPlaylist.sameOrigin(base, otherHost))
        XCTAssertFalse(LiveStationPlaylist.sameOrigin(base, otherScheme))
        XCTAssertFalse(LiveStationPlaylist.sameOrigin(base, otherPort))
    }

    func testURLWithUserInfoCannotBeLoaded() {
        XCTAssertNil(LiveStationPlaylist.validatedURL(
            "https://person:secret@station.example/audio", relativeTo: base
        ))
    }
}
