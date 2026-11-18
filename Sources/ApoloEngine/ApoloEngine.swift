import Foundation
import Observation

/// Music and streaming engine.
///
/// AVFoundation is the playback engine for the codecs it handles. Everything
/// else goes through FFmpeg into an `AVSampleBufferAudioRenderer`, which keeps
/// Spatial Audio and Atmos available on the same session.
///
/// Create one instance and keep it for the app's lifetime.
@MainActor
@Observable
public final class ApoloEngine {
    public private(set) var state: PlaybackState = .idle
    public private(set) var media: MediaInfo?
    public private(set) var elapsed: TimeInterval = 0

    /// Five-band EQ. Applied on the libavcodec route; the AVPlayer route
    /// ignores it until the tap lands.
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

    private let host = AVPlayerHost()
    private let session = AudioSessionController()
    private let nowPlaying = NowPlayingController()
    private var libavHost: LibavcodecAudioHost?
    private var route: AudioRoute = .avPlayer
    private var metadata: NowPlayingMetadata?

    private var queue = PlayQueue()

    /// Sources queued after the current one. The hosts advance into them on
    /// their own; the engine only keeps the Now Playing card in sync.
    public var nextTracks: [ApoloTrack] { queue.upcoming }
    public var currentTrack: ApoloTrack? { queue.current }

    public init() {
        host.onState = { [weak self] state in
            self?.apply(state)
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
        nowPlaying.activate()

        libavHost = LibavcodecAudioHost(
            onState: { [weak self] state in
                Task { @MainActor in self?.apply(state) }
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
        let hostDuration = host.duration
        return hostDuration > 0 ? hostDuration : (media?.duration ?? 0)
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
        metadata: NowPlayingMetadata? = nil
    ) async throws {
        let track = ApoloTrack(
            url: url,
            httpHeaders: httpHeaders,
            metadata: metadata
        )
        queue.start(track)
        try await startPlayback(track)
    }

    private func startPlayback(_ track: ApoloTrack) async throws {
        state = .loading
        metadata = track.metadata

        let info = try await Task.detached(priority: .userInitiated) {
            try MediaProbe.probe(url: track.url, httpHeaders: track.httpHeaders)
        }.value
        media = info

        guard let audioTrack = info.audioTracks.first else {
            state = .failed("No audio track")
            throw ApoloError.noAudioTrack
        }

        try session.activateMultichannel()

        metadataGainDB = info.trackGainDB
        applyProcessing()

        switch CodecSupport.route(forCodec: audioTrack.codec) {
        case .avPlayer:
            route = .avPlayer
            libavHost?.stop()
            await host.load(track: track)
        case .libavcodec:
            route = .libavcodec
            host.stop()
            libavHost?.load(
                url: track.url,
                httpHeaders: track.httpHeaders
            )
        }

        refreshNowPlaying()
    }

    public func play() {
        switch route {
        case .avPlayer: host.play()
        case .libavcodec: libavHost?.play()
        }
    }

    public func pause() {
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
        switch route {
        case .avPlayer:
            await host.seek(to: seconds)
        case .libavcodec:
            libavHost?.seek(to: seconds)
        }
    }

    /// Queues a source to start when the current one ends, with no gap on the
    /// libavcodec route and no audible one on AVQueuePlayer.
    public func enqueueNext(_ track: ApoloTrack) async {
        queue.enqueue(track)
        switch route {
        case .avPlayer:
            await host.enqueueNext(track)
        case .libavcodec:
            libavHost?.enqueueNext(track)
        }
    }

    public func clearQueue() {
        queue.clearUpcoming()
    }

    /// Manual skip. Reloads the source through the normal route decision, so a
    /// codec change between tracks is handled.
    public func skipToNext() async throws {
        guard let next = queue.advance() else { return }
        try await startPlayback(next)
    }

    public func skipToPrevious() async throws {
        guard let previous = queue.previous() else { return }
        try await startPlayback(previous)
    }

    public func stop() {
        host.stop()
        libavHost?.stop()
        route = .avPlayer
        session.deactivate()
        nowPlaying.clear()
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
        metadataGainDB = nil
        elapsed = 0
        applyProcessing()
        refreshNowPlaying()
    }

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

    private func apply(_ newState: PlaybackState) {
        state = newState
        refreshNowPlaying()
    }

    private func refreshNowPlaying() {
        guard let metadata else { return }
        nowPlaying.update(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: duration,
            elapsed: elapsed,
            isPlaying: state == .playing
        )
    }
}
