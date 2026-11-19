import Foundation

/// Resolves a small M3U/PLS station file to one direct HTTP(S) audio URL.
/// This is a bounded preflight, never a transport for the continuous audio.
enum LivePlaylistResolver {
    enum Failure: Error, Equatable {
        case httpStatus(Int)
        case invalidResponse
        case tooLarge
        case tooManyPlaylists
        case unsupportedContent
    }

    private static let maxBytes = 64 * 1_024
    private static let maxPlaylistLevels = 3

    static func resolve(
        url: URL,
        headers: [String: String],
        hint: String? = nil
    ) async throws -> URL {
        var seen = Set<URL>()
        var current = url
        for _ in 0..<maxPlaylistLevels {
            try Task.checkCancellation()
            guard seen.insert(current).inserted else {
                throw Failure.tooManyPlaylists
            }
            let safeHeaders = LiveStationPlaylist.sameOrigin(url, current)
                ? headers : [:]
            let data = try await fetch(url: current, headers: safeHeaders)
            let entries = try LiveStationPlaylist.entries(from: data, url: current)
            guard let selected = entries.first else {
                throw LiveStationPlaylist.Failure.noPlayableEntry
            }
            if !LiveStationPlaylist.isPlaylist(selected) {
                return selected
            }
            current = selected
        }
        throw Failure.tooManyPlaylists
    }

    private static func fetch(
        url: URL,
        headers: [String: String]
    ) async throws -> Data {
        guard LiveStationPlaylist.validatedURL(url.absoluteString, relativeTo: url) != nil
        else { throw LiveStationPlaylist.Failure.invalidURL }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil

        let delegate = SameOriginPlaylistRedirects(origin: url)
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/plain, audio/x-mpegurl, audio/x-scpls, */*",
                         forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw Failure.httpStatus(http.statusCode)
        }
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
        if mime.contains("text/html") || mime.contains("application/json") {
            throw Failure.unsupportedContent
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(length), count > maxBytes {
            throw Failure.tooLarge
        }

        var result = Data()
        result.reserveCapacity(1_024)
        for try await byte in bytes {
            try Task.checkCancellation()
            if result.count == maxBytes { throw Failure.tooLarge }
            result.append(byte)
        }
        return result
    }
}

private final class SameOriginPlaylistRedirects:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) { self.origin = origin }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              LiveStationPlaylist.sameOrigin(origin, destination),
              LiveStationPlaylist.validatedURL(
                  destination.absoluteString, relativeTo: origin
              ) != nil else {
            // Prevent credential/header propagation to other origins.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
