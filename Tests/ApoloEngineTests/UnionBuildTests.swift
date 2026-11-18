import AetherLibavcodec
import AetherLibavfilter
import XCTest
@testable import ApoloEngine

/// These assert that the fork's FFmpeg really carries the union: the formats
/// and filters mpv exposes that the reference build did not.
final class UnionBuildTests: XCTestCase {
    func testMusicDecodersArePresent() {
        for name in ["ape", "tta", "wavpack", "tak", "mpc7", "mpc8"] {
            let decoder = name.withCString {
                avcodec_find_decoder_by_name($0)
            }
            XCTAssertNotNil(decoder, "missing \(name) decoder")
        }
    }

    func testMusicFiltersArePresent() {
        for name in [
            "equalizer", "superequalizer", "firequalizer",
            "loudnorm", "dynaudnorm", "crossfeed",
            "highpass", "lowpass",
        ] {
            let filter = name.withCString {
                avfilter_get_by_name($0)
            }
            XCTAssertNotNil(filter, "missing \(name) filter")
        }
    }
}
