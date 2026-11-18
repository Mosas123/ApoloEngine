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
            joined.withCString { av_dict_set(&options, "headers", $0, 0) }
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
        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            else { continue }

            let codec = avcodec_get_name(codecpar.pointee.codec_id)
                .map { String(cString: $0) } ?? "unknown"

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

        let duration: TimeInterval
        if context.pointee.duration != AV_NOPTS_VALUE {
            duration = TimeInterval(context.pointee.duration) / TimeInterval(AV_TIME_BASE)
        } else {
            duration = 0
        }

        return MediaInfo(
            container: container,
            duration: duration,
            audioTracks: tracks
        )
    }

    /// E-AC-3 profile 30 is Dolby Digital Plus JOC (Atmos). FFmpeg's
    /// `AV_PROFILE_EAC3_DDP_ATMOS` is a plain `#define` and does not bridge.
    static let eac3JOCProfile: Int32 = 30
}
