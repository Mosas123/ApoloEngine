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

    private var decoder: AudioDecoder?
    private var timeObserver: Any?
    private var requesting = false
    private var started = false
    private var wantsToPlay = false

    init(
        onState: @escaping @Sendable (PlaybackState) -> Void,
        onTime: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.onState = onState
        self.onTime = onTime
        synchronizer.addRenderer(renderer)
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, time.isNumeric else { return }
            self.onTime(time.seconds)
        }
    }

    var currentTime: TimeInterval {
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? seconds : 0
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
                let decoder = try AudioDecoder()
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
                try decoder.seek(to: seconds)
                self.renderer.flush()
                self.synchronizer.setCurrentTime(
                    CMTime(seconds: seconds, preferredTimescale: 600)
                )
                self.started = false
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

    private func startRequesting() {
        guard !requesting, decoder != nil else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.provideMoreMedia()
        }
    }

    private func provideMoreMedia() {
        while renderer.isReadyForMoreMediaData {
            guard let decoder else {
                requesting = false
                return
            }

            guard let buffer = decoder.readNextBuffer() else {
                requesting = false
                renderer.stopRequestingMediaData()
                synchronizer.setRate(0, time: synchronizer.currentTime())
                publish(.finished)
                return
            }

            if !started {
                started = true
                let start = CMSampleBufferGetPresentationTimeStamp(buffer)
                synchronizer.setRate(wantsToPlay ? 1 : 0, time: start)
            }

            renderer.enqueue(buffer)
        }
    }

    private func reset() {
        requesting = false
        renderer.stopRequestingMediaData()
        renderer.flush()
        synchronizer.setRate(0, time: .zero)
        synchronizer.setCurrentTime(.zero)
        decoder?.close()
        decoder = nil
        started = false
        wantsToPlay = false
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
