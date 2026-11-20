import AVFoundation
import CoreMedia
import Darwin
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample

/// Demuxes and decodes one audio stream into interleaved Float32
/// `CMSampleBuffer`s ready for `AVSampleBufferAudioRenderer`.
///
/// All members are meant to be used from a single serial queue; the owning
/// host guarantees that.
final class AudioDecoder {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var transport: (any AudioTransport)?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    // Reused across buffers: allocating one packet/frame per read is pure churn.
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var readyBuffers: [CMSampleBuffer] = []
    private var resampler: OpaquePointer?
    private var streamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)
    private var sampleRate: Int32 = 48_000
    private var channels: Int32 = 2
    private var formatDescription: CMAudioFormatDescription?
    private var reachedEnd = false
    /// Stream-time position requested by the last seek. Frames that arrive
    /// before it (demuxers seek to the previous keyframe) are dropped.
    private var seekTargetTicks: Int64?

    private enum PassthroughMode {
        case decode
        case undecided
        case passthrough
    }

    private var passthroughMode: PassthroughMode = .decode
    private var passthroughFormat: CMAudioFormatDescription?
    private var processingChain: AudioProcessingChain?

    var processingSettings: EqualizerSettings = .flat
    var limiterEnabled = true
    var trackGainDB: Double = 0
    /// Added to every buffer PTS so a gapless switch keeps the render timeline
    /// monotonic across tracks.
    var startOffsetSeconds: Double = 0

    private var runningSamples: Int64 = 0
    private var decoderDrained = false
    private var resamplerFlushed = false

    deinit {
        close()
    }

    func open(
        url: URL,
        httpHeaders: [String: String],
        diagnostics: AudioDiagnostics? = nil
    ) throws {
        let source = try OpenedSource.open(
            url: url,
            httpHeaders: httpHeaders,
            diagnostics: diagnostics
        )
        try adopt(source)
    }

    /// Adopts a context that already ran `avformat_find_stream_info`, so the
    /// source is opened once instead of once for the probe and once here.
    func adopt(_ source: OpenedSource) throws {
        guard let context = source.takeFormatContext() else {
            throw ApoloError.openFailed(code: -1)
        }
        formatContext = context
        transport = source.takeTransport()
        do {
            try configure(alreadyProbed: true)
        } catch {
            close()
            throw error
        }
    }

    private func configure(alreadyProbed: Bool) throws {
        guard let formatContext else {
            throw ApoloError.openFailed(code: -1)
        }

        if !alreadyProbed {
            guard avformat_find_stream_info(formatContext, nil) >= 0 else {
                throw ApoloError.unsupportedFormat
            }
        }

        let found = av_find_best_stream(
            formatContext,
            AVMEDIA_TYPE_AUDIO,
            -1,
            -1,
            nil,
            0
        )
        guard found >= 0, let stream = formatContext.pointee.streams[Int(found)] else {
            throw ApoloError.noAudioTrack
        }
        streamIndex = found
        timeBase = stream.pointee.time_base

        // Skip video/subtitle/cover packets instead of demuxing and throwing
        // them away (album rips often carry cover art and chapters).
        for index in 0..<Int(formatContext.pointee.nb_streams)
        where Int32(index) != streamIndex {
            formatContext.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }

        guard let codecpar = stream.pointee.codecpar,
              let codec = avcodec_find_decoder(codecpar.pointee.codec_id)
        else {
            throw ApoloError.unsupportedFormat
        }

        guard let context = avcodec_alloc_context3(codec) else {
            throw ApoloError.unsupportedFormat
        }
        codecContext = context

        guard avcodec_parameters_to_context(context, codecpar) >= 0,
              avcodec_open2(context, codec, nil) >= 0
        else {
            throw ApoloError.unsupportedFormat
        }

        sampleRate = codecpar.pointee.sample_rate > 0
            ? codecpar.pointee.sample_rate
            : 48_000
        channels = codecpar.pointee.ch_layout.nb_channels > 0
            ? codecpar.pointee.ch_layout.nb_channels
            : 2
        if channels > 8 {
            channels = 2
        }

        // Only a 5.1 48 kHz E-AC-3 stream can carry JOC. Whether it does is
        // decidable from the dec3 box, which needs a real packet.
        if codecpar.pointee.codec_id == AV_CODEC_ID_EAC3,
           channels == 6,
           sampleRate == 48_000 {
            passthroughMode = .undecided
        }
    }

    private static let avErrorEOF: Int32 = -541_478_725

    /// Returns the next buffer, decoded or compressed, or nil at end of stream.
    /// Real demux errors throw instead of looking like EOF.
    func readNextBuffer() throws -> CMSampleBuffer? {
        if !readyBuffers.isEmpty {
            return readyBuffers.removeFirst()
        }
        switch passthroughMode {
        case .decode:
            return try readDecodedBuffer()
        case .undecided, .passthrough:
            return try readCompressedBuffer()
        }
    }

    private func readDecodedBuffer() throws -> CMSampleBuffer? {
        guard let formatContext, let codecContext else { return nil }
        guard let packet = ensurePacket() else { return nil }

        while true {
            if !readyBuffers.isEmpty {
                return readyBuffers.removeFirst()
            }
            if reachedEnd {
                if !decoderDrained {
                    decoderDrained = true
                    _ = avcodec_send_packet(codecContext, nil)
                    drain(codecContext)
                    if !readyBuffers.isEmpty { continue }
                }
                if !resamplerFlushed {
                    flushResampler()
                    if !readyBuffers.isEmpty { continue }
                }
                return nil
            }

            let read = av_read_frame(formatContext, packet)
            if read < 0 {
                if read == Self.avErrorEOF {
                    reachedEnd = true
                    continue
                }
                throw ApoloError.readFailed(code: read)
            }

            if packet.pointee.stream_index != streamIndex {
                av_packet_unref(packet)
                continue
            }

            let accepted = send(packet, to: codecContext)
            av_packet_unref(packet)
            if !accepted {
                continue
            }
        }
    }

    /// Sends one packet, tolerating a full decoder: drain what it already has,
    /// then retry the same packet once instead of dropping it.
    private func send(
        _ packet: UnsafePointer<AVPacket>,
        to context: UnsafeMutablePointer<AVCodecContext>
    ) -> Bool {
        let first = avcodec_send_packet(context, packet)
        if first >= 0 {
            drain(context)
            return true
        }

        drain(context)
        let second = avcodec_send_packet(context, packet)
        if second < 0 {
            return false
        }
        drain(context)
        return true
    }

    private func readCompressedBuffer() throws -> CMSampleBuffer? {
        guard let formatContext, let codecContext else { return nil }

        guard let packet = ensurePacket() else { return nil }

        while true {
            if reachedEnd {
                return nil
            }

            let read = av_read_frame(formatContext, packet)
            if read < 0 {
                if read == Self.avErrorEOF {
                    reachedEnd = true
                    return nil
                }
                throw ApoloError.readFailed(code: read)
            }

            if packet.pointee.stream_index != streamIndex {
                av_packet_unref(packet)
                continue
            }

            if let target = seekTargetTicks, packet.pointee.pts != Int64.min {
                if packet.pointee.pts < target {
                    av_packet_unref(packet)
                    continue
                }
                seekTargetTicks = nil
            }

            let seconds = startSeconds(for: packet) + startOffsetSeconds

            if passthroughMode == .undecided {
                let stream = formatContext.pointee.streams[Int(streamIndex)]
                if let codecpar = stream?.pointee.codecpar,
                   let entry = EAC3Passthrough.formatDescription(
                       codecpar: codecpar,
                       packet: packet
                   ),
                   entry.carriesJOC {
                    passthroughFormat = entry.description
                    passthroughMode = .passthrough
                } else {
                    passthroughMode = .decode
                    let accepted = send(packet, to: codecContext)
                    av_packet_unref(packet)
                    if accepted, !readyBuffers.isEmpty {
                        return readyBuffers.removeFirst()
                    }
                    return try readDecodedBuffer()
                }
            }

            guard let format = passthroughFormat else {
                av_packet_unref(packet)
                return nil
            }
            let buffer = EAC3Passthrough.sampleBuffer(
                packet: packet,
                seconds: seconds,
                formatDescription: format
            )
            av_packet_unref(packet)
            if let buffer {
                return buffer
            }
        }
    }

    private func startSeconds(for packet: UnsafePointer<AVPacket>) -> Double {
        let ticks = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : packet.pointee.dts
        guard ticks != Int64.min, timeBase.den > 0 else { return 0 }
        return Double(ticks) * Double(timeBase.num) / Double(timeBase.den)
    }

    func updateProcessing(
        settings: EqualizerSettings,
        limiterEnabled: Bool,
        trackGainDB: Double
    ) {
        processingSettings = settings
        self.limiterEnabled = limiterEnabled
        self.trackGainDB = trackGainDB
        processingChain?.update(
            settings: settings,
            limiterEnabled: limiterEnabled,
            trackGainDB: trackGainDB
        )
    }

    func seek(to seconds: TimeInterval) throws {
        guard let formatContext, let codecContext else { return }
        guard timeBase.num > 0, timeBase.den > 0 else {
            throw ApoloError.unsupportedFormat
        }

        let rate = Double(timeBase.num) / Double(timeBase.den)
        let target = Int64(seconds / rate)
        let result = avformat_seek_file(
            formatContext,
            streamIndex,
            Int64.min,
            target,
            Int64.max,
            AVSEEK_FLAG_BACKWARD
        )
        guard result >= 0 else { throw ApoloError.unsupportedFormat }

        // Drop packets the demuxer queued before the seek point.
        avformat_flush(formatContext)
        avcodec_flush_buffers(codecContext)
        reachedEnd = false
        decoderDrained = false
        resamplerFlushed = false
        runningSamples = 0
        seekTargetTicks = target
        readyBuffers.removeAll()
    }

    func close() {
        seekTargetTicks = nil
        if packet != nil {
            av_packet_free(&packet)
        }
        if frame != nil {
            av_frame_free(&frame)
        }
        readyBuffers.removeAll()
        if resampler != nil {
            swr_free(&resampler)
        }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        transport?.close()
        transport = nil
        formatDescription = nil
        passthroughFormat = nil
        processingChain = nil
        passthroughMode = .decode
        decoderDrained = false
        resamplerFlushed = false
    }

    private func drain(_ context: UnsafeMutablePointer<AVCodecContext>) {
        guard let frame = ensureFrame() else { return }

        while avcodec_receive_frame(context, frame) >= 0 {
            if resampler == nil, !makeResampler(from: frame) {
                continue
            }
            append(frame)
        }
    }

    private func makeResampler(from frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        var inputLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inputLayout, channels)
        }

        var outputLayout = AVChannelLayout()
        Self.makeResamplerOutputLayout(channels: channels, into: &outputLayout)

        defer {
            av_channel_layout_uninit(&inputLayout)
            av_channel_layout_uninit(&outputLayout)
        }

        let inputFormat = AVSampleFormat(rawValue: frame.pointee.format)
        let inputRate = frame.pointee.sample_rate > 0
            ? frame.pointee.sample_rate
            : sampleRate

        let result = swr_alloc_set_opts2(
            &resampler,
            &outputLayout,
            AV_SAMPLE_FMT_FLT,
            sampleRate,
            &inputLayout,
            inputFormat,
            inputRate,
            0,
            nil
        )
        guard result >= 0, let resampler else { return false }

        guard swr_init(resampler) >= 0 else {
            swr_free(&self.resampler)
            return false
        }

        do {
            try createFormatDescription()
        } catch {
            swr_free(&self.resampler)
            return false
        }

        processingChain = AudioProcessingChain(
            sampleRate: Double(sampleRate),
            channels: Int(channels),
            settings: processingSettings,
            limiterEnabled: limiterEnabled,
            trackGainDB: trackGainDB
        )
        return true
    }

    private func ensurePacket() -> UnsafeMutablePointer<AVPacket>? {
        if let packet {
            av_packet_unref(packet)
            return packet
        }
        packet = av_packet_alloc()
        return packet
    }

    private func ensureFrame() -> UnsafeMutablePointer<AVFrame>? {
        if let frame { return frame }
        frame = av_frame_alloc()
        return frame
    }

    private func append(_ frame: UnsafeMutablePointer<AVFrame>) {
        if let target = seekTargetTicks, frame.pointee.pts != Int64.min {
            if frame.pointee.pts < target { return }
            seekTargetTicks = nil
        }
        guard let resampler else { return }

        let samples = frame.pointee.nb_samples
        guard samples > 0 else { return }

        let outputSamples = Int(swr_get_out_samples(resampler, samples))
        guard outputSamples > 0 else { return }

        let bytesPerFrame = Int(channels) * 4
        guard let memory = malloc(outputSamples * bytesPerFrame) else {
            return
        }
        var output: UnsafeMutablePointer<UInt8>? = memory
            .assumingMemoryBound(to: UInt8.self)
        let converted: Int32 = withUnsafeMutablePointer(to: &output) {
            outputPointer in
            let source = UnsafePointer<UnsafePointer<UInt8>?>(
                OpaquePointer(frame.pointee.extended_data)
            )
            return swr_convert(
                resampler,
                outputPointer,
                Int32(outputSamples),
                source,
                samples
            )
        }
        guard converted > 0 else {
            free(memory)
            return
        }

        processIfNeeded(memory, frames: Int(converted))

        let ticks = frame.pointee.pts == Int64.min
            ? runningSamples
            : av_rescale_q(
                frame.pointee.pts,
                timeBase,
                AVRational(num: 1, den: sampleRate)
            )
        runningSamples += Int64(converted)

        if let buffer = makeSampleBuffer(
            memory: memory,
            byteCount: Int(converted) * bytesPerFrame,
            samples: Int(converted),
            startTicks: ticks
        ) {
            readyBuffers.append(buffer)
        }
    }

    /// Pushes whatever resampler tail is still buffered when the decoder hits
    /// EOF. Without this the last few milliseconds of every track are lost.
    private func flushResampler() {
        guard let resampler, !resamplerFlushed else { return }
        resamplerFlushed = true

        let outputSamples = Int(swr_get_out_samples(resampler, 0))
        guard outputSamples > 0 else { return }

        let bytesPerFrame = Int(channels) * 4
        guard let memory = malloc(outputSamples * bytesPerFrame) else {
            return
        }
        var output: UnsafeMutablePointer<UInt8>? = memory
            .assumingMemoryBound(to: UInt8.self)
        let converted: Int32 = withUnsafeMutablePointer(to: &output) {
            outputPointer in
            swr_convert(
                resampler,
                outputPointer,
                Int32(outputSamples),
                nil,
                0
            )
        }
        guard converted > 0 else {
            free(memory)
            return
        }

        processIfNeeded(memory, frames: Int(converted))

        let ticks = runningSamples
        runningSamples += Int64(converted)

        if let buffer = makeSampleBuffer(
            memory: memory,
            byteCount: Int(converted) * bytesPerFrame,
            samples: Int(converted),
            startTicks: ticks
        ) {
            readyBuffers.append(buffer)
        }
    }

    private func processIfNeeded(
        _ pointer: UnsafeMutableRawPointer,
        frames: Int
    ) {
        guard let chain = processingChain else { return }
        chain.process(
            interleaved: pointer.assumingMemoryBound(to: Float.self),
            frames: frames
        )
    }

    /// Hands the freshly converted PCM to CoreMedia without an intermediate
    /// copy. The block buffer takes ownership and frees it with `free`.
    /// On every failure path the memory is already released here.
    private func makeSampleBuffer(
        memory: UnsafeMutableRawPointer,
        byteCount: Int,
        samples: Int,
        startTicks: Int64
    ) -> CMSampleBuffer? {
        guard let formatDescription, byteCount > 0, samples > 0 else {
            free(memory)
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memory,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            free(memory)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: startTicks, timescale: sampleRate)
                + CMTime(seconds: startOffsetSeconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(samples),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            // The block buffer owns and will free the memory.
            return nil
        }
        return sampleBuffer
    }

    /// The layout the resampler writes. Everything is FFmpeg's default except
    /// 7 channels: 6.1's default order (FL FR FC LFE BC SL SR) is the one count
    /// CoreAudio has no tag for, so point the resampler at 6.1(back)
    /// (FL FR FC LFE BL BR BC), which `MPEG_6_1_A` does describe.
    static func makeResamplerOutputLayout(
        channels: Int32,
        into layout: inout AVChannelLayout
    ) {
        if channels == 7,
           av_channel_layout_from_string(&layout, "6.1(back)") >= 0 {
            return
        }
        av_channel_layout_default(&layout, channels)
    }

    private func createFormatDescription() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var layout = AudioChannelLayout(
            mChannelLayoutTag: Self.layoutTag(for: channels),
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )

        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw ApoloError.unsupportedFormat
        }
        formatDescription = description
    }

    private static func layoutTag(for channels: Int32) -> AudioChannelLayoutTag {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        case 3: return kAudioChannelLayoutTag_WAVE_2_1
        case 4: return kAudioChannelLayoutTag_MPEG_4_0_A
        case 5: return kAudioChannelLayoutTag_MPEG_5_0_A
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
        case 7: return kAudioChannelLayoutTag_MPEG_6_1_A
        case 8: return kAudioChannelLayoutTag_MPEG_7_1_C
        default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }
    }
}
