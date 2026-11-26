import Foundation
import XCTest
@testable import ApoloEngine

final class G0F09ICYFragmentationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    func testHeaderBodyBoundaryInvariance() throws {
        // Reference boundary is the end of the known generated header, not
        // a second invocation of the parser being investigated.
        let payloads: [(String, Data)] = [
            ("plain", Data([0,255,42,11,13,10])),
            ("binaryDelimiter", Data([0,13,10,13,10,255,42])),
            ("leadingDelimiter", Data([13,10,13,10,0,255,42])),
            ("headerLikeBody", Data("X-Fake: value\r\n\r\n".utf8) + Data([0,255,42])),
            ("twoDelimiters", Data([0,13,10,13,10,13,10,13,10,255,42]))
        ]
        var total = 0
        var exact = 0
        var rejected = 0
        var silent = 0
        var incomplete = 0
        for ending in ["LF","CRLF"] {
            let sep = ending == "LF" ? "\n" : "\r\n"
            let header = Data(("ICY 200 OK" + sep + "Content-Type: audio/ogg" + sep + sep).utf8)
            for (name, body) in payloads {
                let wire = header + body
                // Single split at every byte boundary plus one-byte chunks
                // and a coalesced response. Once parsed, body is passed on
                // unchanged, as in LegacyICYConnection.consume.
                for split in 0...wire.count {
                    let chunks = split == 0 ? wire.map { Data([$0]) } :
                        [Data(wire.prefix(split)),Data(wire.dropFirst(split))]
                    var parser = LegacyICYHeaderParser()
                    var got = Data()
                    var found = false
                    var status = 0
                    var fakeHeader = false
                    var failure = "none"
                    do {
                        for chunk in chunks where !chunk.isEmpty {
                            if found { got.append(chunk) }
                            else if let response = try parser.consume(chunk) {
                                found = true
                                status = response.statusCode
                                fakeHeader = response.header("x-fake") != nil
                                got.append(response.initialAudio)
                            }
                        }
                    } catch { failure = String(describing: error) }
                    let ok = found && status == 200 && got == body && !fakeHeader && failure == "none"
                    let kind: String
                    if ok { exact += 1; kind = "exact" }
                    else if failure != "none" { rejected += 1; kind = "rejected" }
                    else if found { silent += 1; kind = "silentMismatch" }
                    else { incomplete += 1; kind = "incomplete" }
                    total += 1
                    print("G0_F09F51_CASE ending=\(ending) body=\(name) split=\(split) headerBytes=\(header.count) wireBytes=\(wire.count) result=\(kind) failure=\(failure) expected=\(body.count) actual=\(got.count) fakeHeader=\(fakeHeader) hex=\(got.map { String(format: "%02x", $0) }.joined())")
                }
            }
        }
        print("G0_F09F51_SUMMARY total=\(total) exact=\(exact) rejected=\(rejected) silent=\(silent) incomplete=\(incomplete)")
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(total, exact + rejected + silent + incomplete)
        XCTAssertEqual(exact, total, "valid header/body framing must be invariant to transport fragmentation")
    }
}
