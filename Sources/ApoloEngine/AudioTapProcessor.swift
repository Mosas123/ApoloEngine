import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// `MTAudioProcessingTap` that runs the EQ, ReplayGain gain and limiter over
/// the audio AVPlayer is about to play.
///
/// The tap lives on the audio render thread. All mutable state sits behind a
/// lock, and the processor is retained by the tap itself (`passRetained` +
/// `finalize`), so an item going away can never leave `process` with a freed
/// object.
final class AudioTapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var chain: AudioProcessingChain?

    private var equalizer: EqualizerSettings
    private var limiterEnabled: Bool
    private var trackGainDB: Double

    private var sampleRate: Double = 48_000
    private var channels = 2
    private var isFloat = false
    private var isNonInterleaved = true

    /// Reused on the audio thread only, to avoid a malloc per callback.
    private var planarPointers: [UnsafeMutablePointer<Float>] = []

    init(
        equalizer: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        self.equalizer = equalizer
        self.limiterEnabled = limiterEnabled
        self.trackGainDB = trackGainDB
    }

    func makeTap() -> MTAudioProcessingTap? {
        // The tap stores this pointer without retaining it, so we hand it a +1
        // and release it in `audioTapFinalize`.
        let opaque = Unmanaged.passRetained(self).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: opaque,
            init: audioTapInit,
            finalize: audioTapFinalize,
            prepare: audioTapPrepare,
            unprepare: audioTapUnprepare,
            process: audioTapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        if status != noErr {
            Unmanaged<AudioTapProcessor>.fromOpaque(opaque).release()
            return nil
        }
        return tap
    }

    func update(
        equalizer: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        lock.lock()
        self.equalizer = equalizer
        self.limiterEnabled = limiterEnabled
        self.trackGainDB = trackGainDB
        rebuildChainLocked()
        lock.unlock()
    }

    func prepare(format: AudioStreamBasicDescription) {
        lock.lock()
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        channels = max(1, Int(format.mChannelsPerFrame))
        isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        rebuildChainLocked()
        lock.unlock()
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }

        lock.lock()
        let chain = self.chain
        let float = isFloat
        let planar = isNonInterleaved
        let channelCount = channels
        lock.unlock()

        guard float, let chain else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        if planar {
            planarPointers.removeAll(keepingCapacity: true)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                planarPointers.append(data.assumingMemoryBound(to: Float.self))
            }
            guard planarPointers.count == channelCount else { return }
            chain.process(planar: planarPointers, frames: frames)
        } else if let buffer = buffers.first, let data = buffer.mData {
            chain.process(
                interleaved: data.assumingMemoryBound(to: Float.self),
                frames: frames
            )
        }
    }

    /// Callers must hold `lock`.
    private func rebuildChainLocked() {
        chain = AudioProcessingChain(
            sampleRate: sampleRate,
            channels: channels,
            settings: equalizer,
            limiterEnabled: limiterEnabled,
            trackGainDB: trackGainDB
        )
    }
}

private let audioTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let audioTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTapProcessor>.fromOpaque(storage).release()
}

private let audioTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<AudioTapProcessor>
        .fromOpaque(storage)
        .takeUnretainedValue()
    processor.prepare(format: format.pointee)
}

private let audioTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let audioTapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, _, bufferList, framesOut, _ in
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferList,
        nil,
        nil,
        framesOut
    )
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<AudioTapProcessor>
        .fromOpaque(storage)
        .takeUnretainedValue()
    processor.process(
        bufferList: bufferList,
        frames: Int(framesOut.pointee)
    )
}
