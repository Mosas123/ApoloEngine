import Foundation

/// Fixed-size byte ring shared between URLSession's delegate and FFmpeg's
/// blocking AVIO reader. The capacity is an absolute bound, not a target.
final class LiveAudioBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private var storage: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var failed = false
    private var closed = false

    var capacity: Int { storage.count }

    init(capacity: Int = 512 * 1_024) {
        precondition(capacity > 0)
        storage = [UInt8](repeating: 0, count: capacity)
    }

    var bufferedBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return available
    }

    var hasFailed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return failed
    }

    /// Returns false rather than increasing memory or silently dropping audio.
    /// The live transport may suspend the network task before reaching this.
    func append(_ bytes: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !failed, bytes.count <= storage.count - available else {
            return false
        }
        guard !bytes.isEmpty else { return true }

        let first = min(bytes.count, storage.count - writeIndex)
        bytes.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            storage.withUnsafeMutableBufferPointer { buffer in
                guard let destination = buffer.baseAddress else { return }
                destination.advanced(by: writeIndex)
                    .update(from: source, count: first)
                if bytes.count > first {
                    destination.update(
                        from: source.advanced(by: first),
                        count: bytes.count - first
                    )
                }
            }
        }
        writeIndex = (writeIndex + bytes.count) % storage.count
        available += bytes.count
        condition.signal()
        return true
    }

    /// Waits for audio without busy-spinning. A prolonged silence fails the
    /// read; a cancelled transport wakes it immediately.
    func read(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        timeout: TimeInterval = 20
    ) -> Int {
        guard count > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while available == 0, !failed, !closed {
            if !condition.wait(until: deadline) {
                failed = true
                condition.broadcast()
                break
            }
        }
        guard available > 0 else { return 0 }
        let count = min(count, available)
        let first = min(count, storage.count - readIndex)
        storage.withUnsafeBufferPointer { buffer in
            guard let source = buffer.baseAddress else { return }
            destination.update(
                from: source.advanced(by: readIndex),
                count: first
            )
            if count > first {
                destination.advanced(by: first).update(
                    from: source,
                    count: count - first
                )
            }
        }
        readIndex = (readIndex + count) % storage.count
        available -= count
        return count
    }

    func fail() {
        condition.lock()
        failed = true
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Strips interleaved Icecast/Shoutcast ICY metadata before decoding.
/// A metadata interval is a count of AUDIO bytes, not raw network bytes.
struct ICYMetadataParser {
    private let interval: Int
    private var audioRemaining: Int
    private var metadataRemaining = 0
    private var metadata = Data()

    init(interval: Int) {
        self.interval = max(0, interval)
        audioRemaining = max(0, interval)
    }

    mutating func consume(_ chunk: Data) -> (audio: Data, titles: [String]) {
        guard interval > 0 else { return (chunk, []) }
        let bytes = [UInt8](chunk)
        var audio = Data()
        var titles: [String] = []
        var index = 0

        while index < bytes.count {
            if metadataRemaining > 0 {
                let count = min(metadataRemaining, bytes.count - index)
                metadata.append(contentsOf: bytes[index..<(index + count)])
                metadataRemaining -= count
                index += count
                if metadataRemaining == 0 {
                    if let title = Self.streamTitle(from: metadata) {
                        titles.append(title)
                    }
                    metadata.removeAll(keepingCapacity: true)
                    audioRemaining = interval
                }
            } else if audioRemaining > 0 {
                let count = min(audioRemaining, bytes.count - index)
                audio.append(contentsOf: bytes[index..<(index + count)])
                audioRemaining -= count
                index += count
            } else {
                metadataRemaining = Int(bytes[index]) * 16
                index += 1
                if metadataRemaining == 0 {
                    audioRemaining = interval
                }
            }
        }

        return (audio, titles)
    }

    private static func streamTitle(from metadata: Data) -> String? {
        let useful = Data(metadata.prefix { $0 != 0 })
        guard let text = String(data: useful, encoding: .utf8)
                ?? String(data: useful, encoding: .isoLatin1),
              let key = text.range(of: "StreamTitle=", options: .caseInsensitive)
        else { return nil }
        let value = text[key.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "'" || quote == "\"" else {
            return nil
        }
        let remainder = value.dropFirst()
        guard let end = remainder.firstIndex(of: quote) else { return nil }
        let title = String(remainder[..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && !$0.isASCIIControl }
        return title.isEmpty ? nil : String(title.prefix(512))
    }
}

private extension Character {
    var isASCIIControl: Bool {
        unicodeScalars.allSatisfy {
            $0.value < 32 || $0.value == 127
        }
    }
}
