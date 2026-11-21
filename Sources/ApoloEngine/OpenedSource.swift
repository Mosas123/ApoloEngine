import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// A demuxer that has already run `avformat_find_stream_info`.
///
/// The engine opens it once on a background task, reads `info` to decide the
/// route, and either closes it (AVPlayer path) or hands the `AVFormatContext`
/// to `AudioDecoder` (libavcodec path) so the source is not opened twice.
///
/// Ownership moves between threads; it is never used concurrently, which is
/// what the `@unchecked Sendable` promises.
final class OpenedSource: @unchecked Sendable {
    let info: MediaInfo
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var transport: (any AudioTransport)?

    private init(
        info: MediaInfo,
        formatContext: UnsafeMutablePointer<AVFormatContext>,
        transport: (any AudioTransport)?
    ) {
        self.info = info
        self.formatContext = formatContext
        self.transport = transport
    }

    static func open(
        url: URL,
        httpHeaders: [String: String] = [:],
        sessionConfiguration: URLSessionConfiguration = .default,
        isLive: Bool = false,
        onICYTitle: (@Sendable (String) -> Void)? = nil,
        liveCancellation: LiveStreamCancellation? = nil,
        finiteCancellation: FiniteStreamCancellation? = nil,
        diagnostics: AudioDiagnostics? = nil
    ) throws -> OpenedSource {
        var options: OpaquePointer?
        // Music headers resolve well within this; the defaults (5 MB / 5 s)
        // only add startup latency.
        _ = av_dict_set(&options, "probesize", "2000000", 0)
        _ = av_dict_set(&options, "analyzeduration", "2000000", 0)
        if !httpHeaders.isEmpty {
            let joined = httpHeaders
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n")
            joined.withCString { _ = av_dict_set(&options, "headers", $0, 0) }
        }

        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            let transport: any AudioTransport
            if isLive {
                let liveStream = LiveHTTPStream(
                    url: url,
                    headers: httpHeaders,
                    configuration: sessionConfiguration,
                    onICYTitle: onICYTitle,
                    onHTTPStatus: { [weak liveCancellation] status in
                        liveCancellation?.recordHTTPStatus(status)
                    }
                )
                // Register before starting the request/probe so stop() can
                // interrupt a blocking FFmpeg read immediately.
                liveCancellation?.register(liveStream)
                guard let live = LiveHTTPTransport(stream: liveStream) else {
                    av_dict_free(&options)
                    throw ApoloError.openFailed(code: -1)
                }
                transport = live
            } else {
                let fileStream = HTTPStream(
                    url: url,
                    headers: httpHeaders,
                    configuration: sessionConfiguration,
                    diagnostics: diagnostics
                )
                // Register before the blocking open/probe starts. A Stop/Next
                // may already have cancelled this obsolete generation.
                finiteCancellation?.register(fileStream)
                guard let file = HTTPTransport(stream: fileStream) else {
                    av_dict_free(&options)
                    throw ApoloError.openFailed(code: -1)
                }
                transport = file
            }
            guard let allocated = avformat_alloc_context() else {
                transport.close()
                av_dict_free(&options)
                throw ApoloError.unsupportedFormat
            }
            allocated.pointee.pb = transport.context

            var context: UnsafeMutablePointer<AVFormatContext>? = allocated
            let openStarted = DispatchTime.now().uptimeNanoseconds
            let openCode = avformat_open_input(&context, nil, nil, &options)
            diagnostics?.emit(
                "probe.open ms=\(AudioDiagnostics.elapsedMs(since: openStarted)) code=\(openCode)"
            )
            av_dict_free(&options)
            guard openCode == 0, let context else {
                if context != nil {
                    avformat_close_input(&context)
                }
                transport.close()
                throw ApoloError.openFailed(code: openCode)
            }

            do {
                let probeStarted = DispatchTime.now().uptimeNanoseconds
                let info = try buildInfo(context)
                diagnostics?.emit(
                    "probe.streamInfo ms=\(AudioDiagnostics.elapsedMs(since: probeStarted)) "
                        + "container=\(info.container) codec=\(info.audioTracks.first?.codec ?? "unknown") "
                        + "duration=\(String(format: "%.3f", info.duration))"
                )
                return OpenedSource(
                    info: info,
                    formatContext: context,
                    transport: transport
                )
            } catch {
                var closing: UnsafeMutablePointer<AVFormatContext>? = context
                avformat_close_input(&closing)
                transport.close()
                throw error
            }
        }

        var context: UnsafeMutablePointer<AVFormatContext>?
        // FFmpeg's file protocol does not percent-decode a Foundation file URL.
        // Trop downloads are named "Artist - Title [id].flac", so passing
        // absoluteString asks FFmpeg for a literal "%20" filename (ENOENT).
        // Use the filesystem path for local media; preserve URL semantics for
        // any non-file protocol.
        let input = url.isFileURL ? url.path : url.absoluteString
        let openCode = input.withCString {
            avformat_open_input(&context, $0, nil, &options)
        }
        av_dict_free(&options)
        if url.isFileURL {
            // Safe on-device diagnostics: never expose the user's file path.
            diagnostics?.emit(
                "probe.localOpen exists=\(FileManager.default.fileExists(atPath: url.path)) code=\(openCode)"
            )
        }
        guard openCode == 0, let context else {
            throw ApoloError.openFailed(code: openCode)
        }

        do {
            let info = try buildInfo(context)
            return OpenedSource(
                info: info,
                formatContext: context,
                transport: nil
            )
        } catch {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
            throw error
        }
    }

    /// Transfers ownership to the caller. The source no longer closes it.
    func takeFormatContext() -> UnsafeMutablePointer<AVFormatContext>? {
        let context = formatContext
        formatContext = nil
        return context
    }

    func takeTransport() -> (any AudioTransport)? {
        let transport = self.transport
        self.transport = nil
        return transport
    }

    func close() {
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        transport?.close()
        transport = nil
    }

    deinit {
        close()
    }

    private static func buildInfo(
        _ context: UnsafeMutablePointer<AVFormatContext>
    ) throws -> MediaInfo {
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

            let codec = avcodec_get_name(codecpar.pointee.codec_id)
                .map { String(cString: $0) } ?? "unknown"

            tracks.append(
                AudioTrackInfo(
                    index: index,
                    codec: codec,
                    sampleRate: Int(codecpar.pointee.sample_rate),
                    channels: Int(codecpar.pointee.ch_layout.nb_channels),
                    isAtmos: codecpar.pointee.profile == MediaProbe.eac3JOCProfile
                )
            )
        }

        guard !tracks.isEmpty else { throw ApoloError.noAudioTrack }

        let container = context.pointee.iformat
            .map { String(cString: $0.pointee.name) } ?? "unknown"

        let duration: TimeInterval
        if context.pointee.duration != Int64.min, context.pointee.duration > 0 {
            duration = TimeInterval(context.pointee.duration)
                / TimeInterval(AV_TIME_BASE)
        } else {
            duration = streamDuration
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

        return parseReplayGain(String(cString: value))
    }

    /// Parses `"-7.23 dB"` (the form ReplayGain tags use).
    static func parseReplayGain(_ value: String) -> Double? {
        var text = value.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(
            of: "dB",
            with: "",
            options: .caseInsensitive
        )
        text = text.trimmingCharacters(in: .whitespaces)
        return Double(text)
    }
}
