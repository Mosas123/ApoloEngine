import Foundation
import Observation

/// Music and streaming engine.
///
/// AVFoundation is the playback engine. FFmpeg probes every source first and
/// is the route for codecs AVFoundation cannot play. This first version
/// implements the AVPlayer path; the libavcodec route is the next milestone.
///
/// Create one instance and keep it for the app's lifetime.
@MainActor
@Observable
public final class ApoloEngine {
    public private(set) var state: PlaybackState = .idle
    public private(set) var media: MediaInfo?
    public private(set) var elapsed: TimeInterval = 0

    private let host = AVPlayerHost()
    private let session = AudioSessionController()
    private let nowPlaying = NowPlayingController()
    private var metadata: NowPlayingMetadata?

    public init() {
        host.onState = { [weak self] state in
            self?.state = state
            self?.refreshNowPlaying()
        }
        host.onTime = { [weak self] time in
            self?.elapsed = time
        }
        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onSeek = { [weak self] time in
            Task { await self?.seek(to: time) }
        }
        nowPlaying.activate()
    }

    public var currentTime: TimeInterval {
        host.currentTime
    }

    public var duration: TimeInterval {
        host.duration
    }

    public var volume: Float {
        get { host.volume }
        set { host.volume = newValue }
    }

    /// Probes the source, then hands it to AVFoundation.
    ///
    /// The probe runs off the main actor because `avformat_open_input` and
    /// `avformat_find_stream_info` can block for seconds on a slow CDN.
    public func load(
        url: URL,
        httpHeaders: [String: String] = [:],
        metadata: NowPlayingMetadata? = nil
    ) async throws {
        state = .loading
        self.metadata = metadata

        let info = try await Task.detached(priority: .userInitiated) {
            try MediaProbe.probe(url: url, httpHeaders: httpHeaders)
        }.value
        media = info

        guard let track = info.audioTracks.first else {
            state = .failed("No audio track")
            throw ApoloError.noAudioTrack
        }

        switch CodecSupport.route(forCodec: track.codec) {
        case .avPlayer:
            try session.activateMultichannel()
            host.load(url: url, httpHeaders: httpHeaders)
            refreshNowPlaying()
        case .libavcodec:
            state = .failed("libavcodec route not implemented yet")
            throw ApoloError.unsupportedFormat
        }
    }

    public func play() {
        host.play()
    }

    public func pause() {
        host.pause()
    }

    public func togglePlayPause() {
        if state == .playing {
            pause()
        } else {
            play()
        }
    }

    public func seek(to seconds: TimeInterval) async {
        await host.seek(to: seconds)
    }

    public func stop() {
        host.stop()
        session.deactivate()
        nowPlaying.clear()
        media = nil
        elapsed = 0
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
