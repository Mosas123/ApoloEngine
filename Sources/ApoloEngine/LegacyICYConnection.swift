import Foundation
import Network

/// Narrow plain-HTTP compatibility path for old radio servers that answer
/// `ICY 200 OK`, which URLSession's HTTP parser may reject. Never used for
/// HTTPS or on-demand music. Audio still enters the existing bounded ring.
final class LegacyICYConnection: @unchecked Sendable {
    private let url: URL
    private let buffer: LiveAudioBuffer
    private let onTitle: (@Sendable (String) -> Void)?
    private let onStatus: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var connection: NWConnection?
    private var headerParser = LegacyICYHeaderParser()
    private var metadataParser = ICYMetadataParser(interval: 0)
    private var receivedHeaders = false
    private var waitingForDrain = false
    private var stopped = false
    private let queue = DispatchQueue(
        label: "ApoloEngine.LegacyICY",
        qos: .userInitiated
    )

    init(
        url: URL,
        buffer: LiveAudioBuffer,
        onTitle: (@Sendable (String) -> Void)?,
        onStatus: (@Sendable (Int) -> Void)?
    ) {
        self.url = url
        self.buffer = buffer
        self.onTitle = onTitle
        self.onStatus = onStatus
    }

    func start() {
        guard url.scheme?.lowercased() == "http",
              let hostname = url.host,
              !hostname.isEmpty,
              url.user == nil, url.password == nil,
              let rawPort = UInt16(exactly: url.port ?? 80),
              rawPort > 0,
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            buffer.fail()
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(hostname),
            port: endpointPort,
            using: .tcp
        )
        lock.lock()
        guard !stopped, self.connection == nil else {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.sendRequest(on: connection)
            case .failed:
                self.fail()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// The raw fallback deliberately sends no resolver/authentication headers.
    /// Only a same-host TCP request is sent, avoiding cookie/credential leaks
    /// through arbitrary radio redirects or malformed HTTP responses.
    private func sendRequest(on connection: NWConnection) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? "/"
        if path.isEmpty { path = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            path += "?" + query
        }
        let host = url.host ?? ""
        let hostHeader = host.contains(":") ? "[\(host)]" : host
        let portSuffix = (url.port ?? 80) == 80 ? "" : ":\(url.port ?? 80)"
        let request = "GET \(path) HTTP/1.0\r\nHost: \(hostHeader)\(portSuffix)\r\nIcy-MetaData: 1\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(request.utf8),
            completion: .contentProcessed { [weak self] error in
                if error == nil {
                    self?.receive(on: connection)
                } else {
                    self?.fail()
                }
            }
        )
    }

    private func receive(on connection: NWConnection) {
        lock.lock()
        let shouldReceive = !stopped && !waitingForDrain
            && self.connection === connection
        lock.unlock()
        guard shouldReceive else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1_024
        ) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            if error != nil { self.fail(); return }
            if let data, !data.isEmpty, !self.consume(data) {
                self.fail()
                return
            }
            if complete { self.fail(); return }
            self.lock.lock()
            let needsDrain = self.buffer.bufferedBytes
                >= self.buffer.capacity * 3 / 4
            self.waitingForDrain = needsDrain
            self.lock.unlock()
            if !needsDrain { self.receive(on: connection) }
        }
    }

    /// Called from the FFmpeg reader when it has freed ring capacity.
    func resumeIfDrained() {
        lock.lock()
        let shouldResume = !stopped && waitingForDrain
            && buffer.bufferedBytes <= buffer.capacity / 4
        if shouldResume { waitingForDrain = false }
        let connection = shouldResume ? self.connection : nil
        lock.unlock()
        if let connection { receive(on: connection) }
    }

    private func consume(_ data: Data) -> Bool {
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        let audio: Data
        var status: Int?
        do {
            if receivedHeaders {
                audio = data
            } else {
                guard let response = try headerParser.consume(data) else {
                    lock.unlock()
                    return true
                }
                receivedHeaders = true
                status = response.statusCode
                guard response.statusCode == 200 else {
                    lock.unlock()
                    onStatus?(response.statusCode)
                    return false
                }
                let type = response.header("Content-Type")?.lowercased() ?? ""
                guard !type.contains("text/html"),
                      !type.contains("application/json"),
                      !type.contains("mpegurl"),
                      !type.contains("scpls") else {
                    lock.unlock()
                    return false
                }
                let interval = Int(response.header("icy-metaint") ?? "") ?? 0
                metadataParser = ICYMetadataParser(
                    interval: interval > 0 && interval < (1 << 24) ? interval : 0
                )
                audio = response.initialAudio
            }
            let parsed = metadataParser.consume(audio)
            lock.unlock()
            if let status { onStatus?(status) }
            guard buffer.append(parsed.audio) else { return false }
            for title in parsed.titles { onTitle?(title) }
            return true
        } catch {
            lock.unlock()
            return false
        }
    }

    private func fail() {
        lock.lock()
        let cancelled = stopped
        lock.unlock()
        if !cancelled { buffer.fail() }
    }

    func close() {
        lock.lock()
        stopped = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    deinit { close() }
}
