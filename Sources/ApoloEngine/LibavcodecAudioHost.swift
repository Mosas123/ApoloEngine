import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// libavcodec -> `AVSampleBufferAudioRenderer` playback host.
///
/// The decoder and the renderer plumbing live on one serial queue; the public
/// methods only hop onto it. State and time callbacks are `@Sendable`, so the
/// caller can bounce them to the main actor.
final class LibavcodecAudioHost: @unchecked Sendable {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(
        label: "com.apolo.engine.audio",
        qos: .userInitiated
    )

    // Session identifiers are captured with every async callback. An old
    // decoder's queued state/time event must never overwrite a new station.
    private let onState: @Sendable (PlaybackState, UInt64) -> Void
    private let onTime: @Sendable (TimeInterval, UInt64) -> Void
    private let onTrackChange: @Sendable (ApoloTrack, UInt64) -> Void
    private let diagnostics: AudioDiagnostics
    private let epochLock = NSLock()
    private var playbackEpoch: UInt64 = 0

    private var decoder: AudioDecoder?
    private var timeObserver: Any?
    private var automaticFlushObserver: NSObjectProtocol?
    private var requesting = false
    private var started = false
    private var isLive = false
    private var wantsToPlay = false
    private var equalizer = EqualizerSettings.flat
    private var limiterEnabled = true
    private var trackGainDB: Double = 0
    private var nextTrack: ApoloTrack?
    private var timelineEnd: TimeInterval = 0
    /// Absolute synchronizer position where the current track starts. The
    /// public time is always relative to it, even after gapless switches.
    private var trackStart: TimeInterval = 0
    private let timelineLock = NSLock()
    private var finishToken: UInt64 = 0

    init(
        onState: @escaping @Sendable (PlaybackState, UInt64) -> Void,
        onTime: @escaping @Sendable (TimeInterval, UInt64) -> Void,
        onTrackChange: @escaping @Sendable (ApoloTrack, UInt64) -> Void,
        diagnostics: AudioDiagnostics = AudioDiagnostics()
    ) {
        self.onState = onState
        self.onTime = onTime
        self.onTrackChange = onTrackChange
        self.diagnostics = diagnostics
        synchronizer.addRenderer(renderer)
        // Delay the initial rate change until AVFoundation has buffered enough
        // audio for a reliable start. Without this, the media clock can run
        // ahead of the very first PCM and make the intro sound clipped.
        // This applies to resumed/seeking playback too, without adding
        // synthetic silence or changing sample timestamps.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        // Apple can automatically flush queued samples during rate changes.
        // Observe without changing playback yet; the iPhone A/B logs can show
        // whether a flush is correlated with the clipped initial transient.
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] notification in
            let seconds = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey]
                as? NSValue)?.timeValue.seconds
            self?.queue.async { [weak self] in
                guard let self else { return }
                let timestamp = seconds.map { String(format: "%.3f", $0) } ?? "unknown"
                self.diagnostics.emit(
                    "renderer.autoFlush epoch=\(self.currentPlaybackEpoch) "
                        + "flushAt=\(timestamp) "
                        + "started=\(self.started) wantsPlay=\(self.wantsToPlay)"
                )
            }
        }
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, time.isNumeric else { return }
            self.onTime(
                max(0, time.seconds - self.currentTrackStart),
                self.currentPlaybackEpoch
            )
        }
    }

    deinit {
        if let automaticFlushObserver {
            NotificationCenter.default.removeObserver(automaticFlushObserver)
        }
    }

    private var currentPlaybackEpoch: UInt64 {
        epochLock.lock()
        defer { epochLock.unlock() }
        return playbackEpoch
    }

    private func setPlaybackEpoch(_ epoch: UInt64) {
        epochLock.lock()
        playbackEpoch = epoch
        epochLock.unlock()
    }

    var currentTime: TimeInterval {
        let seconds = synchronizer.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        return max(0, seconds - currentTrackStart)
    }

    private var currentTrackStart: TimeInterval {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        return trackStart
    }

    private func setTrackStart(_ value: TimeInterval) {
        timelineLock.lock()
        trackStart = value
        timelineLock.unlock()
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    func load(url: URL, httpHeaders: [String: String], epoch: UInt64 = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            self.setPlaybackEpoch(epoch)
            self.reset()
            do {
                let decoder = AudioDecoder()
                decoder.processingSettings = self.equalizer
                decoder.limiterEnabled = self.limiterEnabled
                decoder.trackGainDB = self.trackGainDB
                try decoder.open(
                    url: url, httpHeaders: httpHeaders, diagnostics: self.diagnostics
                )
                self.decoder = decoder
                self.wantsToPlay = true
                self.publish(.loading)
                self.startRequesting()
            } catch {
                self.publish(.failed(Self.describe(error)))
            }
        }
    }

    /// Adopts a source the engine already opened and probed.
    func load(
        source: OpenedSource,
        isLive: Bool = false,
        epoch: UInt64 = 0
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.setPlaybackEpoch(epoch)
            self.reset()
            self.isLive = isLive
            do {
                let decoder = AudioDecoder()
                decoder.processingSettings = self.equalizer
                decoder.limiterEnabled = self.limiterEnabled
                decoder.trackGainDB = self.trackGainDB
                try decoder.adopt(source)
                self.decoder = decoder
                self.wantsToPlay = true
                self.publish(.loading)
                self.startRequesting()
            } catch {
                self.publish(.failed(Self.describe(error)))
            }
        }
    }

    func play() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsToPlay = true
            if self.started {
                self.synchronizer.setRate(1, time: self.synchronizer.currentTime())
            }
            self.publish(.playing)
            self.startRequesting()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsToPlay = false
            if self.started {
                self.synchronizer.setRate(0, time: self.synchronizer.currentTime())
            }
            self.publish(.paused)
        }
    }

    func seek(to seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self, let decoder = self.decoder else { return }
            do {
                let relativeTarget = max(0, seconds)
                let target = self.currentTrackStart + relativeTarget
                try decoder.seek(to: relativeTarget)
                // Never run the synchronizer across an empty flushed renderer:
                // the old code resumed rate=1 here, before the first new PCM.
                // First PCM now re-arms playback with the preroll gate.
                self.synchronizer.setRate(0, time: self.synchronizer.currentTime())
                self.renderer.flush()
                self.started = false
                self.timelineEnd = target
                self.finishToken &+= 1
                self.synchronizer.setRate(
                    0,
                    time: CMTime(seconds: target, preferredTimescale: 600)
                )
                self.diagnostics.emit(
                    "renderer.seek epoch=\(self.currentPlaybackEpoch) "
                        + "target=\(String(format: "%.3f", relativeTarget)) "
                        + "wantsPlay=\(self.wantsToPlay) awaitingFirstPCM=true"
                )
                // Prepare the first sample even if the user seeks while
                // paused; setRate(0) keeps it silent until Play.
                self.startRequesting()
            } catch {
                self.publish(.failed("Seek failed"))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reset()
            self.publish(.idle)
        }
    }

    func configure(
        equalizer: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.equalizer = equalizer
            self.limiterEnabled = limiterEnabled
            self.trackGainDB = trackGainDB
            self.decoder?.updateProcessing(
                settings: equalizer,
                limiterEnabled: limiterEnabled,
                trackGainDB: trackGainDB
            )
        }
    }

    private func startRequesting() {
        guard !requesting, decoder != nil else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.provideMoreMedia()
        }
    }

    private func provideMoreMedia() {
        // One buffer per callback. The renderer calls this again as soon as
        // it wants more, so control commands queued on this serial queue
        // (pause, seek, load) run between refill steps instead of waiting for
        // a long burst to finish.
        guard renderer.isReadyForMoreMediaData else { return }
        guard let decoder else {
            requesting = false
            return
        }

        let buffer: CMSampleBuffer?
        let readStarted = DispatchTime.now().uptimeNanoseconds
        let beforeClock = synchronizer.currentTime().seconds
        let beforeAhead = max(0, timelineEnd - beforeClock)
        do {
            buffer = try decoder.readNextBuffer()
        } catch {
            diagnostics.emit(
                "renderer.decodeFailure epoch=\(currentPlaybackEpoch) "
                    + "readMs=\(AudioDiagnostics.elapsedMs(since: readStarted)) "
                    + "clock=\(String(format: "%.3f", beforeClock)) "
                    + "ahead=\(String(format: "%.3f", beforeAhead))"
            )
            requesting = false
            renderer.stopRequestingMediaData()
            synchronizer.setRate(0, time: synchronizer.currentTime())
            publish(.failed(Self.describe(error)))
            return
        }

        let readMs = AudioDiagnostics.elapsedMs(since: readStarted)
        if readMs >= 120, !isLive {
            let afterClock = synchronizer.currentTime().seconds
            diagnostics.emit(
                "renderer.slowDecode epoch=\(currentPlaybackEpoch) ms=\(readMs) "
                    + "aheadBefore=\(String(format: "%.3f", beforeAhead)) "
                    + "aheadAfter=\(String(format: "%.3f", max(0, timelineEnd - afterClock))) "
                    + "sample=\(buffer == nil ? "eof" : "pcm")"
            )
        }
        if let buffer {
            enqueueDecoded(buffer)
            return
        }

        if isLive {
            // Indefinite stations must not complete the track or auto-advance
            // a song queue when a decoder reports EOF.
            requesting = false
            renderer.stopRequestingMediaData()
            synchronizer.setRate(0, time: synchronizer.currentTime())
            publish(.failed("Live stream ended"))
            return
        }

        if let next = nextTrack, start(next: next) {
            nextTrack = nil
            if let newDecoder = self.decoder,
               let first = try? newDecoder.readNextBuffer() {
                enqueueDecoded(first)
            }
            return
        }

        diagnostics.emit(
            "renderer.decoderEOF epoch=\(currentPlaybackEpoch) "
                + "clock=\(String(format: "%.3f", synchronizer.currentTime().seconds)) "
                + "timelineEnd=\(String(format: "%.3f", timelineEnd)) "
                + "remaining=\(String(format: "%.3f", max(0, timelineEnd - synchronizer.currentTime().seconds))) "
                + "wantsPlay=\(wantsToPlay)"
        )
        requesting = false
        renderer.stopRequestingMediaData()
        // The renderer still holds enqueued audio. Do not stop the clock now
        // or the tail of every track is cut. Finish once the last queued
        // buffer should have played.
        let remaining = max(
            0,
            timelineEnd - synchronizer.currentTime().seconds
        )
        finishToken &+= 1
        let token = finishToken
        diagnostics.emit(
            "renderer.finishScheduled epoch=\(currentPlaybackEpoch) "
                + "remaining=\(String(format: "%.3f", remaining)) token=\(token)"
        )
        queue.asyncAfter(deadline: .now() + remaining + 0.3) { [weak self] in
            guard let self, self.finishToken == token else { return }
            self.diagnostics.emit(
                "renderer.finishFired epoch=\(self.currentPlaybackEpoch) "
                    + "clock=\(String(format: "%.3f", self.synchronizer.currentTime().seconds)) "
                    + "timelineEnd=\(String(format: "%.3f", self.timelineEnd)) "
                    + "ahead=\(String(format: "%.3f", max(0, self.timelineEnd - self.synchronizer.currentTime().seconds))) "
                    + "wantsPlay=\(self.wantsToPlay)"
            )
            self.synchronizer.setRate(0, time: self.synchronizer.currentTime())
            self.publish(.finished)
        }
    }

    private func enqueueDecoded(_ buffer: CMSampleBuffer) {
        if !started {
            started = true
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            if !isLive {
                diagnostics.emit(
                    "renderer.firstPCM epoch=\(currentPlaybackEpoch) "
                        + "pts=\(String(format: "%.3f", start.seconds)) "
                        + "clockBefore=\(String(format: "%.3f", synchronizer.currentTime().seconds)) "
                        + "wantsPlay=\(wantsToPlay) "
                        + "prerollGate=\(synchronizer.delaysRateChangeUntilHasSufficientMediaData)"
                )
            }
            synchronizer.setRate(wantsToPlay ? 1 : 0, time: start)
            if isLive && wantsToPlay {
                publish(.playing)
            }
        }
        timelineEnd = max(timelineEnd, Self.endSeconds(of: buffer))
        renderer.enqueue(buffer)
    }

    func enqueueNext(_ track: ApoloTrack) {
        queue.async { [weak self] in
            guard let self, !self.isLive else { return }
            self.nextTrack = track
            self.finishToken &+= 1
            // The host may have already reached `.finished`; restart the
            // renderer so the queued track actually plays. Clearing `started`
            // makes the first new buffer re-arm the synchronizer rate.
            if !self.requesting {
                self.started = false
                self.startRequesting()
            }
        }
    }

    func clearNext() {
        queue.async { [weak self] in
            self?.nextTrack = nil
        }
    }

    /// Opens the next source on the running synchronizer and hands it the
    /// timeline position the previous track ended at. Returns false when the
    /// source cannot be opened.
    private func start(next track: ApoloTrack) -> Bool {
        do {
            let decoder = AudioDecoder()
            decoder.processingSettings = equalizer
            decoder.limiterEnabled = limiterEnabled
            decoder.trackGainDB = track.effectiveGainDB
            self.trackGainDB = track.effectiveGainDB
            decoder.startOffsetSeconds = max(
                timelineEnd,
                synchronizer.currentTime().seconds
            )
            try decoder.open(
                url: track.url,
                httpHeaders: track.httpHeaders,
                diagnostics: diagnostics
            )
            self.decoder?.close()
            self.decoder = decoder
            self.setTrackStart(decoder.startOffsetSeconds)
            self.finishToken &+= 1
            onTrackChange(track, currentPlaybackEpoch)
            return true
        } catch {
            return false
        }
    }

    private func reset() {
        isLive = false
        requesting = false
        renderer.stopRequestingMediaData()
        renderer.flush()
        synchronizer.setRate(0, time: .zero)
        decoder?.close()
        decoder = nil
        started = false
        wantsToPlay = false
        nextTrack = nil
        timelineEnd = 0
        setTrackStart(0)
        finishToken &+= 1
    }

    private static func endSeconds(of buffer: CMSampleBuffer) -> TimeInterval {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let duration = CMSampleBufferGetDuration(buffer)
        if duration.isNumeric, duration.seconds > 0 {
            return start + duration.seconds
        }

        var rate = 48_000.0
        var frames = Double(CMSampleBufferGetNumSamples(buffer))
        if let format = CMSampleBufferGetFormatDescription(buffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            rate = asbd.pointee.mSampleRate
            if asbd.pointee.mFormatID != kAudioFormatLinearPCM {
                frames = Double(asbd.pointee.mFramesPerPacket)
            }
        }
        guard rate > 0 else { return start }
        return start + frames / rate
    }

    private func publish(_ state: PlaybackState) {
        onState(state, currentPlaybackEpoch)
    }

    private static func describe(_ error: Error) -> String {
        if let apolo = error as? ApoloError {
            switch apolo {
            case .openFailed(let code):
                return "Could not open the stream (\(code))"
            case .readFailed(let code):
                return "Could not read the stream (\(code))"
            case .unsupportedFormat:
                return "Unsupported audio format"
            case .noAudioTrack:
                return "No audio track"
            case .playbackUnavailable:
                return "Playback unavailable"
            }
        }
        return error.localizedDescription
    }
}
