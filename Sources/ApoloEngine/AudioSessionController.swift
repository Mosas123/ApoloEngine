import AVFoundation

/// Owns the AVAudioSession for music playback.
///
/// `setSupportsMultichannelContent(true)` is what turns on Spatial Audio for
/// multichannel content on AirPods. Without it the system treats the app as
/// plain stereo even when the engine delivers a surround bed.
@MainActor
final class AudioSessionController {
    private let session = AVAudioSession.sharedInstance()

    func activateMultichannel() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
