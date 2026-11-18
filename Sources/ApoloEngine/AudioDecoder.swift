import AVFoundation
import CoreMedia
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
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var streamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)
    private var sampleRate: Int32 = 48_000
    private var channels: Int32 = 2
    private var formatDescription: CMAudioFormatDescription?
    private var reachedEnd = false

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

    private var pendingBytes: [UInt8] = []
    private var pendingSamples = 0
    private var pendingStartPTS: CMTime = .invalid
    private var runningSamples: Int64 = 0

    deinit {
        close()
    }

    func open(url: URL, httpHeaders: [String: String]) throws {
        var options: OpaquePointer?
        if !httpHeaders.isEmpty {
            let joined = httpHeaders
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n")
            joined.withCString { _ = av_dict_set(&options, "headers", $0, 0) }
        }

        let openCode = url.absoluteString.withCString {
            avformat_open_input(&formatContext, $0, nil, &options)
        }
        av_dict_free(&options)
        guard openCode == 0, let formatContext else {
            throw ApoloError.openFailed(code: openCode)
        }

        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            throw ApoloError.unsupportedFormat
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

    /// Returns the next buffer, decoded or compressed, or nil at end of stream.
    func readNextBuffer() -> CMSampleBuffer? {
        switch passthroughMode {
        case .decode:
            return readDecodedBuffer()
        case .undecided, .passthrough:
            return readCompressedBuffer()
        }
    }

    private func readDecodedBuffer() -> CMSampleBuffer? {
        guard let formatContext, let codecContext else { return nil }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return nil }

        while true {
            if reachedEnd {
                return nil
            }

            let read = av_read_frame(formatContext, packet)
            if read < 0 {
                reachedEnd = true
                avcodec_send_packet(codecContext, nil)
                return drain(codecContext)
            }

            if packet.pointee.stream_index != streamIndex {
                av_packet_unref(packet)
                continue
            }

            let sent = avcodec_send_packet(codecContext, packet)
            av_packet_unref(packet)
            if sent < 0 {
                continue
            }

            if let buffer = drain(codecContext) {
                return buffer
            }
        }
    }

    private func readCompressedBuffer() -> CMSampleBuffer? {
        guard let formatContext, let codecContext else { return nil }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return nil }

        while true {
            if reachedEnd {
                return nil
            }

            let read = av_read_frame(formatContext, packet)
            if read < 0 {
                reachedEnd = true
                return nil
            }

            if packet.pointee.stream_index != streamIndex {
                av_packet_unref(packet)
                continue
            }

            let seconds = startSeconds(for: packet)

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
                    let sent = avcodec_send_packet(codecContext, packet)
                    av_packet_unref(packet)
                    if sent < 0 {
                        continue
                    }
                    return drain(codecContext)
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
        guard resampler != nil else { return }
        processingChain = AudioProcessingChain(
            sampleRate: Double(sampleRate),
            channels: Int(channels),
            settings: settings,
            limiterEnabled: limiterEnabled,
            trackGainDB: trackGainDB
        )
    }

    func seek(to seconds: TimeInterval) throws {
        guard let formatContext, let codecContext else { return }

        let rate = Double(timeBase.num) / Double(timeBase.den)
        let target = Int64(seconds / rate)
        let result = avformat_seek_file(
            formatContext,
            streamIndex,
            Int64.min,
            target,
            Int64.max,
            0
        )
        guard result >= 0 else { throw ApoloError.unsupportedFormat }

        avcodec_flush_buffers(codecContext)
        reachedEnd = false
        runningSamples = 0
        resetPending()
    }

    func close() {
        if resampler != nil {
            swr_free(&resampler)
        }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatDescription = nil
        passthroughFormat = nil
        processingChain = nil
        passthroughMode = .decode
        resetPending()
    }

    private func drain(_ context: UnsafeMutablePointer<AVCodecContext>) -> CMSampleBuffer? {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frame else { return nil }

        resetPending()

        while avcodec_receive_frame(context, frame) >= 0 {
            if resampler == nil, !makeResampler(from: frame) {
                continue
            }
            append(frame)
        }

        return makeSampleBuffer()
    }

    private func makeResampler(from frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        var inputLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inputLayout, channels)
        }

        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, channels)

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

    private func append(_ frame: UnsafeMutablePointer<AVFrame>) {
        guard let resampler else { return }

        let samples = frame.pointee.nb_samples
        guard samples > 0 else { return }

        let outputSamples = Int(swr_get_out_samples(resampler, samples))
        guard outputSamples > 0 else { return }

        let bytesPerFrame = Int(channels) * 4
        var scratch = [UInt8](repeating: 0, count: outputSamples * bytesPerFrame)
        let converted: Int32 = scratch.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var output: UnsafeMutablePointer<UInt8>? = base.assumingMemoryBound(to: UInt8.self)
            return withUnsafeMutablePointer(to: &output) { outputPointer in
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
        }
        guard converted > 0 else { return }

        if let chain = processingChain {
            scratch.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                chain.process(
                    interleaved: base.assumingMemoryBound(to: Float.self),
                    frames: Int(converted)
                )
            }
        }

        if pendingSamples == 0 {
            let ticks = frame.pointee.pts == Int64.min
                ? runningSamples
                : av_rescale_q(
                    frame.pointee.pts,
                    timeBase,
                    AVRational(num: 1, den: sampleRate)
                )
            pendingStartPTS = CMTime(value: ticks, timescale: sampleRate)
        }

        pendingBytes.append(contentsOf: scratch.prefix(Int(converted) * bytesPerFrame))
        pendingSamples += Int(converted)
        runningSamples += Int64(converted)
    }

    private func makeSampleBuffer() -> CMSampleBuffer? {
        guard pendingSamples > 0,
              let formatDescription,
              !pendingBytes.isEmpty
        else { return nil }

        let totalBytes = pendingBytes.count
        let totalSamples = pendingSamples
        let startPTS = pendingStartPTS

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            resetPending()
            return nil
        }

        status = pendingBytes.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard status == kCMBlockBufferNoErr else {
            resetPending()
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: startPTS,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(totalSamples),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        resetPending()
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private func resetPending() {
        pendingBytes.removeAll(keepingCapacity: true)
        pendingSamples = 0
        pendingStartPTS = .invalid
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
