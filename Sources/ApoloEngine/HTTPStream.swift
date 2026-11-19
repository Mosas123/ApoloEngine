import Foundation
import AetherLibavformat
import AetherLibavutil

/// Synchronous byte source for FFmpeg's custom AVIO.
///
/// It downloads the whole resource once through `URLSession` (the headers and
/// redirect handling come for free) and then serves reads and seeks from
/// memory. Music album files are small enough for this; a live stream is not a
/// case this path covers, because it never ends.
final class HTTPStream: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var data: Data?
    private var loadError: Error?
    private var position: Int64 = 0

    init(
        url: URL,
        headers: [String: String],
        configuration: URLSessionConfiguration = .default
    ) {
        self.url = url
        self.headers = headers
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// True when the download failed (as opposed to a clean end of file).
    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadError != nil
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard count > 0, let data, position < Int64(data.count) else {
            return 0
        }
        let available = Int(data.count) - Int(position)
        let toCopy = min(count, available)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.update(
                from: base.advanced(by: Int(position))
                    .assumingMemoryBound(to: UInt8.self),
                count: toCopy
            )
        }
        position += Int64(toCopy)
        return toCopy
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }

        let size = Int64(data?.count ?? 0)
        let base: Int64
        switch whence & ~0x20000 {
        case 0:
            base = 0
        case 1:
            base = position
        case 2:
            base = size
        case 0x10000:
            return size
        default:
            return -1
        }

        let target = base + offset
        guard target >= 0, target <= size else { return -1 }
        position = target
        return target
    }

    private func loadIfNeeded() {
        lock.lock()
        if data != nil || loadError != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let result = LoadResult()
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                result.set(data: nil, error: URLError(.badServerResponse))
            } else if let error {
                result.set(data: nil, error: error)
            } else {
                result.set(data: data, error: nil)
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
            lock.lock()
            loadError = URLError(.timedOut)
            lock.unlock()
            return
        }

        lock.lock()
        if let data = result.data {
            self.data = data
        } else {
            loadError = result.error ?? URLError(.unknown)
        }
        lock.unlock()
    }
}

private final class LoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedError: Error?

    func set(data: Data?, error: Error?) {
        lock.lock()
        storedData = data
        storedError = error
        lock.unlock()
    }

    var data: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

/// Owns the `AVIOContext`, its read buffer and the stream behind it.
final class HTTPTransport: @unchecked Sendable {
    private var avio: UnsafeMutablePointer<AVIOContext>?
    private var stream: HTTPStream?

    init?(stream: HTTPStream) {
        let bufferSize = 32 * 1024
        guard let buffer = av_malloc(bufferSize) else { return nil }
        let opaque = Unmanaged.passRetained(stream).toOpaque()
        guard let context = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self),
            Int32(bufferSize),
            0,
            opaque,
            httpReadPacket,
            nil,
            httpSeek
        ) else {
            av_free(buffer)
            Unmanaged<HTTPStream>.fromOpaque(opaque).release()
            return nil
        }
        context.pointee.seekable = 1
        avio = context
        self.stream = stream
    }

    var context: UnsafeMutablePointer<AVIOContext>? {
        avio
    }

    func close() {
        guard let avio else { return }
        let buffer = avio.pointee.buffer
        let opaque = avio.pointee.opaque
        var pointer: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&pointer)
        self.avio = nil
        if let buffer {
            av_free(buffer)
        }
        if let opaque {
            Unmanaged<HTTPStream>.fromOpaque(opaque).release()
        }
        stream = nil
    }

    deinit {
        close()
    }
}

private let httpReadPacket: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<UInt8>?,
    Int32
) -> Int32 = { opaque, buffer, size in
    guard let opaque, let buffer, size > 0 else { return 0 }
    let stream = Unmanaged<HTTPStream>
        .fromOpaque(opaque)
        .takeUnretainedValue()
    let read = stream.read(into: buffer, count: Int(size))
    if read > 0 {
        return Int32(read)
    }
    // The AVIO contract wants AVERROR_EOF, not 0. A failed download is EIO.
    return stream.hasError ? -5 : -541_478_725
}

private let httpSeek: @convention(c) (
    UnsafeMutableRawPointer?,
    Int64,
    Int32
) -> Int64 = { opaque, offset, whence in
    guard let opaque else { return -1 }
    let stream = Unmanaged<HTTPStream>
        .fromOpaque(opaque)
        .takeUnretainedValue()
    return stream.seek(offset: offset, whence: whence)
}
