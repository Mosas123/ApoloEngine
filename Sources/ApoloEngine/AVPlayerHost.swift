import AVFoundation

/// AVFoundation playback host. Music path first: no video layer, no HLS server.
///
/// `AVQueuePlayer` plus one `MTAudioProcessingTap` per item gives gapless
/// transitions on the Apple-playable path.
@MainActor
final class AVPlayerHost {
    private let player = AVQueuePlayer()
    // Device crash mitigation: iOS 27.0.1 can EXC_BAD_ACCESS within
    // AVFCore's _pushTimedMetadataGroups while releasing an internal
    // metadata dictionary. Avoid installing AVPlayerItemMetadataOutput on
    // untrusted live HLS until a separately validated collector is ready.
    // ICY metadata on the FFmpeg live route remains fully supported.
    nonisolated static let nativeHLSTimedMetadataEnabled = false
    private var timeObserver: Any?
    private var wantsToPlay = false
    private var finished = false
    private var isLiveStream = false
    private var liveMetadataOutput: AVPlayerItemMetadataOutput?
    private var liveMetadataHandler: LiveTimedMetadataHandler?
    private var lastLiveTitle: String?
    private(set) var loadGeneration: UInt64 = 0
    private var lastState: PlaybackState = .idle
    private var tapProcessors: [AudioTapProcessor] = []
    private var endObservers: [NSObjectProtocol] = []
    private var lastObservedItem: AVPlayerItem?
    private var lastObservedTime: TimeInterval?
    private var lastObservedDuration: TimeInterval?
    private var clockAudit = NativeClockAudit()
    private(set) var nativeEndEvidence: NativeEndedItemEvidence?
    private var equalizer = EqualizerSettings.flat
    private var limiterEnabled = true
    private var trackGainDB: Double = 0

    var onState: (@MainActor (PlaybackState) -> Void)?
    var onTime: (@MainActor (TimeInterval) -> Void)?
    var onTrackChange: (@MainActor () -> Void)?
    var onLiveTitle: (@MainActor (String) -> Void)?
    var onNativeEndEvidence: (@MainActor (NativeEndedItemEvidence) -> Void)?
    var onNativeClockTrace: (@MainActor (NativeClockTrace) -> Void)?
    var onNativeAccessSummary: (@MainActor (TimeInterval?, Int) -> Void)?

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
        // AVQueuePlayer may have already dequeued the last item at EOF.
        // Reporting zero here invents a premature ending in the app layer.
        if finished && player.currentItem == nil {
            return nativeEndEvidence?.position ?? 0
        }
        let time = player.currentTime().seconds
        return time.isFinite && time >= 0 ? time : 0
    }

    var duration: TimeInterval {
        if finished && player.currentItem == nil {
            return nativeEndEvidence?.duration ?? 0
        }
        guard let duration = player.currentItem?.duration, duration.isNumeric,
              duration.seconds.isFinite, duration.seconds > 0 else { return 0 }
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
        loadGeneration &+= 1
        let generation = loadGeneration
        resetItems()
        finished = false
        isLiveStream = false
        wantsToPlay = true
        publish(.loading)

        let asset = makeAsset(track)
        let item = AVPlayerItem(asset: asset)
        let audioTrack = try? await asset
            .loadTracks(withMediaType: .audio)
            .first
        guard generation == loadGeneration else { return }
        guard let audioTrack else {
            // Fail fast: the monitor then hands the source to mpv without
            // waiting for the loading timeout.
            publish(.failed("This source has no audio track"))
            return
        }
        observeEnd(of: item)
        observeFailure(of: item)
        if !(track.isAtmos || Self.isSpatialCompressed(track.sourceMIMEType)) {
            attachTap(to: item, track: audioTrack)
        }
        player.insert(item, after: nil)
        // loadTracks suspends the main actor. An explicit Pause can happen
        // while the audio track is loading; never undo it with unconditional
        // autoplay when the asset eventually becomes ready.
        if wantsToPlay {
            player.play()
        } else {
            player.pause()
        }
        refreshState()
    }

    /// Native live streams have no finite audio track table or meaningful
    /// end time. Attach the player immediately instead of awaiting
    /// loadTracks(), which may stall on an endless HTTP response.
    func loadLive(track: ApoloTrack) async {
        loadGeneration &+= 1
        resetItems()
        finished = false
        isLiveStream = true
        wantsToPlay = true
        publish(.loading)

        let item = AVPlayerItem(asset: makeAsset(track))
        // Avoid AVPlayerItemMetadataOutput on iOS 27.0.1 live streams:
        // one physical-device crash occurred inside the AVFoundation
        // timed-metadata callback, after audio had started successfully.
        // The parser is retained for future investigation, but the native
        // output is explicitly disabled for the device beta.
        if Self.nativeHLSTimedMetadataEnabled {
            let generation = loadGeneration
            let output = AVPlayerItemMetadataOutput(identifiers: nil)
            let handler = LiveTimedMetadataHandler { [weak self] title in
                Task { @MainActor [weak self] in
                    guard let self, self.isLiveStream,
                          self.loadGeneration == generation,
                          self.lastLiveTitle != title else { return }
                    self.lastLiveTitle = title
                    self.onLiveTitle?(title)
                }
            }
            output.setDelegate(handler, queue: .main)
            item.add(output)
            liveMetadataOutput = output
            liveMetadataHandler = handler
        }
        observeEnd(of: item)
        observeFailure(of: item)
        // Do not attach MTAudioProcessingTap to live transport yet: native
        // HLS and indefinite audio may not expose a stable asset track.
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
        guard !isLiveStream else { return }
        let generation = loadGeneration
        let asset = makeAsset(track)
        let item = AVPlayerItem(asset: asset)
        let audioTrack = try? await asset
            .loadTracks(withMediaType: .audio)
            .first
        guard generation == loadGeneration else { return }
        guard let audioTrack else { return }
        observeEnd(of: item)
        observeFailure(of: item)
        if !(track.isAtmos || Self.isSpatialCompressed(track.sourceMIMEType)) {
            attachTap(to: item, track: audioTrack)
        }
        player.insert(item, after: player.items().last)
        if finished {
            finished = false
            // The successor may arrive after the listener pressed Pause
            // during an ended/loading transition. Honor that latest intent.
            if wantsToPlay {
                player.play()
            } else {
                player.pause()
            }
            refreshState()
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
        loadGeneration &+= 1
        wantsToPlay = false
        finished = false
        player.pause()
        resetItems()
        publish(.idle)
    }

    func seek(to seconds: TimeInterval) async {
        guard !isLiveStream else { return }
        // A seek may invalidate the previously observed time of this SAME
        // item. Never use its pre-seek clock to diagnose a later EOF.
        lastObservedTime = nil
        clockAudit.invalidateBaseline()
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

    nonisolated static func isSpatialCompressed(_ mime: String?) -> Bool {
        let normalized = (mime ?? "").lowercased()
        return normalized.contains("eac3")
            || normalized.contains("ec+3")
            || normalized.contains("ac3")
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
        let generation = loadGeneration
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let ended = notification.object as? AVPlayerItem else { return }
            // The block runs on the main queue, so reading the player here is
            // safe without crossing an isolation boundary.
            MainActor.assumeIsolated {
                guard let self, self.loadGeneration == generation else { return }
                self.handleEnd(of: ended)
            }
        }
        endObservers.append(token)
    }

    private func observeFailure(of item: AVPlayerItem) {
        let generation = loadGeneration
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loadGeneration == generation else { return }
                if self.isLiveStream { self.finished = true }
                self.publish(.failed("Playback failed"))
            }
        }
        endObservers.append(token)
    }

    private func handleEnd(of ended: AVPlayerItem) {
        guard !finished else { return }
        if isLiveStream {
            // A live station going silent is not the end of a song or queue.
            // Keep the failure stable; the periodic tick must not turn it
            // back into "loading" before a reconnection is attempted.
            finished = true
            publish(.failed("Live stream ended"))
            return
        }
        // Sample the notification's item, never the possibly nil/new
        // AVQueuePlayer.currentItem. Previous-track observations are rejected.
        let itemPosition = ended.currentTime()
        let itemDuration = ended.duration
        let evidence = NativeEndedItemEvidence.make(
            endedPosition: itemPosition.isNumeric ? itemPosition.seconds : nil,
            endedDuration: itemDuration.isNumeric ? itemDuration.seconds : nil,
            lastObservedPosition: lastObservedTime,
            lastObservedDuration: lastObservedDuration,
            observationMatchesEndedItem: lastObservedItem === ended
        )
        nativeEndEvidence = evidence
        onNativeEndEvidence?(evidence)
        if let position = evidence.position,
           let finalClock = clockAudit.finish(
               position: position,
               uptime: ProcessInfo.processInfo.systemUptime,
               playerRate: Double(player.rate),
               motion: nativeClockMotion
           ) {
            onNativeClockTrace?(finalClock)
        }
        if let lastAccess = ended.accessLog()?.events.last {
            let watched = lastAccess.durationWatched
            onNativeAccessSummary?(
                watched.isFinite && watched >= 0 ? watched : nil,
                lastAccess.numberOfStalls
            )
        }

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
        // AVPlayerItemMetadataOutput retains no delegate. Remove it before
        // releasing the handler, so obsolete station events stop arriving.
        if let output = liveMetadataOutput {
            output.setDelegate(nil, queue: nil)
            for item in player.items() {
                item.remove(output)
            }
        }
        liveMetadataOutput = nil
        liveMetadataHandler = nil
        lastLiveTitle = nil
        for observer in endObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        endObservers.removeAll()
        nativeEndEvidence = nil
        lastObservedItem = nil
        lastObservedTime = nil
        lastObservedDuration = nil
        clockAudit.reset()
        isLiveStream = false
        tapProcessors.removeAll()
        player.removeAllItems()
    }

    private func tick(_ time: CMTime) {
        if !isLiveStream, let item = player.currentItem {
            if item !== lastObservedItem {
                lastObservedTime = nil
                lastObservedDuration = nil
                lastObservedItem = item
                clockAudit.reset()
            }
            let position = item.currentTime()
            if position.isNumeric && position.seconds.isFinite && position.seconds >= 0 {
                lastObservedTime = position.seconds
                if let trace = clockAudit.observe(
                    position: position.seconds,
                    uptime: ProcessInfo.processInfo.systemUptime,
                    playerRate: Double(player.rate),
                    motion: nativeClockMotion
                ) {
                    onNativeClockTrace?(trace)
                }
            }
            let length = item.duration
            if length.isNumeric && length.seconds.isFinite && length.seconds > 0 {
                lastObservedDuration = length.seconds
            }
        }
        if time.isNumeric {
            onTime?(isLiveStream ? 0 : time.seconds)
        }
        refreshState()
    }

    private var nativeClockMotion: NativeClockMotion {
        switch player.timeControlStatus {
        case .playing: return .playing
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .waiting
        @unknown default: return .waiting
        }
    }

    private func refreshState() {
        guard !finished else { return }
        guard let item = player.currentItem else {
            publish(.idle)
            return
        }
        if item.status == .failed {
            // Never surface AVFoundation's error text: it can contain the
            // signed URL. The app only needs to know that it failed.
            publish(.failed("Playback failed"))
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
