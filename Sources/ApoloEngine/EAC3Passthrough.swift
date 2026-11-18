import AudioToolbox
import CoreMedia
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// E-AC-3 JOC (Dolby Atmos) passthrough.
///
/// The packets go to `AVSampleBufferAudioRenderer` compressed, so the system
/// Atmos decoder receives the whole stream instead of a decoded 5.1 core.
///
/// The renderer reads the JOC signal from the `dec3` sample-entry box carried
/// as the format description's magic cookie. FFmpeg's demuxers do not expose
/// that box, so it is produced the same way a muxer does: one real packet
/// through FFmpeg's mp4 muxer, then the box is read back out.
enum EAC3Passthrough {
    static let framesPerPacket: UInt32 = 1536
    static let sampleRate: Double = 48_000

    /// Builds the compressed format description and reports whether it
    /// carries JOC (Atmos).
    static func formatDescription(
        codecpar: UnsafePointer<AVCodecParameters>,
        packet: UnsafePointer<AVPacket>
    ) -> (description: CMAudioFormatDescription, carriesJOC: Bool)? {
        guard let box = dec3Box(codecpar: codecpar, packet: packet) else {
            return nil
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatEnhancedAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 6,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_C

        var description: CMAudioFormatDescription?
        let status = box.withUnsafeBytes { cookie -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size,
                layout: &layout,
                magicCookieSize: cookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { return nil }
        return (description, carriesJOC(dec3: box))
    }

    /// One compressed packet as a one-sample `CMSampleBuffer`. The bytes are
    /// copied because the demux loop frees the packet immediately after.
    static func sampleBuffer(
        packet: UnsafePointer<AVPacket>,
        seconds: Double,
        formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else {
            return nil
        }
        let count = Int(packet.pointee.size)
        let bytes = UnsafeRawBufferPointer(start: data, count: count)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block,
        CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: count
        ) == kCMBlockBufferNoErr else {
            return nil
        }

        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(count)
        )
        var sample: CMSampleBuffer?
        let status = withUnsafeMutablePointer(to: &packetDescription) { pointer in
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDescription,
                sampleCount: 1,
                presentationTimeStamp: CMTime(
                    seconds: seconds,
                    preferredTimescale: 90_000
                ),
                packetDescriptions: pointer,
                sampleBufferOut: &sample
            )
        }
        return status == noErr ? sample : nil
    }

    // MARK: - dec3 box

    /// Reads the JOC flag out of a `dec3` box (header included or not).
    static func carriesJOC(dec3 record: Data) -> Bool {
        var bytes = [UInt8](record)
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("dec3".utf8) {
            bytes.removeFirst(8)
        }

        var reader = BitReader(bytes: bytes)
        guard reader.skip(13), let independent = reader.read(3) else {
            return false
        }
        for _ in 0...independent {
            guard reader.skip(2 + 5 + 1 + 1 + 3 + 3 + 1 + 3),
                  let dependent = reader.read(4)
            else { return false }
            guard reader.skip(dependent > 0 ? 9 : 1) else { return false }
        }
        guard reader.skip(7), let flag = reader.read(1) else { return false }
        return flag == 1
    }

    static func dec3Box(
        codecpar: UnsafePointer<AVCodecParameters>,
        packet: UnsafePointer<AVPacket>
    ) -> Data? {
        var contextOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&contextOut, nil, "mp4", "dec3.mp4") == 0,
              let context = contextOut
        else { return nil }
        defer { avformat_free_context(context) }

        var ioOut: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&ioOut) >= 0, let io = ioOut else { return nil }
        context.pointee.pb = io

        let written = muxOnePacket(
            context: context,
            codecpar: codecpar,
            packet: packet
        )
        var bytes: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(io, &bytes)
        defer { if let bytes { av_free(bytes) } }
        guard written, size > 8, let bytes else { return nil }

        return findBox(
            "dec3",
            in: UnsafeBufferPointer(start: bytes, count: Int(size))
        )
    }

    private static func muxOnePacket(
        context: UnsafeMutablePointer<AVFormatContext>,
        codecpar: UnsafePointer<AVCodecParameters>,
        packet: UnsafePointer<AVPacket>
    ) -> Bool {
        guard let stream = avformat_new_stream(context, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, codecpar) >= 0
        else { return false }

        stream.pointee.codecpar.pointee.codec_tag = 0
        stream.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))

        guard avformat_write_header(context, nil) >= 0 else { return false }

        var cloned: UnsafeMutablePointer<AVPacket>? = av_packet_clone(packet)
        defer { av_packet_free(&cloned) }
        guard let copy = cloned else { return false }
        copy.pointee.stream_index = 0
        copy.pointee.pts = 0
        copy.pointee.dts = 0
        copy.pointee.duration = Int64(framesPerPacket)

        guard av_write_frame(context, copy) >= 0 else { return false }
        return av_write_trailer(context) >= 0
    }

    private static func findBox(
        _ type: String,
        in bytes: UnsafeBufferPointer<UInt8>
    ) -> Data? {
        let code = Array(type.utf8)
        guard code.count == 4, let moov = topLevelPayload("moov", in: bytes) else {
            return nil
        }
        var index = moov.lowerBound + 4
        while index + 4 <= moov.upperBound {
            if Array(bytes[index..<(index + 4)]) == code {
                let start = index - 4
                let size = Int(boxSize(bytes, at: start))
                if size >= 8, start >= moov.lowerBound, start + size <= moov.upperBound {
                    return Data(bytes[start..<(start + size)])
                }
            }
            index += 1
        }
        return nil
    }

    private static func boxSize(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    private static func topLevelPayload(
        _ type: String,
        in bytes: UnsafeBufferPointer<UInt8>
    ) -> Range<Int>? {
        let code = Array(type.utf8)
        var index = 0
        while index + 8 <= bytes.count {
            let size32 = boxSize(bytes, at: index)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard index + 16 <= bytes.count else { return nil }
                size = 0
                for offset in 8..<16 {
                    size = (size << 8) | Int(bytes[index + offset])
                }
                header = 16
            } else if size32 == 0 {
                size = bytes.count - index
            }
            guard size >= header, index + size <= bytes.count else { return nil }
            if Array(bytes[(index + 4)..<(index + 8)]) == code {
                return (index + header)..<(index + size)
            }
            index += size
        }
        return nil
    }
}

private struct BitReader {
    let bytes: [UInt8]
    private var bitIndex = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(_ count: Int) -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<count {
            let byteIndex = bitIndex / 8
            guard byteIndex < bytes.count else { return nil }
            let bit = (Int(bytes[byteIndex]) >> (7 - bitIndex % 8)) & 1
            value = (value << 1) | UInt32(bit)
            bitIndex += 1
        }
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        bitIndex += count
        return bitIndex <= bytes.count * 8
    }
}
