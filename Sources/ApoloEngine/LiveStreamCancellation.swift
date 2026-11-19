import Foundation

/// Stops a live network read without waiting for FFmpeg's serial decoder
/// queue. A probe may still be inside avformat_open_input when stop() runs.
final class LiveStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: LiveHTTPStream?
    private var cancelled = false

    func register(_ stream: LiveHTTPStream) {
        lock.lock()
        let shouldClose = cancelled
        if !shouldClose { self.stream = stream }
        lock.unlock()

        if shouldClose { stream.close() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = stream
        stream = nil
        lock.unlock()
        current?.close()
    }

    deinit { cancel() }
}
