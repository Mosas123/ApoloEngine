import AetherLibavutil
import AetherLibswresample
import AudioToolbox
import CoreMedia
import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

final class G0LayoutBridgeTests: XCTestCase {
    private enum LabError: Error { case layout, conversion, fixture, coreMedia }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }

    private func names(_ layout: inout AVChannelLayout) -> [String] {
        (0..<Int(layout.nb_channels)).map { i in
            let id = av_channel_layout_channel_from_index(&layout, UInt32(i))
            var buf = [CChar](repeating: 0, count: 64)
            let rc = buf.withUnsafeMutableBufferPointer {
                av_channel_name($0.baseAddress, $0.count, id)
            }
            return rc >= 0 ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "unknown"
        }
    }

    private func fixture(mask: UInt32, channels: Int, frames: Int, rate:Int, pcm: [Int16]) -> Data {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func put<T: FixedWidthInteger>(_ x: T) {
            var value = x.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        let size = frames * channels * 2
        ascii("RIFF"); put(UInt32(60 + size)); ascii("WAVE")
        ascii("fmt "); put(UInt32(40)); put(UInt16(0xfffe))
        put(UInt16(channels)); put(UInt32(rate)); put(UInt32(rate * channels * 2))
        put(UInt16(channels * 2)); put(UInt16(16)); put(UInt16(22)); put(UInt16(16)); put(mask)
        // KSDATAFORMAT_SUBTYPE_PCM GUID in RIFF byte order.
        data.append(contentsOf: [1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113])
        ascii("data"); put(UInt32(size))
        for x in pcm { put(x) }
        return data
    }

    private func reference(_ pcm: [Int16], channels: Int,
                           input: inout AVChannelLayout, output: inout AVChannelLayout) throws -> [Float] {
        var context: OpaquePointer?
        defer { swr_free(&context) }
        guard swr_alloc_set_opts2(&context, &output, AV_SAMPLE_FMT_FLT, 48000,
                                  &input, AV_SAMPLE_FMT_S16, 48000, 0, nil) >= 0,
              let swr = context, swr_init(swr) >= 0
        else { throw LabError.conversion }
        let frames = pcm.count / channels
        let upper = swr_get_out_samples(swr, Int32(frames))
        guard upper >= Int32(frames), upper <= 8192 else { throw LabError.conversion }
        var out = [Float](repeating: 0, count: Int(upper) * channels)
        let got = pcm.withUnsafeBytes { raw in
            var src: UnsafePointer<UInt8>? = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return out.withUnsafeMutableBytes { dst in
                var ptr: UnsafeMutablePointer<UInt8>? = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return withUnsafePointer(to: &src) { source in
                    withUnsafeMutablePointer(to: &ptr) { dest in
                        swr_convert(swr, dest, upper, source, Int32(frames))
                    }
                }
            }
        }
        guard got == Int32(frames), swr_get_delay(swr, 48000) == 0 else { throw LabError.conversion }
        return Array(out.prefix(Int(got) * channels))
    }

    // Expand the actual tag through the Apple SDK, not a guessed label order.
    private func appleLabels(_ tag: AudioChannelLayoutTag, channels: Int) throws -> [UInt32] {
        var value = tag
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                         UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &value, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size), size <= 4096
        else { throw LabError.layout }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                     UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &value, &size, storage) == noErr
        else { throw LabError.layout }
        let expanded = storage.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        guard expanded.mNumberChannelDescriptions == UInt32(channels),
              let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions),
              offset + channels * MemoryLayout<AudioChannelDescription>.stride <= Int(size)
        else { throw LabError.layout }
        let entries = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<channels).map { entries[$0].mChannelLabel }
    }

    private func engine(_ url: URL, channels: Int, frames: Int, rate:Int) throws -> (pcm: [Float], tag: UInt32, timeline: Bool, asbd: Bool, labels:[UInt32]) {
        let decoder = AudioDecoder()
        decoder.limiterEnabled = false
        try decoder.open(url: url, httpHeaders: [:])
        defer { decoder.close() }
        var pcm: [Float] = [], tag: UInt32?, labels:[UInt32]=[]
        var done = false, timeline = true, asbdValid = true
        for _ in 0..<128 {
            guard let b = try decoder.readNextBuffer() else { done = true; break }
            let n = CMSampleBufferGetNumSamples(b)
            guard n > 0, let block = CMSampleBufferGetDataBuffer(b),
                  let desc = CMSampleBufferGetFormatDescription(b),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            else { throw LabError.coreMedia }
            let shape = asbd.pointee
            asbdValid = asbdValid && shape.mSampleRate == Double(rate)
                && shape.mChannelsPerFrame == UInt32(channels) && shape.mBitsPerChannel == 32
                && shape.mFormatID == kAudioFormatLinearPCM && shape.mBytesPerFrame == UInt32(channels * 4)
                && (shape.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && (shape.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            var size = 0
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &size),
                  size >= 12 else { throw LabError.layout }
            let t = layout.pointee.mChannelLayoutTag
            guard tag == nil || tag == t else { throw LabError.layout }
            tag = t
            let observed:[UInt32]
            if t == kAudioChannelLayoutTag_UseChannelDescriptions {
                guard layout.pointee.mNumberChannelDescriptions == UInt32(channels),
                      let offset=MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions),
                      size>=offset+channels*MemoryLayout<AudioChannelDescription>.stride else{throw LabError.layout}
                let entries=UnsafeRawPointer(layout).advanced(by:offset).assumingMemoryBound(to:AudioChannelDescription.self)
                observed=(0..<channels).map{entries[$0].mChannelLabel}
            }else{observed=try appleLabels(t,channels:channels)}
            if labels.isEmpty{labels=observed}else{XCTAssertEqual(labels,observed)}
            let stamp = CMSampleBufferGetPresentationTimeStamp(b).seconds
            timeline = timeline && stamp.isFinite && abs(stamp * Double(rate) - Double(pcm.count / channels)) < 0.001
            let count = n * channels
            guard count <= frames * channels, pcm.count + count <= frames * channels,
                  CMBlockBufferGetDataLength(block) == count * 4 else { throw LabError.fixture }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
            }
            guard status == noErr, chunk.allSatisfy({ $0.isFinite }) else { throw LabError.coreMedia }
            pcm.append(contentsOf: chunk)
        }
        guard done, try decoder.readNextBuffer() == nil, let tag else { throw LabError.coreMedia }
        return (pcm, tag, timeline, asbdValid,labels)
    }

    private func explicitLabels(_ channels: [String]) throws -> [UInt32] {
        let mapping: [String: UInt32] = [
            "FL": kAudioChannelLabel_Left, "FR": kAudioChannelLabel_Right,
            "FC": kAudioChannelLabel_Center, "LFE": kAudioChannelLabel_LFEScreen,
            "BL": kAudioChannelLabel_RearSurroundLeft, "BR": kAudioChannelLabel_RearSurroundRight,
            "SL": kAudioChannelLabel_LeftSurround, "SR": kAudioChannelLabel_RightSurround,
            "BC": kAudioChannelLabel_CenterSurround,
            "FLC": kAudioChannelLabel_LeftCenter, "FRC": kAudioChannelLabel_RightCenter
        ]
        if channels == ["FC"] { return [kAudioChannelLabel_Mono] }
        return try channels.map {
            guard let label = mapping[$0] else { throw LabError.layout }
            return label
        }
    }

    func testMatrix()throws {
        let overlay=ProcessInfo.processInfo.environment["APOLO_G0_LAYOUT_OVERLAY"]=="1"
        let cases:[(String,UInt32,Int)]=[
            ("mono",0x4,1),("stereo",0x3,2),("2.1",0xb,3),("3.0",0x7,3),
            ("4.0",0x107,4),("quad",0x33,4),("5.0-back",0x37,5),("5.0-side",0x607,5),
            ("5.1-back",0x3f,6),("5.1-side",0x60f,6),("6.1",0x70f,7),("6.1-back",0x13f,7),
            ("7.1",0x63f,8),("7.1-wide-back",0xff,8)]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("g0-4b42-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        print("G0_4B42_PROCESS pid=\(getpid()) overlay=\(overlay)")
        var total=0,identical=0,labelsExact=0
        for rate in [48000,96000] {
            for (name,mask,ch) in cases {
                var input=AVChannelLayout(),selected=AVChannelLayout()
                defer{av_channel_layout_uninit(&input);av_channel_layout_uninit(&selected)}
                guard av_channel_layout_from_mask(&input,UInt64(mask))>=0,input.nb_channels==Int32(ch) else{throw LabError.layout}
                AudioDecoder.makeResamplerOutputLayout(channels:Int32(ch),into:&selected)
                let inNames=names(&input),outNames=names(&selected),expected=try explicitLabels(inNames)
                let slot=4097,frames=slot*ch
                var pcm=[Int16](repeating:0,count:frames*ch)
                for c in 0..<ch {
                    for i in 0..<slot {pcm[(c*slot+i)*ch+c]=Int16(4096+(i%17)*256)}
                }
                let oracle=pcm.map{Float($0)/32768}
                let url=root.appendingPathComponent("\(name)-\(rate).wav")
                try fixture(mask:mask,channels:ch,frames:frames,rate:rate,pcm:pcm).write(to:url)
                let actual=try engine(url,channels:ch,frames:frames,rate:rate)
                XCTAssertTrue(actual.asbd);XCTAssertTrue(actual.timeline);XCTAssertEqual(actual.pcm.count,oracle.count)
                let exact=actual.pcm.count==oracle.count && zip(actual.pcm,oracle).allSatisfy{$0.0.bitPattern==$0.1.bitPattern}
                let labelExact=actual.labels==expected
                if overlay{XCTAssertTrue(exact);XCTAssertTrue(labelExact)}
                if exact{identical+=1};if labelExact{labelsExact+=1};total+=1
                var matrix=[String]()
                for c in 0..<ch {
                    let f=c*slot+128,divisor=oracle[f*ch+c]
                    matrix.append((0..<ch).map{String(format:"%.8f",actual.pcm[f*ch+$0]/divisor)}.joined(separator:","))
                }
                print("G0_4B42_CASE name=\(name) rate=\(rate) channels=\(ch) input=\(inNames.joined(separator:",")) defaultOutput=\(outNames.joined(separator:",")) actualTag=\(actual.tag) labels=\(actual.labels.map(String.init).joined(separator:",")) expectedLabels=\(expected.map(String.init).joined(separator:",")) sourceExact=\(exact) labelsExact=\(labelExact) frames=\(frames) matrix=\(matrix.joined(separator:";")) hash=\(hash(actual.pcm))")
            }
        }
        XCTAssertEqual(total,28)
        print("G0_4B42_SUMMARY cases=\(total) sourceExact=\(identical) labelsExact=\(labelsExact) overlay=\(overlay)")
    }
}
