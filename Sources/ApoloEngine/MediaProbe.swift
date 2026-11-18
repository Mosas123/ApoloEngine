import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Reads container and stream metadata with FFmpeg.
///
/// Demux only: it never opens a decoder, so an E-AC-3 track only reports
/// `isAtmos` when the container already carries the JOC profile.
public enum MediaProbe {
    public nonisolated static func probe(
        url: URL,
        httpHeaders: [String: String] = [:]
    ) throws -> MediaInfo {
        let key = cacheKey(url: url, headers: httpHeaders)
        if let cached = cache.value(for: key) {
            return cached
        }

        var options: OpaquePointer?
        if !httpHeaders.isEmpty {
            let joined = httpHeaders
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n")
            joined.withCString { _ = av_dict_set(&options, "headers", $0, 0) }
        }
        defer { av_dict_free(&options) }

        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        let openCode = url.absoluteString.withCString {
            avformat_open_input(&formatContext, $0, nil, &options)
        }
        guard openCode == 0, let context = formatContext else {
            throw ApoloError.openFailed(code: openCode)
        }
        defer { avformat_close_input(&formatContext) }

        guard avformat_find_stream_info(context, nil) >= 0 else {
            throw ApoloError.unsupportedFormat
        }

        var tracks: [AudioTrackInfo] = []
        var audioMetadata: OpaquePointer?
        var streamDuration: TimeInterval = 0
        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            else { continue }

            let codec = avcodec_get_name(codecpar.pointee.codec_id)
                .map { String(cString: $0) } ?? "unknown"

            if audioMetadata == nil {
                audioMetadata = stream.pointee.metadata
            }
            if streamDuration == 0, stream.pointee.duration != Int64.min {
                let base = stream.pointee.time_base
                if base.num > 0, base.den > 0 {
                    streamDuration = Double(stream.pointee.duration)
                        * Double(base.num) / Double(base.den)
                }
            }

            tracks.append(
                AudioTrackInfo(
                    index: index,
                    codec: codec,
                    sampleRate: Int(codecpar.pointee.sample_rate),
                    channels: Int(codecpar.pointee.ch_layout.nb_channels),
                    isAtmos: codecpar.pointee.profile == Self.eac3JOCProfile
                )
            )
        }

        guard !tracks.isEmpty else { throw ApoloError.noAudioTrack }

        let container = context.pointee.iformat
            .map { String(cString: $0.pointee.name) } ?? "unknown"

        // AV_NOPTS_VALUE is a C macro (INT64_MIN) and does not bridge to Swift.
        let duration: TimeInterval
        if context.pointee.duration != Int64.min, context.pointee.duration > 0 {
            duration = TimeInterval(context.pointee.duration) / TimeInterval(AV_TIME_BASE)
        } else {
            duration = streamDuration
        }

        let trackGain = replayGain(from: context.pointee.metadata)
            ?? replayGain(from: audioMetadata)

        let info = MediaInfo(
            container: container,
            duration: duration,
            audioTracks: tracks,
            trackGainDB: trackGain
        )
        cache.store(info, for: key)
        return info
    }

    // MARK: - Probe cache

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

    /// Reads `replaygain_track_gain` ("-7.23 dB") and returns the number.
    private static func replayGain(from metadata: OpaquePointer?) -> Double? {
        guard let metadata,
              let entry = av_dict_get(metadata, "replaygain_track_gain", nil, 0),
              let value = entry.pointee.value
        else { return nil }

        var text = String(cString: value).trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(
            of: "dB",
            with: "",
            options: .caseInsensitive
        )
        text = text.trimmingCharacters(in: .whitespaces)
        return Double(text)
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
