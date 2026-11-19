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
        session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                result.error = URLError(.badServerResponse)
            } else if let error {
                result.error = error
            } else {
                result.data = data
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

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
    var data: Data?
    var error: Error?
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
    return Int32(stream.read(into: buffer, count: Int(size)))
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
