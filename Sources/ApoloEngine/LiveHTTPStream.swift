import Foundation

/// Non-seekable, constant-memory HTTP reader for continuous radio.
/// Never uses URLSession.dataTask(with:completionHandler:) or Range requests:
/// that would buffer a potentially endless response in memory.
final class LiveHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let configuration: URLSessionConfiguration
    private let buffer: LiveAudioBuffer
    private let stateLock = NSLock()
    private let onICYTitle: (@Sendable (String) -> Void)?
    private let onHTTPStatus: (@Sendable (Int) -> Void)?
    private var parser = ICYMetadataParser(interval: 0)
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var stopped = false
    private var suspended = false

    init(
        url: URL,
        headers: [String: String],
        capacity: Int = 512 * 1_024,
        configuration: URLSessionConfiguration = .ephemeral,
        onICYTitle: (@Sendable (String) -> Void)? = nil,
        onHTTPStatus: (@Sendable (Int) -> Void)? = nil
    ) {
        self.url = url
        self.headers = headers
        self.configuration = configuration
        buffer = LiveAudioBuffer(capacity: capacity)
        self.onICYTitle = onICYTitle
        self.onHTTPStatus = onHTTPStatus
        super.init()
        configuration.timeoutIntervalForRequest = 20
        // A radio stream lasts much longer than a file download.
        configuration.timeoutIntervalForResource = 7 * 24 * 3_600
    }

    var bufferedBytes: Int { buffer.bufferedBytes }
    var capacity: Int { buffer.capacity }
    var hasError: Bool { buffer.hasFailed }

    func start() {
        stateLock.lock()
        guard !stopped, session == nil else {
            stateLock.unlock()
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let connection = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let download = connection.dataTask(with: request)
        session = connection
        task = download
        stateLock.unlock()
        download.resume()
    }

    /// Called by FFmpeg on its AVIO thread, not the main actor.
    func read(into destination: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        let readCount = buffer.read(
            into: destination,
            count: count,
            timeout: 20
        )
        if readCount == 0, buffer.hasFailed {
            close()
            return 0
        }

        stateLock.lock()
        if suspended, !stopped, buffer.bufferedBytes <= capacity / 4 {
            suspended = false
            task?.resume()
        }
        stateLock.unlock()
        return readCount
    }

    func close() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let connection = session
        let download = task
        session = nil
        task = nil
        if suspended {
            suspended = false
            download?.resume()
        }
        stateLock.unlock()

        buffer.close()
        download?.cancel()
        connection?.invalidateAndCancel()
    }

    deinit { close() }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            buffer.fail()
            completionHandler(.cancel)
            return
        }
        onHTTPStatus?(http.statusCode)
        guard http.statusCode == 200 else {
            buffer.fail()
            completionHandler(.cancel)
            return
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        if type.contains("text/html") || type.contains("mpegurl")
            || type.contains("scpls") || type.contains("application/json") {
            buffer.fail()
            completionHandler(.cancel)
            return
        }

        let interval = Int(
            http.value(forHTTPHeaderField: "icy-metaint") ?? ""
        ) ?? 0
        stateLock.lock()
        parser = ICYMetadataParser(
            interval: interval > 0 && interval < 1 << 24 ? interval : 0
        )
        let shouldCancel = stopped
        stateLock.unlock()
        completionHandler(shouldCancel ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        let parsed = parser.consume(data)
        stateLock.unlock()

        // Audio must not include interleaved ICY metadata when it reaches the
        // decoder. Reject overflow instead of dropping bytes or growing RAM.
        guard buffer.append(parsed.audio) else {
            buffer.fail()
            dataTask.cancel()
            return
        }
        for title in parsed.titles {
            onICYTitle?(title)
        }

        stateLock.lock()
        if !stopped, !suspended, buffer.bufferedBytes >= capacity * 3 / 4 {
            suspended = true
            task?.suspend()
        }
        stateLock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let cancelledByCaller = stopped
        stateLock.unlock()
        if !cancelledByCaller {
            // A live broadcast ending unexpectedly is not a song EOF.
            buffer.fail()
        }
    }
}
