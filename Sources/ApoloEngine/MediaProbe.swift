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
        if context.pointee.duration != Int64.min {
            duration = TimeInterval(context.pointee.duration) / TimeInterval(AV_TIME_BASE)
        } else {
            duration = 0
        }

        let trackGain = replayGain(from: context.pointee.metadata)
            ?? replayGain(from: audioMetadata)

        return MediaInfo(
            container: container,
            duration: duration,
            audioTracks: tracks,
            trackGainDB: trackGain
        )
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
