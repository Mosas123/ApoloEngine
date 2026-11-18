import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// `MTAudioProcessingTap` that runs the EQ, ReplayGain gain and limiter over
/// the audio AVPlayer is about to play.
///
/// The tap lives on the audio render thread. The processing chain is swapped
/// under a lock, so a settings change from the main actor never tears a chain
/// out from under an in-flight buffer.
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
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
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
        return status == noErr ? tap : nil
    }

    func update(
        equalizer: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        self.equalizer = equalizer
        self.limiterEnabled = limiterEnabled
        self.trackGainDB = trackGainDB
        rebuildChain()
    }

    func prepare(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        channels = max(1, Int(format.mChannelsPerFrame))
        isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        rebuildChain()
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, isFloat else { return }

        lock.lock()
        let chain = self.chain
        lock.unlock()
        guard let chain else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        if isNonInterleaved {
            var pointers: [UnsafeMutablePointer<Float>] = []
            pointers.reserveCapacity(buffers.count)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                pointers.append(data.assumingMemoryBound(to: Float.self))
            }
            guard pointers.count == chainChannelCount else { return }
            chain.process(planar: pointers, frames: frames)
        } else if let buffer = buffers.first, let data = buffer.mData {
            chain.process(
                interleaved: data.assumingMemoryBound(to: Float.self),
                frames: frames
            )
        }
    }

    private var chainChannelCount: Int {
        channels
    }

    private func rebuildChain() {
        let newChain = AudioProcessingChain(
            sampleRate: sampleRate,
            channels: channels,
            settings: equalizer,
            limiterEnabled: limiterEnabled,
            trackGainDB: trackGainDB
        )
        lock.lock()
        chain = newChain
        lock.unlock()
    }
}

private let audioTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let audioTapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in }

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
