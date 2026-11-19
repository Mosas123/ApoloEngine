import AVFoundation

/// AVFoundation playback host. Music path first: no video layer, no HLS server.
///
/// `AVQueuePlayer` plus one `MTAudioProcessingTap` per item gives gapless
/// transitions on the Apple-playable path.
@MainActor
final class AVPlayerHost {
    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var wantsToPlay = false
    private var finished = false
    private var lastState: PlaybackState = .idle
    private var tapProcessors: [AudioTapProcessor] = []
    private var endObservers: [NSObjectProtocol] = []
    private var equalizer = EqualizerSettings.flat
    private var limiterEnabled = true
    private var trackGainDB: Double = 0

    var onState: (@MainActor (PlaybackState) -> Void)?
    var onTime: (@MainActor (TimeInterval) -> Void)?
    var onTrackChange: (@MainActor () -> Void)?

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

    func configure(
        equalizer: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        self.equalizer = equalizer
        self.limiterEnabled = limiterEnabled
        self.trackGainDB = trackGainDB
        for processor in tapProcessors {
            processor.update(
                equalizer: equalizer,
                limiterEnabled: limiterEnabled,
                trackGainDB: trackGainDB
            )
        }
    }

    func load(url: URL, httpHeaders: [String: String]) async {
        await load(
            track: ApoloTrack(url: url, httpHeaders: httpHeaders)
        )
    }

    func load(track: ApoloTrack) async {
        resetItems()
        finished = false
        wantsToPlay = true
        publish(.loading)

        let asset = makeAsset(track)
        let item = AVPlayerItem(asset: asset)
        guard let audioTrack = try? await asset
            .loadTracks(withMediaType: .audio)
            .first
        else {
            // Fail fast: the monitor then hands the source to mpv without
            // waiting for the loading timeout.
            publish(.failed("This source has no audio track"))
            return
        }
        observeEnd(of: item)
        observeFailure(of: item)
        attachTap(to: item, track: audioTrack)
        player.insert(item, after: nil)
        player.play()
    }

    func clearUpcoming() {
        let items = player.items()
        guard items.count > 1 else { return }
        for item in items.dropFirst() {
            player.remove(item)
        }
    }

    func enqueueNext(_ track: ApoloTrack) async {
        let asset = makeAsset(track)
        let item = AVPlayerItem(asset: asset)
        guard let audioTrack = try? await asset
            .loadTracks(withMediaType: .audio)
            .first
        else {
            return
        }
        observeEnd(of: item)
        observeFailure(of: item)
        attachTap(to: item, track: audioTrack)
        player.insert(item, after: player.items().last)
        if finished {
            finished = false
            wantsToPlay = true
            player.play()
        }
    }

    func play() {
        wantsToPlay = true
        finished = false
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
        finished = false
        player.pause()
        resetItems()
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

    private func makeAsset(_ track: ApoloTrack) -> AVURLAsset {
        if track.httpHeaders.isEmpty {
            return AVURLAsset(url: track.url)
        }
        return AVURLAsset(
            url: track.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": track.httpHeaders]
        )
    }

    private func attachTap(to item: AVPlayerItem, track: AVAssetTrack) {
        let processor = AudioTapProcessor(
            equalizer: equalizer,
            limiterEnabled: limiterEnabled,
            trackGainDB: trackGainDB
        )
        guard let tap = processor.makeTap() else { return }
        tapProcessors.append(processor)

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func observeEnd(of item: AVPlayerItem) {
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let ended = notification.object as? AVPlayerItem else { return }
            // The block runs on the main queue, so reading the player here is
            // safe without crossing an isolation boundary.
            MainActor.assumeIsolated {
                self?.handleEnd(of: ended)
            }
        }
        endObservers.append(token)
    }

    private func observeFailure(of item: AVPlayerItem) {
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish(.failed("Playback failed"))
            }
        }
        endObservers.append(token)
    }

    private func handleEnd(of ended: AVPlayerItem) {
        guard let last = player.items().last else {
            finished = true
            publish(.finished)
            return
        }
        // Compare the item that actually ended, not `currentItem`: by the time
        // the notification runs AVQueuePlayer may already have advanced.
        if ended === last {
            finished = true
            publish(.finished)
        } else {
            onTrackChange?()
        }
    }

    private func resetItems() {
        for observer in endObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        endObservers.removeAll()
        tapProcessors.removeAll()
        player.removeAllItems()
    }

    private func tick(_ time: CMTime) {
        if time.isNumeric {
            onTime?(time.seconds)
        }
        refreshState()
    }

    private func refreshState() {
        guard !finished else { return }
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
