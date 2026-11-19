import Foundation
import XCTest
@testable import ApoloEngine

final class LegacyICYHeaderParserTests: XCTestCase {
    func testICYHeaderSplitsAcrossEveryByteBoundary() throws {
        let response = Data(
            "ICY 200 OK\r\nicy-name: Test FM\r\nicy-metaint: 4\r\nContent-Type: audio/ogg\r\n\r\nABCD".utf8
        )
        for position in 1..<response.count {
            var parser = LegacyICYHeaderParser()
            XCTAssertNil(try parser.consume(Data(response.prefix(position))))
            let result = try XCTUnwrap(
                parser.consume(Data(response.dropFirst(position)))
            )
            XCTAssertEqual(result.statusCode, 200)
            XCTAssertEqual(result.header("ICY-METAINT"), "4")
            XCTAssertEqual(result.header("content-type"), "audio/ogg")
            XCTAssertEqual(result.initialAudio, Data("ABCD".utf8))
        }
    }

    func testLFOnlyLegacyHeaders() throws {
        var parser = LegacyICYHeaderParser()
        let reply = try XCTUnwrap(parser.consume(
            Data("ICY 200 OK\nicy-metaint: 0\n\nxyz".utf8)
        ))
        XCTAssertEqual(reply.statusCode, 200)
        XCTAssertEqual(reply.initialAudio, Data("xyz".utf8))
    }

    func testNonSuccessStatusIsAvailableForTerminalClassification() throws {
        var parser = LegacyICYHeaderParser()
        let reply = try XCTUnwrap(parser.consume(
            Data("ICY 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n".utf8)
        ))
        XCTAssertEqual(reply.statusCode, 403)
    }

    func testRejectsRegularHTTPAndInvalidStatus() {
        for reply in [
            "HTTP/1.1 200 OK\r\n\r\n",
            "ICY BAD\r\n\r\n",
            "ICY 20 OK\r\n\r\n"
        ] {
            var parser = LegacyICYHeaderParser()
            XCTAssertThrowsError(try parser.consume(Data(reply.utf8))) {
                XCTAssertEqual(
                    $0 as? LegacyICYHeaderParser.Failure,
                    .invalidStatus
                )
            }
        }
    }

    func testRejectsDuplicateMetadataIntervalAndFoldedHeaders() {
        for reply in [
            "ICY 200 OK\r\nicy-metaint: 8\r\nicy-metaint: 0\r\n\r\n",
            "ICY 200 OK\r\n secret: foo\r\nfolded\r\n\r\n"
        ] {
            var parser = LegacyICYHeaderParser()
            XCTAssertThrowsError(try parser.consume(Data(reply.utf8))) {
                XCTAssertEqual(
                    $0 as? LegacyICYHeaderParser.Failure,
                    .malformedHeaders
                )
            }
        }
    }

    func testHeaderSizeIsHardCapped() {
        var parser = LegacyICYHeaderParser()
        let header = "ICY 200 OK\r\nX: " + String(repeating: "a", count: 17_000)
        XCTAssertThrowsError(try parser.consume(Data(header.utf8))) {
            XCTAssertEqual(
                $0 as? LegacyICYHeaderParser.Failure,
                .headersTooLarge
            )
        }
    }

    func testIncompleteHeaderDoesNotEmitAudio() throws {
        var parser = LegacyICYHeaderParser()
        XCTAssertNil(try parser.consume(Data("ICY 200 OK\r\nicy-metaint: 4".utf8)))
        XCTAssertNil(try parser.consume(Data("\r\n".utf8)))
        let result = try XCTUnwrap(parser.consume(Data("\r\nA".utf8)))
        XCTAssertEqual(result.initialAudio, Data("A".utf8))
    }
}
