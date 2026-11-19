import Foundation

/// Incremental parser for legacy Icecast/Shoutcast `ICY 200 OK` responses.
/// The fallback receives raw TCP bytes, so it must never pass response headers
/// into FFmpeg's compressed-audio input.
struct LegacyICYHeaderParser {
    enum Failure: Error, Equatable {
        case invalidStatus
        case malformedHeaders
        case headersTooLarge
    }

    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let initialAudio: Data

        func header(_ key: String) -> String? {
            headers[key.lowercased()]
        }
    }

    private static let maximumHeaderBytes = 16 * 1_024
    private var pending = Data()

    mutating func consume(_ chunk: Data) throws -> Response? {
        pending.append(chunk)

        let crlf = Data([13, 10, 13, 10])
        let lf = Data([10, 10])
        let boundary: Range<Data.Index>?
        if let match = pending.range(of: crlf) {
            boundary = match
        } else {
            boundary = pending.range(of: lf)
        }

        guard let boundary else {
            if pending.count > Self.maximumHeaderBytes {
                throw Failure.headersTooLarge
            }
            return nil
        }

        guard boundary.upperBound <= Self.maximumHeaderBytes else {
            throw Failure.headersTooLarge
        }

        let headerBytes = Data(pending[..<boundary.lowerBound])
        let initialAudio = Data(pending[boundary.upperBound...])
        pending.removeAll(keepingCapacity: false)
        guard let string = String(data: headerBytes, encoding: .isoLatin1) else {
            throw Failure.malformedHeaders
        }
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let statusLine = lines.first, statusLine.hasPrefix("ICY ") else {
            throw Failure.invalidStatus
        }
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0] == "ICY",
              parts[1].count == 3,
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let code = Int(parts[1]), (100...599).contains(code) else {
            throw Failure.invalidStatus
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let delimiter = line.firstIndex(of: ":") else {
                throw Failure.malformedHeaders
            }
            let name = line[..<delimiter].trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: delimiter)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
                  }),
                  !value.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw Failure.malformedHeaders
            }
            // Duplicated security-sensitive headers are invalid rather than
            // allowing ambiguity about the metadata interval or MIME type.
            guard headers[name] == nil else { throw Failure.malformedHeaders }
            headers[name] = value
        }
        return Response(statusCode: code, headers: headers, initialAudio: initialAudio)
    }
}
