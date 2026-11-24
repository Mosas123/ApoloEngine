import AetherLibavutil
import AetherLibswresample
import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

/// F04D.3: isolate rate conversion, drain policy and the production clock
/// arithmetic. This does not invoke or modify AudioDecoder's private methods.
final class G0F04DrainClockTests: XCTestCase {
    private enum LabError: Error { case setup, conversion, bound }
    private struct Buffer {
        let inputOffset: Int
        let frames: Int
    }
    private struct Epoch {
        var pcm: [Float] = []
        var buffers: [Buffer] = []
        var beforeDrain = 0
        var tail = 0
        var firstDrain = 0
        var drainCalls = 0
        var zeroCalls = 0
        var delayBefore: Int64 = 0
        var delayAfter: Int64 = 0
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func digest(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }
    private func exact(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a,b).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
    }
    private func convert(_ inputRate: Int32, _ outputRate: Int32, samples: Int,
                         channels: Int, phase: Double, drainCap: Int?) throws -> Epoch {
        var input = AVChannelLayout(), output = AVChannelLayout()
        av_channel_layout_default(&input, Int32(channels))
        av_channel_layout_default(&output, Int32(channels))
        defer { av_channel_layout_uninit(&input); av_channel_layout_uninit(&output) }
        var owner: OpaquePointer?
        defer { swr_free(&owner) }
        guard swr_alloc_set_opts2(&owner, &output, AV_SAMPLE_FMT_FLT, outputRate,
                                  &input, AV_SAMPLE_FMT_FLT, inputRate, 0, nil) >= 0,
              let swr = owner, swr_init(swr) >= 0 else { throw LabError.setup }
        var pcm: [Float] = []
        for i in 0..<samples {
            for c in 0..<channels {
                pcm.append(Float(0.3 * sin(2 * Double.pi * (997 + Double(c)*173) * Double(i)/Double(inputRate) + phase)))
            }
        }
        var r = Epoch()
        func step(_ src: UnsafePointer<UnsafePointer<UInt8>?>?, _ count: Int, _ limit: Int?) throws -> Int {
            let upper = swr_get_out_samples(swr, Int32(count))
            guard upper >= 0, upper <= 65536 else { throw LabError.bound }
            let capacity = max(1, min(Int(upper), limit ?? Int(upper)))
            var data = [Float](repeating: 0, count: capacity * channels)
            let got = data.withUnsafeMutableBytes { raw -> Int32 in
                var dst: UnsafeMutablePointer<UInt8>? = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return withUnsafeMutablePointer(to: &dst) { swr_convert(swr, $0, Int32(capacity), src, Int32(count)) }
            }
            guard got >= 0, got <= Int32(capacity) else { throw LabError.conversion }
            r.pcm.append(contentsOf: data.prefix(Int(got) * channels))
            guard r.pcm.count <= 65536 * channels else { throw LabError.bound }
            return Int(got)
        }
        let sizes = [1,7,31,127,509,1024,3,257]
        var cursor = 0, index = 0
        try pcm.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while cursor < samples {
                let n = min(sizes[index % sizes.count], samples - cursor)
                var src: UnsafePointer<UInt8>? = base.advanced(by: cursor * channels * 4)
                let got = try withUnsafePointer(to: &src) { try step($0, n, nil) }
                if got == 0 { r.zeroCalls += 1 }
                else { r.buffers.append(Buffer(inputOffset: cursor, frames: got)) }
                cursor += n; index += 1
            }
        }
        r.beforeDrain = r.pcm.count / channels
        r.delayBefore = swr_get_delay(swr, Int64(inputRate))
        var finished = false
        for i in 0..<128 {
            let got = try step(nil, 0, drainCap)
            if i == 0 { r.firstDrain = got }
            r.drainCalls += 1
            r.tail += got
            if got == 0 { finished = true; break }
        }
        r.delayAfter = swr_get_delay(swr, Int64(inputRate))
        guard finished, r.pcm.allSatisfy({ $0.isFinite }),
              r.beforeDrain + r.tail == r.pcm.count / channels else { throw LabError.conversion }
        return r
    }

    private struct Clock {
        var discontinuities = 0
        var largestGap: Int64 = 0
        var tailGap: Int64 = 0
        var next: Int64?
        mutating func append(_ start: Int64, _ count: Int) {
            guard count > 0 else { return }
            if let end = next, start != end {
                discontinuities += 1
                largestGap = max(largestGap, abs(start - end))
            }
            next = start + Int64(count)
        }
    }

    private func clocks(_ result: Epoch, _ inRate: Int32, _ outRate: Int32,
                        origin: Int64) -> (Clock, Clock, Int64) {
        var current = Clock(), anchored = Clock()
        var running: Int64 = 0
        let sourceTB = AVRational(num: 1, den: inRate)
        let outTB = AVRational(num: 1, den: outRate)
        for b in result.buffers {
            // Reproduce append(): input PTS rescaled to output ticks, but
            // runningSamples counts only the number of emitted samples.
            let pts = origin + av_rescale_q(Int64(b.inputOffset), sourceTB, outTB)
            current.append(pts, b.frames)
            anchored.append(origin + running, b.frames)
            running += Int64(b.frames)
        }
        if result.tail > 0 {
            if let previous = current.next { current.tailGap = running - previous }
            // Reproduce flushResampler()'s runningSamples clock.
            current.append(running, result.tail)
            anchored.append(origin + running, result.tail)
        }
        return (current, anchored, running + Int64(result.tail))
    }

    func testG0F04D3DrainAndClockControls() throws {
        // Each transition keeps a single output rate. Input epoch shape changes
        // are simulated by creating independent contexts, never stale pointers.
        let cases: [(Int32,Int32,Int32)] = [
            (44100,48000,48000), (48000,44100,44100),
            (96000,44100,48000), (192000,96000,44100),
            (48000,192000,96000), (44100,96000,192000)
        ]
        let samples = 8193
        var profiles = 0, accepted = 0, errors = 0, values = 0
        var discardedTailProfiles = 0, limitedDrainProfiles = 0, clockProfiles = 0
        for (first, second, out) in cases {
            for ch in [1,2] {
                profiles += 1
                let label = "first=\(first) second=\(second) out=\(out) channels=\(ch)"
                do {
                    let a = try convert(first,out,samples:samples,channels:ch,phase:0.17,drainCap:nil)
                    let b = try convert(second,out,samples:samples,channels:ch,phase:0.41,drainCap:nil)
                    let ac = try convert(first,out,samples:samples,channels:ch,phase:0.17,drainCap:7)
                    let bc = try convert(second,out,samples:samples,channels:ch,phase:0.41,drainCap:7)
                    let aCount = a.pcm.count/ch, bCount = b.pcm.count/ch
                    let ideal = (Double(samples)/Double(first) + Double(samples)/Double(second))*Double(out)
                    // Independent rounding of the two epochs may differ by <2 frames.
                    let countError = Double(aCount+bCount)-ideal
                    let bitExact = exact(a.pcm,ac.pcm) && exact(b.pcm,bc.pcm)
                    if bitExact { values += a.pcm.count+b.pcm.count }
                    if a.tail > 0 { discardedTailProfiles += 1 }
                    if ac.firstDrain < a.tail || bc.firstDrain < b.tail { limitedDrainProfiles += 1 }
                    let fullOneCall = a.firstDrain == a.tail && b.firstDrain == b.tail
                    var anchorOK = true
                    for origin: Int64 in [0,12345] {
                        let (current, anchor, count) = clocks(a,first,out,origin:origin)
                        // Next epoch begins at the actual emitted sample boundary.
                        let nextOrigin = origin + count
                        let (currentB, anchorB, countB) = clocks(b,second,out,origin:nextOrigin)
                        let boundary = (anchorB.next ?? -1) - (origin+count+countB)
                        let ok = anchor.discontinuities == 0 && anchorB.discontinuities == 0
                            && anchor.next == nextOrigin && boundary == 0
                        anchorOK = anchorOK && ok
                        if current.discontinuities > 0 || currentB.discontinuities > 0 { clockProfiles += 1 }
                        print("G0_F04D3_CLOCK \(label) origin=\(origin) currentGapsA=\(current.discontinuities) currentGapsB=\(currentB.discontinuities) currentMaxA=\(current.largestGap) currentMaxB=\(currentB.largestGap) currentTailGapA=\(current.tailGap) currentTailGapB=\(currentB.tailGap) anchoredEnd=\(anchorB.next ?? -1) expectedEnd=\(origin+count+countB) anchoredContinuous=\(ok)")
                    }
                    let ok = bitExact && abs(countError) <= 2 && anchorOK
                    if ok { accepted += 1 }
                    print("G0_F04D3_CASE \(label) firstFrames=\(aCount) secondFrames=\(bCount) ideal=\(ideal) countError=\(countError) firstTail=\(a.tail) secondTail=\(b.tail) discardedFirstTail=\(a.tail) firstFullDrain=\(a.firstDrain) secondFullDrain=\(b.firstDrain) fullOneCall=\(fullOneCall) firstCapDrain=\(ac.firstDrain) secondCapDrain=\(bc.firstDrain) firstCapCalls=\(ac.drainCalls) secondCapCalls=\(bc.drainCalls) delayBeforeA=\(a.delayBefore) delayAfterA=\(a.delayAfter) delayBeforeB=\(b.delayBefore) delayAfterB=\(b.delayAfter) zeroCallsA=\(a.zeroCalls) zeroCallsB=\(b.zeroCalls) drainPartitionExact=\(bitExact) firstSHA256=\(digest(a.pcm)) secondSHA256=\(digest(b.pcm)) accepted=\(ok)")
                } catch {
                    errors += 1
                    print("G0_F04D3_ERROR \(label) error=\(error)")
                }
            }
        }
        print("G0_F04D3_SUMMARY profiles=\(profiles) accepted=\(accepted) comparedValues=\(values) discardedTailProfiles=\(discardedTailProfiles) limitedDrainProfiles=\(limitedDrainProfiles) clockObservations=\(clockProfiles) errors=\(errors)")
        XCTAssertEqual(profiles,12)
        XCTAssertEqual(accepted,12)
        XCTAssertEqual(errors,0)
        // Raw-clock observations are not a production runtime regression test.
    }
}
