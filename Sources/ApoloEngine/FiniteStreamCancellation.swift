import Foundation

/// Cancels an obsolete finite-file AVIO read without touching FFmpeg-owned
/// contexts on another thread. Stop/Next call cancel() before the decoder's
/// serial queue is free; the worker retains ownership and closes normally.
final class FiniteStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: HTTPStream?
    private var cancelled = false

    func register(_ stream: HTTPStream) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { self.stream = stream }
        lock.unlock()
        if shouldCancel { stream.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = stream
        stream = nil
        lock.unlock()
        current?.cancel()
    }

    deinit { cancel() }
}
