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

    private let onState: @Sendable (PlaybackState) -> Void
    private let onTime: @Sendable (TimeInterval) -> Void
    private let onTrackChange: @Sendable (ApoloTrack) -> Void

    private var decoder: AudioDecoder?
    private var timeObserver: Any?
    private var requesting = false
    private var started = false
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
        onState: @escaping @Sendable (PlaybackState) -> Void,
        onTime: @escaping @Sendable (TimeInterval) -> Void,
        onTrackChange: @escaping @Sendable (ApoloTrack) -> Void
    ) {
        self.onState = onState
        self.onTime = onTime
        self.onTrackChange = onTrackChange
        synchronizer.addRenderer(renderer)
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, time.isNumeric else { return }
            self.onTime(max(0, time.seconds - self.currentTrackStart))
        }
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

    func load(url: URL, httpHeaders: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.reset()
            do {
                let decoder = AudioDecoder()
                decoder.processingSettings = self.equalizer
                decoder.limiterEnabled = self.limiterEnabled
                decoder.trackGainDB = self.trackGainDB
                try decoder.open(url: url, httpHeaders: httpHeaders)
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
    func load(source: OpenedSource) {
        queue.async { [weak self] in
            guard let self else { return }
            self.reset()
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
                let target = self.currentTrackStart + max(0, seconds)
                try decoder.seek(to: max(0, seconds))
                self.renderer.flush()
                self.synchronizer.setRate(
                    self.wantsToPlay ? 1 : 0,
                    time: CMTime(seconds: target, preferredTimescale: 600)
                )
                self.started = false
                self.timelineEnd = target
                self.finishToken &+= 1
                if self.wantsToPlay {
                    self.startRequesting()
                }
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

        if let buffer = decoder.readNextBuffer() {
            enqueueDecoded(buffer)
            return
        }

        if let next = nextTrack, start(next: next) {
            nextTrack = nil
            if let buffer = self.decoder?.readNextBuffer() {
                enqueueDecoded(buffer)
            }
            return
        }

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
        queue.asyncAfter(deadline: .now() + remaining + 0.3) { [weak self] in
            guard let self, self.finishToken == token else { return }
            self.synchronizer.setRate(0, time: self.synchronizer.currentTime())
            self.publish(.finished)
        }
    }

    private func enqueueDecoded(_ buffer: CMSampleBuffer) {
        if !started {
            started = true
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            synchronizer.setRate(wantsToPlay ? 1 : 0, time: start)
        }
        timelineEnd = max(timelineEnd, Self.endSeconds(of: buffer))
        renderer.enqueue(buffer)
    }

    func enqueueNext(_ track: ApoloTrack) {
        queue.async { [weak self] in
            guard let self else { return }
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
            decoder.trackGainDB = trackGainDB
            decoder.startOffsetSeconds = max(
                timelineEnd,
                synchronizer.currentTime().seconds
            )
            try decoder.open(url: track.url, httpHeaders: track.httpHeaders)
            self.decoder?.close()
            self.decoder = decoder
            self.setTrackStart(decoder.startOffsetSeconds)
            self.finishToken &+= 1
            onTrackChange(track)
            return true
        } catch {
            return false
        }
    }

    private func reset() {
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
        onState(state)
    }

    private static func describe(_ error: Error) -> String {
        if let apolo = error as? ApoloError {
            switch apolo {
            case .openFailed(let code):
                return "Could not open the stream (\(code))"
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
