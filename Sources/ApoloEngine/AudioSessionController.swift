import AVFoundation
import Foundation

/// Owns the `AVAudioSession` for music playback and reports the interruptions
/// and route changes the engine reacts to.
///
/// `setSupportsMultichannelContent(true)` is what turns on Spatial Audio for
/// multichannel content on AirPods. Without it the system treats the app as
/// plain stereo even when the engine delivers a surround bed.
@MainActor
final class AudioSessionController {
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    var onInterruptionBegan: (@MainActor () -> Void)?
    var onInterruptionEnded: (@MainActor (Bool) -> Void)?
    var onRouteLost: (@MainActor () -> Void)?

    init() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleInterruption(notification)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleRouteChange(notification)
                }
            }
        )
    }

    func activateMultichannel() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            onInterruptionEnded?(options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        if reason == .oldDeviceUnavailable {
            onRouteLost?()
        }
    }
}
