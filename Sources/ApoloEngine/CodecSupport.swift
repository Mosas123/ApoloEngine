import Foundation

/// Decides whether AVFoundation can play a codec on its own.
///
/// The list is intentionally conservative. When a codec is not here the probe
/// has still done its job; the libavcodec route is where it goes next.
public enum CodecSupport {
    /// Audio codecs AVPlayer handles natively on current iOS.
    public static let avPlayerAudioCodecs: Set<String> = [
        "aac",
        "alac",
        "mp3",
        "mp2",
        "flac",
        "ac3",
        "eac3",
        "opus",
        "vorbis",
        "amr_nb",
        "amr_wb",
    ]

    public static func route(forCodec codec: String) -> AudioRoute {
        avPlayerAudioCodecs.contains(codec.lowercased()) ? .avPlayer : .libavcodec
    }
}
