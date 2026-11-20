import Foundation
import XCTest
@testable import ApoloEngine

final class LiveAudioBufferTests: XCTestCase {
    func testRingWrapKeepsByteOrder() {
        let buffer = LiveAudioBuffer(capacity: 8)
        XCTAssertTrue(buffer.append(Data([0, 1, 2, 3, 4, 5])))

        var first = [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(first.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 5, timeout: 0)
        }, 5)
        XCTAssertEqual(first, [0, 1, 2, 3, 4])

        XCTAssertTrue(buffer.append(Data([6, 7, 8, 9, 10, 11, 12])))
        var second = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(second.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 8, timeout: 0)
        }, 8)
        XCTAssertEqual(second, [5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(buffer.bufferedBytes, 0)
    }

    func testOverflowRejectsWithoutDroppingOrAllocating() {
        let buffer = LiveAudioBuffer(capacity: 4)
        XCTAssertTrue(buffer.append(Data([1, 2, 3, 4])))
        XCTAssertFalse(buffer.append(Data([5])))
        XCTAssertEqual(buffer.bufferedBytes, 4)
        XCTAssertEqual(buffer.capacity, 4)

        var audio = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(audio.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 4, timeout: 0)
        }, 4)
        XCTAssertEqual(audio, [1, 2, 3, 4])
    }

    func testClosedBufferWakesReaderWithoutFailure() {
        let buffer = LiveAudioBuffer(capacity: 16)
        buffer.close()
        var audio = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(audio.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 4, timeout: 0)
        }, 0)
        XCTAssertFalse(buffer.hasFailed)
        XCTAssertFalse(buffer.append(Data([7])))
    }

    func testTimeoutAndFailureAreBounded() {
        let buffer = LiveAudioBuffer(capacity: 16)
        var audio = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(audio.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 4, timeout: 0.01)
        }, 0)
        XCTAssertTrue(buffer.hasFailed)
        XCTAssertFalse(buffer.append(Data([9])))
    }

    func testFailureStillAllowsBufferedBytesToDrain() {
        let buffer = LiveAudioBuffer(capacity: 16)
        XCTAssertTrue(buffer.append(Data([1, 2])))
        buffer.fail()
        var audio = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(audio.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 4, timeout: 0)
        }, 2)
        XCTAssertEqual(Array(audio.prefix(2)), [1, 2])
        XCTAssertEqual(audio.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: 4, timeout: 0)
        }, 0)
    }

    func testICYMetadataStrippedAcrossEveryBoundary() {
        // One 4-byte audio interval, a 16-byte metadata block, then audio.
        let raw = Data("abcd".utf8) + Data([1])
            + Data("StreamTitle='A';".utf8)
            + Data("efgh".utf8) + Data([0])
            + Data("ijkl".utf8)
        for split in 1..<raw.count {
            var parser = ICYMetadataParser(interval: 4)
            let first = parser.consume(Data(raw.prefix(split)))
            let second = parser.consume(Data(raw.dropFirst(split)))
            XCTAssertEqual(first.audio + second.audio, Data("abcdefghijkl".utf8))
            XCTAssertEqual(first.titles + second.titles, ["A"])
        }
    }

    func testICYMetadataDisabledPassesThrough() {
        var parser = ICYMetadataParser(interval: 0)
        let raw = Data([0, 1, 255, 2, 3])
        let result = parser.consume(raw)
        XCTAssertEqual(result.audio, raw)
        XCTAssertTrue(result.titles.isEmpty)
    }

    func testICYMultipleTitlesAreDeliveredInOrder() {
        let raw = Data("abcd".utf8) + Data([1])
            + Data("StreamTitle='A';".utf8)
            + Data("efgh".utf8) + Data([1])
            + Data("StreamTitle='B';".utf8)
            + Data("ijkl".utf8)
        var parser = ICYMetadataParser(interval: 4)
        let result = parser.consume(raw)
        XCTAssertEqual(result.audio, Data("abcdefghijkl".utf8))
        XCTAssertEqual(result.titles, ["A", "B"])
    }

    func testICYEmptyTitleDoesNotEraseStationMetadata() {
        var parser = ICYMetadataParser(interval: 2)
        let payload = Data("hi".utf8) + Data([1])
            + Data("StreamTitle='';\0".utf8)
            + Data("ok".utf8)
        let result = parser.consume(payload)
        XCTAssertEqual(result.audio, Data("hiok".utf8))
        XCTAssertTrue(result.titles.isEmpty)
    }
}
