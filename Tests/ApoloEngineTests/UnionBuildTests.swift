import AetherLibavcodec
import AetherLibavfilter
import AetherLibavformat
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

    func testMusicDemuxersArePresent() {
        for name in ["ape", "tta", "wav", "aiff", "tak", "mpc", "mpc8"] {
            let format = name.withCString {
                av_find_input_format($0)
            }
            XCTAssertNotNil(format, "missing \(name) demuxer")
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
