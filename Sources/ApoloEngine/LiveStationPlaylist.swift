import Foundation

/// Parses station playlists only. HLS manifests are not station playlists:
/// the AVFoundation HLS route owns them without ever downloading their segments.
enum LiveStationPlaylist {
    enum Failure: Error, Equatable {
        case malformed
        case hlsManifest
        case noPlayableEntry
        case invalidURL
    }

    static func isPlaylist(_ url: URL, hint: String? = nil) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" { return false }
        if ext == "m3u" || ext == "pls" { return true }
        let mime = (hint ?? "").lowercased().split(separator: ";", maxSplits: 1)
            .first.map(String.init) ?? ""
        return ["audio/x-mpegurl", "audio/mpegurl", "application/x-mpegurl",
                "audio/x-scpls", "application/pls+xml"].contains(mime)
    }

    static func entries(from data: Data, url: URL) throws -> [URL] {
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.malformed
        }
        let lines = content.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.contains(where: { $0.uppercased().hasPrefix("#EXT-X-") }) {
            throw Failure.hlsManifest
        }
        let isPLS = url.pathExtension.lowercased() == "pls"
            || lines.contains(where: { $0.lowercased() == "[playlist]" })
        let candidates: [String]
        if isPLS {
            var indexed: [(Int, String)] = []
            var inPlaylist = false
            for line in lines {
                if line.lowercased() == "[playlist]" {
                    inPlaylist = true
                    continue
                }
                if line.hasPrefix("[") { inPlaylist = false }
                guard inPlaylist, let equal = line.firstIndex(of: "=") else {
                    continue
                }
                let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                    .lowercased()
                guard key.hasPrefix("file"),
                      let index = Int(key.dropFirst(4)), index > 0,
                      index <= 1_000 else { continue }
                let value = String(line[line.index(after: equal)...])
                indexed.append((index, value))
            }
            candidates = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        } else {
            candidates = lines.filter {
                !$0.isEmpty && !$0.hasPrefix("#")
            }
        }
        let urls = candidates.compactMap { validatedURL($0, relativeTo: url) }
        guard !urls.isEmpty else { throw Failure.noPlayableEntry }
        return urls
    }

    static func validatedURL(_ text: String, relativeTo base: URL) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8_192,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// Credentials and arbitrary resolver headers must not follow a station
    /// playlist entry onto another host, port, or scheme.
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }
}
