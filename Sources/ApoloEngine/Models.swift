import Foundation

/// One audio stream found by the probe.
public struct AudioTrackInfo: Sendable, Equatable {
    public let index: Int
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let isAtmos: Bool

    public init(
        index: Int,
        codec: String,
        sampleRate: Int,
        channels: Int,
        isAtmos: Bool
    ) {
        self.index = index
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.isAtmos = isAtmos
    }
}

/// Container and stream metadata for a source.
public struct MediaInfo: Sendable, Equatable {
    public let container: String
    public let duration: TimeInterval
    public let audioTracks: [AudioTrackInfo]
    /// ReplayGain track gain from the container metadata, in dB, when present.
    public let trackGainDB: Double?

    public init(
        container: String,
        duration: TimeInterval,
        audioTracks: [AudioTrackInfo],
        trackGainDB: Double? = nil
    ) {
        self.container = container
        self.duration = duration
        self.audioTracks = audioTracks
        self.trackGainDB = trackGainDB
    }
}

/// Which playback route a track should take.
public enum AudioRoute: Sendable, Equatable {
    /// AVFoundation plays the source directly.
    case avPlayer
    /// libavcodec decodes and feeds `AVSampleBufferAudioRenderer`.
    case libavcodec
}

/// Explicit source lifetime. A live broadcast is never inferred from a
/// missing duration: unresolved songs may also report zero duration.
public enum StreamMode: Sendable, Equatable {
    case onDemand
    case live
}

/// One queued source. The engine uses it to keep gapless playback going and to
/// update the Now Playing card across track boundaries.
public struct ApoloTrack: Sendable, Equatable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let metadata: NowPlayingMetadata?
    /// MIME from the resolver. It lets opaque signed URLs (no extension and no
    /// `mime` query) pick the right route.
    public let sourceMIMEType: String?
    public let isAtmos: Bool
    public let streamMode: StreamMode

    // Filled by the engine when the track is queued. They are playback
    // details, not identity, so equality ignores them.
    var media: MediaInfo?
    var replayGainDB: Double?
    var effectiveGainDB: Double = 0

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        metadata: NowPlayingMetadata? = nil,
        sourceMIMEType: String? = nil,
        isAtmos: Bool = false,
        streamMode: StreamMode = .onDemand
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.metadata = metadata
        self.sourceMIMEType = sourceMIMEType
        self.isAtmos = isAtmos
        self.streamMode = streamMode
    }

    public static func == (lhs: ApoloTrack, rhs: ApoloTrack) -> Bool {
        lhs.url == rhs.url
            && lhs.httpHeaders == rhs.httpHeaders
            && lhs.metadata == rhs.metadata
            && lhs.streamMode == rhs.streamMode
    }
}

/// Read-only snapshot for a debug/diagnostics screen or on-device support.
public struct PlaybackDiagnostics: Sendable, Equatable {
    public let route: AudioRoute
    public let container: String?
    public let codec: String?
    public let sampleRate: Int?
    public let channels: Int?
    public let isAtmos: Bool
    public let duration: TimeInterval
    public let state: PlaybackState

    public init(
        route: AudioRoute,
        container: String?,
        codec: String?,
        sampleRate: Int?,
        channels: Int?,
        isAtmos: Bool,
        duration: TimeInterval,
        state: PlaybackState
    ) {
        self.route = route
        self.container = container
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.isAtmos = isAtmos
        self.duration = duration
        self.state = state
    }
}

/// Playback lifecycle.
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case finished
    case failed(String)
}

/// Metadata for the system Now Playing card.
public struct NowPlayingMetadata: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String?
    /// Encoded image (PNG/JPEG) for the lock screen and Control Center.
    public let artworkData: Data?

    public init(
        title: String,
        artist: String,
        album: String? = nil,
        artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
    }
}

public enum ApoloError: Error, Sendable, Equatable {
    case openFailed(code: Int32)
    case readFailed(code: Int32)
    case unsupportedFormat
    case noAudioTrack
    case playbackUnavailable
}

extension ApoloError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openFailed(let code):
            return "The source could not be opened (FFmpeg error \(code))."
        case .readFailed(let code):
            return "The stream could not be read (FFmpeg error \(code))."
        case .unsupportedFormat:
            return "This audio format is not supported."
        case .noAudioTrack:
            return "The source has no audio track."
        case .playbackUnavailable:
            return "Playback is not available right now."
        }
    }
}
