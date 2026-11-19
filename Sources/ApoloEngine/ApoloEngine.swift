import Foundation
import Observation

/// Music and streaming engine.
///
/// AVFoundation plays the codecs it handles. Everything else goes through
/// FFmpeg into an `AVSampleBufferAudioRenderer`, so Spatial Audio and Atmos
/// stay available on both routes.
///
/// Create one instance and keep it for the app's lifetime.
@MainActor
@Observable
public final class ApoloEngine {
    public private(set) var state: PlaybackState = .idle
    public private(set) var media: MediaInfo?
    public private(set) var elapsed: TimeInterval = 0
    /// ICY track title for a direct live radio source, when available.
    public private(set) var liveTitle: String?

    /// Five-band EQ. Applied on both routes: the libavcodec chain and the
    /// AVPlayer `MTAudioProcessingTap`.
    public var equalizer: EqualizerSettings = .flat {
        didSet { applyProcessing() }
    }

    public var limiterEnabled: Bool = true {
        didSet { applyProcessing() }
    }

    /// Extra gain in dB, applied on top of any ReplayGain tag in the container.
    public var trackGainDB: Double = 0 {
        didSet { applyProcessing() }
    }

    private var metadataGainDB: Double?
    /// Incremented on every load/skip so a slow, superseded probe cannot
    /// overwrite the engine after the user moved on.
    private(set) var loadEpoch: UInt64 = 0

    private let host = AVPlayerHost()
    private let session: AudioSessionController
    private let nowPlaying = NowPlayingController()
    private let managesSystemMediaControls: Bool
    private var libavHost: LibavcodecAudioHost?
    private var route: AudioRoute = .avPlayer
    private var metadata: NowPlayingMetadata?
    private var resumeAfterInterruption = false
    private var liveCancellation: LiveStreamCancellation?
    private var liveReconnectTask: Task<Void, Never>?
    private var liveRetryAttempts = 0
    private var liveRetryOpening = false
    private var livePlayingSince: Date?
    private var liveShouldPlay = true

    private var queue = PlayQueue()

    /// Sources queued after the current one. The hosts advance into them on
    /// their own; the engine only keeps the Now Playing card in sync.
    public var nextTracks: [ApoloTrack] { queue.upcoming }
    public var currentTrack: ApoloTrack? { queue.current }

    /// `managesSystemMediaControls` registers the remote commands and the Now
    /// Playing card; `managesAudioSession` configures and observes
    /// `AVAudioSession`. Pass `false` for either when the host app owns it.
    public init(
        managesSystemMediaControls: Bool = true,
        managesAudioSession: Bool = true
    ) {
        self.managesSystemMediaControls = managesSystemMediaControls
        self.session = AudioSessionController(
            managesSession: managesAudioSession
        )

        host.onState = { [weak self] state in
            guard let self, self.route == .avPlayer else { return }
            self.apply(state)
        }
        host.onTime = { [weak self] time in
            self?.elapsed = time
        }
        host.onTrackChange = { [weak self] in
            self?.advanceFromQueue()
        }
        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onSeek = { [weak self] time in
            Task { await self?.seek(to: time) }
        }
        if managesSystemMediaControls {
            nowPlaying.activate()
        }

        session.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.resumeAfterInterruption = self.state == .playing
            if self.resumeAfterInterruption {
                if self.queue.current?.streamMode == .live {
                    self.liveShouldPlay = false
                    self.cancelLiveReconnect()
                }
                self.pauseInternal()
            }
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, shouldResume, self.resumeAfterInterruption else {
                return
            }
            self.resumeAfterInterruption = false
            self.play()
        }
        session.onRouteLost = { [weak self] in
            self?.pause()
        }

        libavHost = LibavcodecAudioHost(
            onState: { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.route == .libavcodec else { return }
                    self.apply(state)
                }
            },
            onTime: { [weak self] time in
                Task { @MainActor in self?.elapsed = time }
            },
            onTrackChange: { [weak self] track in
                Task { @MainActor in self?.advance(to: track) }
            }
        )
    }

    public var currentTime: TimeInterval {
        switch route {
        case .avPlayer:
            return host.currentTime
        case .libavcodec:
            return libavHost?.currentTime ?? 0
        }
    }

    public var duration: TimeInterval {
        if queue.current?.streamMode == .live { return 0 }
        let hostDuration = host.duration
        return hostDuration > 0 ? hostDuration : (media?.duration ?? 0)
    }

    /// Snapshot for a diagnostics screen: route, codec and stream shape.
    public var diagnostics: PlaybackDiagnostics {
        let track = media?.audioTracks.first
        return PlaybackDiagnostics(
            route: route,
            container: media?.container,
            codec: track?.codec,
            sampleRate: track?.sampleRate,
            channels: track?.channels,
            isAtmos: track?.isAtmos ?? false,
            duration: duration,
            state: state
        )
    }

    public var volume: Float {
        get {
            switch route {
            case .avPlayer: return host.volume
            case .libavcodec: return libavHost?.volume ?? 1
            }
        }
        set {
            host.volume = newValue
            libavHost?.volume = newValue
        }
    }

    /// Probes the source, then picks the playback route.
    ///
    /// The probe runs off the main actor because `avformat_open_input` and
    /// `avformat_find_stream_info` can block on a slow source.
    public func load(
        url: URL,
        httpHeaders: [String: String] = [:],
        metadata: NowPlayingMetadata? = nil,
        sourceMIMEType: String? = nil,
        isAtmos: Bool = false,
        streamMode: StreamMode = .onDemand
    ) async throws {
        let track = ApoloTrack(
            url: url,
            httpHeaders: httpHeaders,
            metadata: metadata,
            sourceMIMEType: sourceMIMEType,
            isAtmos: isAtmos,
            streamMode: streamMode
        )
        cancelLiveReconnect()
        liveRetryAttempts = 0
        liveRetryOpening = false
        livePlayingSince = nil
        liveShouldPlay = true
        queue.start(track)
        loadEpoch &+= 1
        try await startPlayback(track, epoch: loadEpoch)
    }

    /// Start a live radio broadcast. This first route supports HLS and direct
    /// Apple-playable HTTP audio; Ogg/Opus live transport is a future route.
    /// Live mode never seeks or treats an unknown duration as end-of-file.
    public func loadLive(
        url: URL,
        httpHeaders: [String: String] = [:],
        metadata: NowPlayingMetadata? = nil,
        sourceMIMEType: String? = nil
    ) async throws {
        try await load(
            url: url,
            httpHeaders: httpHeaders,
            metadata: metadata,
            sourceMIMEType: sourceMIMEType,
            streamMode: .live
        )
    }

    private func startPlayback(_ track: ApoloTrack, epoch: UInt64) async throws {
        guard epoch == loadEpoch else { return }
        // A stop or station switch must cancel a blocked FFmpeg read before
        // the serial decoder queue can execute its normal stop operation.
        liveCancellation?.cancel()
        liveCancellation = nil
        state = .loading
        elapsed = 0
        media = nil
        metadata = track.metadata
        liveTitle = nil

        if track.streamMode == .live {
            if Self.supportsNativeLive(track.url, hint: track.sourceMIMEType) {
                guard epoch == loadEpoch else { return }
                try? session.activateMultichannel()
                metadataGainDB = nil
                applyProcessing()
                route = .avPlayer
                libavHost?.stop()
                await host.loadLive(track: track)
                refreshNowPlaying()
                return
            }

            guard Self.supportsFFmpegLive(track.url, hint: track.sourceMIMEType) else {
                host.stop()
                libavHost?.stop()
                state = .failed("Unsupported live radio format")
                throw ApoloError.unsupportedFormat
            }

            let cancellation = LiveStreamCancellation()
            liveCancellation = cancellation
            let onTitle: @Sendable (String) -> Void = { [weak self] title in
                Task { @MainActor [weak self] in
                    guard let self, self.loadEpoch == epoch else { return }
                    self.liveTitle = title
                }
            }
            let source: OpenedSource
            do {
                source = try await Task.detached(priority: .userInitiated) {
                    try OpenedSource.open(
                        url: track.url,
                        httpHeaders: track.httpHeaders,
                        isLive: true,
                        onICYTitle: onTitle,
                        liveCancellation: cancellation
                    )
                }.value
            } catch {
                if epoch == loadEpoch {
                    state = .failed("Could not open live audio")
                }
                throw error
            }
            guard epoch == loadEpoch, liveShouldPlay else {
                source.close()
                return
            }
            media = source.info
            try? session.activateMultichannel()
            metadataGainDB = source.info.trackGainDB
            applyProcessing()
            route = .libavcodec
            host.stop()
            libavHost?.load(source: source, isLive: true)
            refreshNowPlaying()
            return
        }

        // The FFmpeg build has no network protocols, and AVFoundation is the
        // native path for remote music (including Spatial/Atmos). Remote
        // sources skip the probe entirely; the local FFmpeg route keeps the
        // full codec/container probe.
        if isRemote(track.url)
            && !isExoticRemote(track.url, hint: track.sourceMIMEType) {
            guard epoch == loadEpoch else { return }
            try? session.activateMultichannel()
            metadataGainDB = nil
            applyProcessing()
            route = .avPlayer
            libavHost?.stop()
            await host.load(track: track)
            refreshNowPlaying()
            return
        }

        if let cached = MediaProbe.cachedInfo(
            url: track.url,
            httpHeaders: track.httpHeaders
        ) {
            media = cached
            try await applyRoute(
                track: track,
                info: cached,
                source: nil,
                epoch: epoch
            )
            return
        }

        let source: OpenedSource
        do {
            source = try await Task.detached(priority: .userInitiated) {
                try OpenedSource.open(
                    url: track.url,
                    httpHeaders: track.httpHeaders
                )
            }.value
        } catch {
            if epoch == loadEpoch {
                state = .failed("Could not open the source")
            }
            throw error
        }

        guard epoch == loadEpoch else {
            source.close()
            return
        }

        media = source.info
        MediaProbe.remember(
            source.info,
            url: track.url,
            httpHeaders: track.httpHeaders
        )
        try await applyRoute(
            track: track,
            info: source.info,
            source: source,
            epoch: epoch
        )
    }

    private func applyRoute(
        track: ApoloTrack,
        info: MediaInfo,
        source: OpenedSource?,
        epoch: UInt64
    ) async throws {
        guard epoch == loadEpoch else {
            source?.close()
            return
        }

        guard let audioTrack = info.audioTracks.first else {
            source?.close()
            state = .failed("No audio track")
            throw ApoloError.noAudioTrack
        }

        // A session failure degrades Spatial Audio, it must not strand the
        // engine in `.loading`.
        try? session.activateMultichannel()

        metadataGainDB = info.trackGainDB
        applyProcessing()

        let codecRoute: AudioRoute = isRemote(track.url)
            ? .libavcodec
            : CodecSupport.route(
                forCodec: audioTrack.codec,
                container: info.container
            )
        switch codecRoute {
        case .avPlayer:
            source?.close()
            route = .avPlayer
            libavHost?.stop()
            await host.load(track: track)
        case .libavcodec:
            route = .libavcodec
            host.stop()
            if let source {
                libavHost?.load(source: source)
            } else {
                libavHost?.load(
                    url: track.url,
                    httpHeaders: track.httpHeaders
                )
            }
        }

        refreshNowPlaying()
    }

    public func play() {
        resumeAfterInterruption = false
        if queue.current?.streamMode == .live {
            liveShouldPlay = true
            if case .failed = state {
                liveRetryAttempts = 0
                scheduleLiveReconnect()
                return
            }
        }
        switch route {
        case .avPlayer: host.play()
        case .libavcodec: libavHost?.play()
        }
    }

    public func pause() {
        resumeAfterInterruption = false
        if queue.current?.streamMode == .live {
            liveShouldPlay = false
            cancelLiveReconnect()
            if case .loading = state {
                liveCancellation?.cancel()
            }
        }
        pauseInternal()
    }

    private func pauseInternal() {
        switch route {
        case .avPlayer: host.pause()
        case .libavcodec: libavHost?.pause()
        }
    }

    public func togglePlayPause() {
        if state == .playing {
            pause()
        } else {
            play()
        }
    }

    public func seek(to seconds: TimeInterval) async {
        guard queue.current?.streamMode != .live else { return }
        switch route {
        case .avPlayer:
            await host.seek(to: seconds)
        case .libavcodec:
            libavHost?.seek(to: seconds)
        }
        elapsed = seconds
        refreshNowPlaying()
    }

    /// Queues a source to start when the current one ends, with no gap on the
    /// libavcodec route and no audible one on AVQueuePlayer.
    public func enqueueNext(_ track: ApoloTrack) async {
        guard queue.current?.streamMode != .live else { return }
        queue.enqueue(track)

        var prepared = track
        prepared.effectiveGainDB = trackGainDB
        if !isRemote(track.url) {
            let info: MediaInfo?
            if let cached = MediaProbe.cachedInfo(
                url: track.url,
                httpHeaders: track.httpHeaders
            ) {
                info = cached
            } else {
                info = try? await Task.detached(priority: .utility) {
                    try MediaProbe.probe(
                        url: track.url,
                        httpHeaders: track.httpHeaders
                    )
                }.value
            }
            if let info {
                prepared.media = info
                prepared.replayGainDB = info.trackGainDB
                prepared.effectiveGainDB = (info.trackGainDB ?? 0) + trackGainDB
                queue.replace(track, with: prepared)
            }
        }

        switch route {
        case .avPlayer:
            await host.enqueueNext(prepared)
        case .libavcodec:
            libavHost?.enqueueNext(prepared)
        }
    }

    public func clearQueue() {
        queue.clearUpcoming()
        host.clearUpcoming()
        libavHost?.clearNext()
    }

    /// Manual skip. Reloads the source through the normal route decision, so a
    /// codec change between tracks is handled.
    public func skipToNext() async throws {
        guard let next = queue.advance() else { return }
        cancelLiveReconnect()
        liveRetryAttempts = 0
        livePlayingSince = nil
        liveShouldPlay = true
        loadEpoch &+= 1
        try await startPlayback(next, epoch: loadEpoch)
    }

    public func skipToPrevious() async throws {
        guard let previous = queue.previous() else { return }
        cancelLiveReconnect()
        liveRetryAttempts = 0
        livePlayingSince = nil
        liveShouldPlay = true
        loadEpoch &+= 1
        try await startPlayback(previous, epoch: loadEpoch)
    }

    public func stop() {
        cancelLiveReconnect()
        liveShouldPlay = false
        liveRetryAttempts = 0
        liveRetryOpening = false
        livePlayingSince = nil
        loadEpoch &+= 1
        liveCancellation?.cancel()
        liveCancellation = nil
        host.stop()
        libavHost?.stop()
        route = .avPlayer
        session.deactivate()
        if managesSystemMediaControls {
            nowPlaying.clear()
        }
        media = nil
        elapsed = 0
        state = .idle
        queue.clear()
        metadata = nil
    }

    private func advanceFromQueue() {
        guard let next = queue.advance() else { return }
        applyAdvanced(next)
    }

    private func advance(to track: ApoloTrack) {
        if !queue.consume(track) {
            queue.start(track)
        }
        applyAdvanced(track)
    }

    private func applyAdvanced(_ track: ApoloTrack) {
        metadata = track.metadata
        metadataGainDB = track.replayGainDB
        media = track.media
        elapsed = 0
        applyProcessing()
        refreshNowPlaying()
    }

    private func isRemote(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Remote containers AVFoundation cannot play. They go through FFmpeg over
    /// the HTTP AVIO. Live/segmented streams are excluded on purpose: the HTTP
    /// source downloads a finite file.
    private func isExoticRemote(_ url: URL, hint: String? = nil) -> Bool {
        Self.shouldUseFFmpegForRemote(url, hint: hint)
    }

    /// The native live route handles HLS and Apple-playable HTTP audio only.
    /// Explicit mode avoids misclassifying ordinary songs with unknown length.
    nonisolated static func supportsNativeLive(
        _ url: URL, hint: String? = nil
    ) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        guard !["pls", "m3u", "xspf", "asx"].contains(ext) else { return false }
        return !shouldUseFFmpegForRemote(url, hint: hint)
    }

    /// Only exotic direct streams use the nonseekable FFmpeg live transport.
    /// Playlist URLs require a playlist resolver, not a byte-stream decoder.
    nonisolated static func supportsFFmpegLive(
        _ url: URL, hint: String? = nil
    ) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        guard !["m3u", "m3u8", "pls", "xspf", "asx"].contains(ext) else {
            return false
        }
        return shouldUseFFmpegForRemote(url, hint: hint)
    }

    /// True when a remote URL must go through FFmpeg. Local files are never
    /// included: local FLAC still plays through AVPlayer.
    nonisolated static func shouldUseFFmpegForRemote(
        _ url: URL,
        hint: String? = nil
    ) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        let normalizedHint = (hint ?? "").lowercased()
        if normalizedHint.contains("webm")
            || normalizedHint.contains("ogg")
            || normalizedHint.contains("opus")
            || normalizedHint.contains("matroska")
            || normalizedHint.contains("flac") {
            return true
        }
        if exoticRemoteExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        // Signed CDN URLs often have no extension; the MIME query is the
        // reliable signal (YouTube: `mime=audio%2Fwebm`).
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let mime = components?.queryItems?
            .first { $0.name.lowercased() == "mime" }?
            .value?
            .lowercased() ?? ""
        return mime.contains("webm")
            || mime.contains("ogg")
            || mime.contains("opus")
            || mime.contains("matroska")
            || mime.contains("flac")
    }

    nonisolated private static let exoticRemoteExtensions: Set<String> = [
        "ape", "tta", "wv", "tak", "mpc", "mp+",
        "dsf", "dff", "dsdiff", "aiff", "aif", "wma", "mka",
        "webm", "weba", "ogg", "oga", "opus", "flac",
    ]

    private func applyProcessing() {
        let gain = (metadataGainDB ?? 0) + trackGainDB
        host.configure(
            equalizer: equalizer,
            limiterEnabled: limiterEnabled,
            trackGainDB: gain
        )
        libavHost?.configure(
            equalizer: equalizer,
            limiterEnabled: limiterEnabled,
            trackGainDB: gain
        )
    }

    private func cancelLiveReconnect() {
        liveReconnectTask?.cancel()
        liveReconnectTask = nil
    }

    /// Only reconnect explicitly-live sources. A new connection always opens
    /// a fresh demuxer; reconnecting at an arbitrary Ogg/Opus byte boundary
    /// would corrupt compressed packets.
    private func scheduleLiveReconnect() {
        guard liveShouldPlay,
              !liveRetryOpening,
              liveReconnectTask == nil,
              let track = queue.current,
              track.streamMode == .live,
              liveCancellation?.terminalHTTPStatus == nil,
              let delay = LiveRetryPolicy.delay(forAttempt: liveRetryAttempts + 1)
        else { return }

        liveRetryAttempts += 1
        let expectedEpoch = loadEpoch
        liveReconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .milliseconds(Int(delay * 1_000))
                )
            } catch {
                return
            }
            guard let self,
                  self.loadEpoch == expectedEpoch,
                  self.liveShouldPlay,
                  self.queue.current == track else { return }
            self.liveReconnectTask = nil
            self.liveRetryOpening = true
            self.loadEpoch &+= 1
            let retryEpoch = self.loadEpoch
            do {
                try await self.startPlayback(track, epoch: retryEpoch)
                self.liveRetryOpening = false
                if self.loadEpoch == retryEpoch,
                   case .failed = self.state {
                    self.scheduleLiveReconnect()
                }
            } catch {
                self.liveRetryOpening = false
                guard self.loadEpoch == retryEpoch,
                      self.liveShouldPlay else { return }
                self.apply(.failed("Live stream reconnect failed"))
            }
        }
    }

    private func apply(_ newState: PlaybackState) {
        state = newState
        if queue.current?.streamMode == .live {
            switch newState {
            case .playing:
                if livePlayingSince == nil { livePlayingSince = Date() }
                cancelLiveReconnect()
            case .failed:
                if let since = livePlayingSince,
                   Date().timeIntervalSince(since) >= LiveRetryPolicy.resetAfterPlaying {
                    liveRetryAttempts = 0
                }
                livePlayingSince = nil
                scheduleLiveReconnect()
            case .idle, .loading, .paused, .finished:
                break
            }
        }
        refreshNowPlaying()
    }

    private func refreshNowPlaying() {
        guard managesSystemMediaControls, let metadata else { return }
        nowPlaying.update(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: duration,
            elapsed: elapsed,
            isPlaying: state == .playing,
            artworkData: metadata.artworkData
        )
    }
}
