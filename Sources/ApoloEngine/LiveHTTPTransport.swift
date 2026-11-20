import Foundation
import AetherLibavformat
import AetherLibavutil

/// Shared ownership contract for finite-file and continuous FFmpeg AVIO.
protocol AudioTransport: AnyObject, Sendable {
    var context: UnsafeMutablePointer<AVIOContext>? { get }
    func close()
}

extension HTTPTransport: AudioTransport {}

/// FFmpeg receives only audio bytes, with ICY blocks already stripped.
/// No seek callback and seekable=0: an infinite station is not a file.
final class LiveHTTPTransport: AudioTransport, @unchecked Sendable {
    private var avio: UnsafeMutablePointer<AVIOContext>?
    private var stream: LiveHTTPStream?

    init?(stream: LiveHTTPStream) {
        let bufferSize = 32 * 1_024
        guard let buffer = av_malloc(bufferSize) else { return nil }
        let opaque = Unmanaged.passRetained(stream).toOpaque()
        guard let context = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self),
            Int32(bufferSize),
            0,
            opaque,
            liveReadPacket,
            nil,
            nil
        ) else {
            av_free(buffer)
            Unmanaged<LiveHTTPStream>.fromOpaque(opaque).release()
            return nil
        }
        context.pointee.seekable = 0
        avio = context
        self.stream = stream
        stream.start()
    }

    var context: UnsafeMutablePointer<AVIOContext>? { avio }

    func close() {
        guard let avio else { return }
        stream?.close()
        let buffer = avio.pointee.buffer
        let opaque = avio.pointee.opaque
        var pointer: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&pointer)
        self.avio = nil
        if let buffer { av_free(buffer) }
        if let opaque {
            Unmanaged<LiveHTTPStream>.fromOpaque(opaque).release()
        }
        stream = nil
    }

    deinit { close() }
}

private let liveReadPacket: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<UInt8>?,
    Int32
) -> Int32 = { opaque, buffer, size in
    guard let opaque, let buffer, size > 0 else { return -5 }
    let stream = Unmanaged<LiveHTTPStream>
        .fromOpaque(opaque)
        .takeUnretainedValue()
    let read = stream.read(into: buffer, count: Int(size))
    if read > 0 { return Int32(read) }
    // Stream closure is exceptional for live radio. It must not cause a
    // synthetic on-demand EOF or advance Thrum's song queue.
    return -5
}
