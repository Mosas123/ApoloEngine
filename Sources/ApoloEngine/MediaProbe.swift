import Foundation

/// Reads container and stream metadata with FFmpeg.
///
/// The open/parse work lives in `OpenedSource`; this type adds the small LRU
/// cache the engine uses to avoid re-probing the same local file.
public enum MediaProbe {
    public nonisolated static func probe(
        url: URL,
        httpHeaders: [String: String] = [:]
    ) throws -> MediaInfo {
        let key = cacheKey(url: url, headers: httpHeaders)
        if let cached = cache.value(for: key) {
            return cached
        }
        let source = try OpenedSource.open(url: url, httpHeaders: httpHeaders)
        let info = source.info
        cache.store(info, for: key)
        return info
    }

    nonisolated static func cachedInfo(
        url: URL,
        httpHeaders: [String: String] = [:]
    ) -> MediaInfo? {
        cache.value(for: cacheKey(url: url, headers: httpHeaders))
    }

    nonisolated static func remember(
        _ info: MediaInfo,
        url: URL,
        httpHeaders: [String: String] = [:]
    ) {
        cache.store(info, for: cacheKey(url: url, headers: httpHeaders))
    }

    private static let cache = ProbeCache()

    private static func cacheKey(
        url: URL,
        headers: [String: String]
    ) -> String {
        if url.isFileURL {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            return "file|\(url.path)|\(size)|\(modified)"
        }
        let headerKey = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "url|\(url.absoluteString)|\(headerKey)"
    }

    /// E-AC-3 profile 30 is Dolby Digital Plus JOC (Atmos). FFmpeg's
    /// `AV_PROFILE_EAC3_DDP_ATMOS` is a plain `#define` and does not bridge.
    static let eac3JOCProfile: Int32 = 30
}

private final class ProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: MediaInfo] = [:]
    private var order: [String] = []
    private let limit = 32

    func value(for key: String) -> MediaInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let info = entries[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return info
    }

    func store(_ info: MediaInfo, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = info
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }
}
