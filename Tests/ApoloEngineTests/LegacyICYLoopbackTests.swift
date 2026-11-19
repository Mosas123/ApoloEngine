import Foundation
import Network
import XCTest
@testable import ApoloEngine

/// Loopback integration: an actual TCP listener sends a raw ICY response,
/// exercising NWConnection, the header parser, and the bounded audio ring.
final class LegacyICYLoopbackTests: XCTestCase {
    func testRawICYServerDeliversAudioAndStripsInterleavedMetadata() throws {
        let listening = expectation(description: "station listening")
        let requested = expectation(description: "client request")
        let titled = expectation(description: "ICY title")
        let queue = DispatchQueue(label: "ApoloEngineTests.LegacyICYStation")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        // A real legacy server does not send an HTTP/1.x status line.
        let header = Data(
            "ICY 200 OK\r\nContent-Type: audio/ogg\r\nicy-metaint: 4\r\n\r\n".utf8
        )
        let metadata = Data("StreamTitle='A';".utf8)
        XCTAssertEqual(metadata.count, 16)
        let response = header
            + Data("abcd".utf8)
            + Data([1])
            + metadata
            + Data("efgh".utf8)
            + Data([0])

        let connections = ICYTestConnections()
        defer { connections.cancel() }
        listener.newConnectionHandler = { connection in
            connections.add(connection)
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 4_096
                ) { data, _, _, error in
                    guard error == nil, let data,
                          let text = String(data: data, encoding: .utf8),
                          text.contains("GET /station HTTP/1.0") else {
                        return
                    }
                    // No cookies, authorization headers or redirect chain.
                    XCTAssertFalse(text.lowercased().contains("authorization:"))
                    XCTAssertFalse(text.lowercased().contains("cookie:"))
                    requested.fulfill()
                    connection.send(
                        content: response,
                        completion: .contentProcessed { _ in }
                    )
                }
            }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)

        let port = try XCTUnwrap(listener.port?.rawValue)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/station"))
        let ring = LiveAudioBuffer(capacity: 64)
        let connection = LegacyICYConnection(
            url: url,
            buffer: ring,
            onTitle: { title in
                if title == "A" { titled.fulfill() }
            },
            onStatus: { status in
                XCTAssertEqual(status, 200)
            }
        )
        defer {
            connection.close()
            ring.close()
        }
        connection.start()

        var collected = [UInt8](repeating: 0, count: 8)
        var count = 0
        while count < collected.count {
            let amount = collected.withUnsafeMutableBufferPointer { pointer in
                ring.read(
                    into: pointer.baseAddress!.advanced(by: count),
                    count: collected.count - count,
                    timeout: 3
                )
            }
            if amount == 0 { break }
            count += amount
            connection.resumeIfDrained()
        }
        XCTAssertEqual(count, 8)
        XCTAssertEqual(Data(collected.prefix(count)), Data("abcdefgh".utf8))
        wait(for: [requested, titled], timeout: 5)
        XCTAssertLessThanOrEqual(ring.bufferedBytes, ring.capacity)
    }
}

/// Keep accepted NWConnection instances alive for the loopback test until
/// teardown; the listener itself does not own established TCP connections.
private final class ICYTestConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NWConnection] = []

    func add(_ connection: NWConnection) {
        lock.lock()
        values.append(connection)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let existing = values
        values.removeAll()
        lock.unlock()
        for connection in existing { connection.cancel() }
    }
}
