import Foundation
import AetherLibavformat
import AetherLibavutil

/// Synchronous, seekable byte source for FFmpeg's custom AVIO.
///
/// Reads go through `URLSession` with `Range` requests, one 1 MB window at a
/// time, so FFmpeg can start after the first chunk instead of waiting for the
/// whole file. Servers that ignore `Range` (200 with the full body) are
/// served from memory. Live/segmented streams are out of scope.
final class HTTPStream: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let diagnostics: AudioDiagnostics?
    private let chunkSize = 1 << 20
    private let lock = NSLock()

    private var totalSize: Int64?
    private var cache = Data()
    private var cacheStart: Int64 = 0
    private var fullData: Data?
    private var loadError: Error?
    private var position: Int64 = 0

    init(
        url: URL,
        headers: [String: String],
        configuration: URLSessionConfiguration = .default,
        diagnostics: AudioDiagnostics? = nil
    ) {
        self.url = url
        self.headers = headers
        self.diagnostics = diagnostics
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// True when the transport failed (as opposed to a clean end of file).
    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadError != nil
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        lock.lock()
        let start = position
        lock.unlock()

        guard ensureData(at: start, needed: count) else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        if let fullData {
            guard start < Int64(fullData.count) else { return 0 }
            let available = Int(fullData.count) - Int(start)
            let toCopy = min(count, available)
            fullData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.update(
                    from: base.advanced(by: Int(start))
                        .assumingMemoryBound(to: UInt8.self),
                    count: toCopy
                )
            }
            position += Int64(toCopy)
            return toCopy
        }

        let offset = Int(start - cacheStart)
        guard offset >= 0, offset < cache.count else { return 0 }
        let available = cache.count - offset
        let toCopy = min(count, available)
        cache.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.update(
                from: base.advanced(by: offset)
                    .assumingMemoryBound(to: UInt8.self),
                count: toCopy
            )
        }
        position += Int64(toCopy)
        return toCopy
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        let code = whence & ~0x20000

        if code == 0x10000 {
            ensureSize()
            lock.lock()
            defer { lock.unlock() }
            return totalSize ?? 0
        }

        let base: Int64
        switch code {
        case 0:
            base = 0
        case 1:
            lock.lock()
            base = position
            lock.unlock()
        case 2:
            ensureSize()
            lock.lock()
            base = totalSize ?? 0
            lock.unlock()
        default:
            return -1
        }

        let target = base + offset
        guard target >= 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        if let totalSize, target > totalSize {
            return -1
        }
        position = target
        return target
    }

    private func ensureData(at start: Int64, needed: Int) -> Bool {
        lock.lock()
        if loadError != nil {
            lock.unlock()
            return false
        }
        if let fullData {
            let ok = start < Int64(fullData.count)
            lock.unlock()
            return ok
        }
        if start >= cacheStart,
           start + Int64(needed) <= cacheStart + Int64(cache.count) {
            lock.unlock()
            return true
        }
        if let totalSize, start >= totalSize {
            lock.unlock()
            return false
        }
        lock.unlock()
        return fetch(from: start)
    }

    private func ensureSize() {
        lock.lock()
        let known = totalSize != nil || fullData != nil
        lock.unlock()
        if known { return }
        _ = fetch(from: 0)
    }

    // A brief CDN hiccup must not permanently poison the FFmpeg byte stream.
    // Retry the exact same Range; the read position only moves after bytes
    // have been copied to the decoder. Never retry authorization failures.
    private static let maxTransientRetries = 2

    private func fetch(from start: Int64) -> Bool {
        for attempt in 0...Self.maxTransientRetries {
            if attempt > 0 {
                // This is FFmpeg's synchronous AVIO worker, not the main actor.
                Thread.sleep(forTimeInterval: Double(attempt) * 0.15)
            }

            let requestStarted = DispatchTime.now().uptimeNanoseconds
            switch requestRange(from: start) {
            case .failure(let error):
                diagnostics?.emit(
                    "http.range start=\(start) status=networkError "
                        + "errorCode=\((error as NSError).code) bytes=0 "
                        + "attempt=\(attempt + 1) ms=\(AudioDiagnostics.elapsedMs(since: requestStarted))"
                )
                if attempt < Self.maxTransientRetries,
                   Self.isTransientNetworkError(error) {
                    continue
                }
                fail(error)
                return false

            case .success(let (http, data)):
                diagnostics?.emit(
                    "http.range start=\(start) status=\(http.statusCode) "
                        + "bytes=\(data.count) attempt=\(attempt + 1) "
                        + "ms=\(AudioDiagnostics.elapsedMs(since: requestStarted))"
                )
                switch http.statusCode {
                case 206:
                    guard let range = Self.parseContentRange(
                        http.value(forHTTPHeaderField: "Content-Range")
                    ), range.start == start,
                       range.end >= range.start,
                       Int64(data.count) == range.end - range.start + 1,
                       (range.total.map { range.end < $0 } ?? true) else {
                        fail(URLError(.badServerResponse))
                        return false
                    }
                    lock.lock()
                    if let oldSize = totalSize,
                       let newSize = range.total,
                       oldSize != newSize {
                        lock.unlock()
                        fail(URLError(.badServerResponse))
                        return false
                    }
                    totalSize = range.total ?? totalSize
                    cacheStart = range.start
                    cache = data
                    lock.unlock()
                    return true

                case 200:
                    // Some small files ignore Range. Preserve the existing
                    // compatibility path; these responses contain the full file.
                    lock.lock()
                    fullData = data
                    totalSize = Int64(data.count)
                    cacheStart = 0
                    cache = data
                    lock.unlock()
                    return true

                case 408, 500, 502, 503, 504:
                    if attempt < Self.maxTransientRetries { continue }
                    fail(URLError(.badServerResponse))
                    return false

                default:
                    // 401/403/404/410/416 and other nontransient responses:
                    // do not repeatedly request an expired or rejected URL.
                    fail(URLError(.badServerResponse))
                    return false
                }
            }
        }
        fail(URLError(.badServerResponse))
        return false
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case URLError.Code.timedOut.rawValue,
             URLError.Code.networkConnectionLost.rawValue,
             URLError.Code.cannotConnectToHost.rawValue:
            return true
        default:
            return false
        }
    }

    private func requestRange(
        from start: Int64
    ) -> Result<(HTTPURLResponse, Data), Error> {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(
            "bytes=\(start)-\(start + Int64(chunkSize) - 1)",
            forHTTPHeaderField: "Range"
        )

        let result = FetchResult()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            result.set(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
            return .failure(URLError(.timedOut))
        }

        let fetched = result.value()
        if let error = fetched.error {
            return .failure(error)
        }
        guard let http = fetched.response as? HTTPURLResponse,
              let data = fetched.data else {
            return .failure(URLError(.badServerResponse))
        }
        return .success((http, data))
    }

    private func fail(_ error: Error) {
        lock.lock()
        if loadError == nil {
            loadError = error
        }
        lock.unlock()
    }

    /// `"bytes 0-1048575/5000000"` -> (start: 0, total: 5000000).
    static func parseContentRange(
        _ value: String?
    ) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let halves = parts[1].split(separator: "/")
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0, end >= start else { return nil }
        return (start, end, Int64(halves[1]))
    }
}

private final class FetchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    private var error: Error?

    func set(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    func value() -> (data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, response, error)
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
