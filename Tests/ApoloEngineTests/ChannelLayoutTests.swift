import AetherLibavutil
import XCTest
@testable import ApoloEngine

final class ChannelLayoutTests: XCTestCase {
    func testSevenChannelsUseSixOneBack() {
        var layout = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels: 7, into: &layout)
        defer { av_channel_layout_uninit(&layout) }

        XCTAssertEqual(layout.nb_channels, 7)

        var buffer = [CChar](repeating: 0, count: 64)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            av_channel_layout_describe(
                &layout,
                pointer.baseAddress,
                pointer.count
            )
        }
        XCTAssertGreaterThanOrEqual(written, 0)

        let name = buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
        XCTAssertTrue(
            name.contains("6.1"),
            "expected the 6.1(back) layout, got \(name)"
        )
    }

    func testStereoUsesTheDefaultLayout() {
        var layout = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels: 2, into: &layout)
        defer { av_channel_layout_uninit(&layout) }

        XCTAssertEqual(layout.nb_channels, 2)
    }
}
