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

    public init(title: String, artist: String, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

public enum ApoloError: Error, Sendable, Equatable {
    case openFailed(code: Int32)
    case unsupportedFormat
    case noAudioTrack
    case playbackUnavailable
}
