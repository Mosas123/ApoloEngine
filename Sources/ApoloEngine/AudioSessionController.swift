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
    private let managesSession: Bool
    private var observers: [NSObjectProtocol] = []

    var onInterruptionBegan: (@MainActor () -> Void)?
    var onInterruptionEnded: (@MainActor (Bool) -> Void)?
    var onRouteLost: (@MainActor () -> Void)?

    init(managesSession: Bool = true) {
        self.managesSession = managesSession
        guard managesSession else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let info = notification.userInfo,
                      let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt
                else { return }
                let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                MainActor.assumeIsolated {
                    self?.handleInterruption(
                        typeRaw: typeRaw,
                        optionsRaw: optionsRaw
                    )
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let reasonRaw = notification
                    .userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                else { return }
                MainActor.assumeIsolated {
                    self?.handleRouteChange(reasonRaw: reasonRaw)
                }
            }
        )
    }

    func activateMultichannel() throws {
        guard managesSession else { return }
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
    }

    func deactivate() {
        guard managesSession else { return }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func handleInterruption(typeRaw: UInt, optionsRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            onInterruptionEnded?(options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    func handleRouteChange(reasonRaw: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }

        if reason == .oldDeviceUnavailable {
            onRouteLost?()
        }
    }
}
