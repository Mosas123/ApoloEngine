import AVFoundation

/// AVFoundation playback host. Music path first: no video layer, no HLS server.
@MainActor
final class AVPlayerHost {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var wantsToPlay = false
    private var lastState: PlaybackState = .idle

    var onState: (@MainActor (PlaybackState) -> Void)?
    var onTime: (@MainActor (TimeInterval) -> Void)?

    init() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
    }

    var currentTime: TimeInterval {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    var duration: TimeInterval {
        guard let duration = player.currentItem?.duration, duration.isNumeric else {
            return 0
        }
        return duration.seconds
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func load(url: URL, httpHeaders: [String: String]) {
        let asset: AVURLAsset
        if httpHeaders.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders]
            )
        }
        wantsToPlay = true
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.play()
        publish(.loading)
    }

    func play() {
        wantsToPlay = true
        player.play()
        refreshState()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        refreshState()
    }

    func stop() {
        wantsToPlay = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        publish(.idle)
    }

    func seek(to seconds: TimeInterval) async {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        _ = await player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func tick(_ time: CMTime) {
        if time.isNumeric {
            onTime?(time.seconds)
        }
        refreshState()
    }

    private func refreshState() {
        guard let item = player.currentItem else {
            publish(.idle)
            return
        }
        if item.status == .failed {
            let message = item.error?.localizedDescription ?? "Playback failed"
            publish(.failed(message))
        } else if wantsToPlay {
            publish(player.timeControlStatus == .playing ? .playing : .loading)
        } else {
            publish(.paused)
        }
    }

    private func publish(_ state: PlaybackState) {
        guard state != lastState else { return }
        lastState = state
        onState?(state)
    }
}
