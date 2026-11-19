import Foundation

/// Decides whether AVFoundation or libavcodec should play a source.
///
/// The codec alone is not enough: AVPlayer cannot open WebM/Matroska/Ogg
/// containers even when the codec inside is AAC, and it cannot decode Opus or
/// Vorbis from those containers either. The container wins when it is one of
/// the libav-only ones.
public enum CodecSupport {
    /// Audio codecs AVPlayer handles natively inside Apple containers.
    public static let avPlayerAudioCodecs: Set<String> = [
        "aac",
        "alac",
        "mp3",
        "mp2",
        "flac",
        "ac3",
        "eac3",
        "amr_nb",
        "amr_wb",
    ]

    private static let libavContainerMarkers = ["webm", "matroska", "ogg"]

    public static func route(
        forCodec codec: String,
        container: String? = nil
    ) -> AudioRoute {
        let codec = codec.lowercased()
        let container = (container ?? "").lowercased()

        if libavContainerMarkers.contains(where: { container.contains($0) }) {
            return .libavcodec
        }
        if codec == "opus" || codec == "vorbis" {
            return .libavcodec
        }
        return avPlayerAudioCodecs.contains(codec) ? .avPlayer : .libavcodec
    }
}
