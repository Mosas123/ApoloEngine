import AVFoundation

/// Exposes only recognizable song titles from native timed metadata.
/// This is intentionally not a generic metadata/URL logger.
enum LiveTimedMetadata {
    static func title(in items: [AVMetadataItem]) -> String? {
        for item in items.reversed() {
            guard item.identifier == .id3MetadataTitleDescription
                || item.identifier == .commonIdentifierTitle
                || item.commonKey == .commonKeyTitle else {
                continue
            }
            guard let raw = item.stringValue,
                  let title = sanitize(raw) else { continue }
            return title
        }
        return nil
    }

    static func sanitize(_ value: String) -> String? {
        // Metadata originates from third-party broadcast sources. Bound
        // display size and remove NUL/newlines and other controls.
        let scalars = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(256)
        let value = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// AVFoundation calls this object on its designated delegate queue. The
/// actor-owned engine receives only an immutable String, never AV objects.
final class LiveTimedMetadataHandler: NSObject,
    AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
    private let onTitle: @Sendable (String) -> Void

    init(onTitle: @escaping @Sendable (String) -> Void) {
        self.onTitle = onTitle
    }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: sending [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        for group in groups {
            if let title = LiveTimedMetadata.title(in: group.items) {
                onTitle(title)
            }
        }
    }
}
