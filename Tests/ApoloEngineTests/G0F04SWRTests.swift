import AetherLibavutil
import AetherLibswresample
import Foundation
import CryptoKit
import XCTest
@testable import ApoloEngine

/// F04A: isolate the linked SWR numeric conversion before testing CoreMedia,
/// rematrixing or different-rate resampling. All layouts are identical in/out.
final class G0F04SWRTests: XCTestCase {
    private enum LabError: Error { case setup, conversion, bound }
    private enum Kind: String, CaseIterable {
        case u8, s16, s32, f32, f64
        var width: Int {
            switch self {
            case .u8: return 1
            case .s16: return 2
            case .s32, .f32: return 4
            case .f64: return 8
            }
        }
        func format(_ planar: Bool) -> AVSampleFormat {
            switch self {
            case .u8: return planar ? AV_SAMPLE_FMT_U8P : AV_SAMPLE_FMT_U8
            case .s16: return planar ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S16
            case .s32: return planar ? AV_SAMPLE_FMT_S32P : AV_SAMPLE_FMT_S32
            case .f32: return planar ? AV_SAMPLE_FMT_FLTP : AV_SAMPLE_FMT_FLT
            case .f64: return planar ? AV_SAMPLE_FMT_DBLP : AV_SAMPLE_FMT_DBL
            }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"] == "1")
    }

    private func bytes<T>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    private func scalar(_ kind: Kind, frame: Int, channel: Int) -> ([UInt8], Float) {
        // Boundary and tiny values, distinct per channel. Input bytes are exact;
        // expected Float32 is independently computed from the integer or double.
        let i = (frame + channel * 13) % 17
        let values: [Int32] = [Int32.min, Int32.max, -1, 0, 1, -256, 256,
                               -65536, 65536, -16777217, 16777217,
                               -1073741824, 1073741824, -2147483392,
                               2147483392, -123456789, 987654321]
        let v = values[i]
        switch kind {
        case .u8:
            let x = UInt8(Int(v >> 24) + 128)
            return ([x], Float(Int(x) - 128) / 128)
        case .s16:
            let x = Int16(v >> 16)
            return (bytes(x), Float(x) / 32768)
        case .s32:
            return (bytes(v), Float(Double(v) / 2147483648))
        case .f32:
            let x = Float(Double(v) / 2147483648)
            return (bytes(x), x)
        case .f64:
            let x = Double(v) / 2147483648
            return (bytes(x), Float(x))
        }
    }

    private func hash(_ pcm: [Float]) -> String {
        let bits = pcm.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
    }

    private func measure(kind: Kind, planar: Bool, rate: Int32, channels: Int) throws -> (Int, Int, Double, String, Int64, Int) {
        var input = AVChannelLayout()
        var output = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &input)
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &output)
        defer {
            av_channel_layout_uninit(&input)
            av_channel_layout_uninit(&output)
        }
        var context: OpaquePointer?
        defer { swr_free(&context) }
        guard swr_alloc_set_opts2(&context, &output, AV_SAMPLE_FMT_FLT, rate,
                                  &input, kind.format(planar), rate, 0, nil) >= 0,
              let swr = context, swr_init(swr) >= 0
        else { throw LabError.setup }
        var actual: [Float] = [], expected: [Float] = []
        var cursor = 0
        var maxDelay: Int64 = 0
        func convert(_ source: UnsafePointer<UnsafePointer<UInt8>?>?, _ count: Int32) throws -> Int {
            let upper = swr_get_out_samples(swr, count)
            guard upper >= 0, upper <= 8192 else { throw LabError.bound }
            let capacity = max(Int(upper), 1)
            var chunk = [Float](repeating: 0, count: capacity * channels)
            let got = chunk.withUnsafeMutableBytes { dst -> Int32 in
                var ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self) as UnsafeMutablePointer<UInt8>?
                return withUnsafeMutablePointer(to: &ptr) {
                    swr_convert(swr, $0, Int32(capacity), source, count)
                }
            }
            guard got >= 0, got <= Int32(capacity) else { throw LabError.conversion }
            actual.append(contentsOf: chunk.prefix(Int(got) * channels))
            maxDelay = max(maxDelay, swr_get_delay(swr, Int64(rate)))
            return Int(got)
        }
        for n in [1, 7, 31, 64, 154] {
            var data = [UInt8](repeating: 0, count: n * channels * kind.width)
            for f in 0..<n {
                for c in 0..<channels {
                    let (b, x) = scalar(kind, frame: cursor + f, channel: c)
                    expected.append(x)
                    let offset = (planar ? c * n + f : f * channels + c) * kind.width
                    data.replaceSubrange(offset..<(offset + kind.width), with: b)
                }
            }
            _ = try data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let planes: [UnsafePointer<UInt8>?] = (0..<(planar ? channels : 1)).map {
                    base.advanced(by: $0 * n * kind.width)
                }
                return try planes.withUnsafeBufferPointer {
                    try convert($0.baseAddress, Int32(n))
                }
            }
            cursor += n
        }
        var tail = 0
        var drained = false
        for _ in 0..<16 {
            let got = try convert(nil, 0)
            tail += got
            if got == 0 { drained = true; break }
        }
        guard drained, actual.allSatisfy({ $0.isFinite }) else { throw LabError.bound }
        var different = -1, peak = Double.infinity
        if actual.count == expected.count {
            different = 0; peak = 0
            for (a, b) in zip(actual, expected) {
                if a.bitPattern != b.bitPattern { different += 1 }
                peak = max(peak, abs(Double(a) - Double(b)))
            }
        }
        return (actual.count / channels, different, peak, hash(actual), maxDelay, tail)
    }

    func testG0F04ASameRateNumericIdentity() throws {
        var attempted = 0, exact = 0, errors = 0, values = 0
        let rates: [Int32] = [44100, 48000, 96000, 192000]
        for rate in rates {
            for channels in [1, 2, 6, 8] {
                for kind in Kind.allCases {
                    for planar in [false, true] {
                        attempted += 1
                        let label = "rate=\(rate) channels=\(channels) format=\(kind.rawValue) planar=\(planar)"
                        do {
                            let (frames, different, peak, digest, delay, tail) = try measure(kind: kind, planar: planar, rate: rate, channels: channels)
                            let ok = frames == 257 && different == 0 && delay == 0 && tail == 0
                            if ok { exact += 1; values += frames * channels }
                            print("G0_F04A_CASE \(label) frames=\(frames) different=\(different) peak=\(peak) pcmSHA256=\(digest) maxDelay=\(delay) tail=\(tail) exact=\(ok)")
                        } catch {
                            errors += 1
                            print("G0_F04A_ERROR \(label) error=\(error)")
                        }
                    }
                }
            }
        }
        print("G0_F04A_SUMMARY attempted=\(attempted) exact=\(exact) comparedValues=\(values) errors=\(errors)")
        XCTAssertEqual(attempted, 160)
        XCTAssertEqual(exact, 160)
        XCTAssertEqual(values, 174760)
        XCTAssertEqual(errors, 0)
    }

    // F04B isolates actual rate conversion from decoding, DSP and rendering.
    private struct RateResult {
        let pcm: [Float]
        let tail: Int
        let maxDelayInputFrames: Int64
        let delayBeforeDrain: Int64
        let delayAfterDrain: Int64
        let zeroOutputCalls: Int
        let drainCalls: Int
    }

    private func convertRate(_ pcm: [Float], inputRate: Int32, outputRate: Int32,
                             channels: Int, split: Bool) throws -> RateResult {
        var input = AVChannelLayout()
        var output = AVChannelLayout()
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &input)
        AudioDecoder.makeResamplerOutputLayout(channels: Int32(channels), into: &output)
        defer {
            av_channel_layout_uninit(&input)
            av_channel_layout_uninit(&output)
        }
        var context: OpaquePointer?
        defer { swr_free(&context) }
        guard swr_alloc_set_opts2(&context, &output, AV_SAMPLE_FMT_FLT, outputRate,
                                  &input, AV_SAMPLE_FMT_FLT, inputRate, 0, nil) >= 0,
              let swr = context, swr_init(swr) >= 0
        else { throw LabError.setup }
        guard !pcm.isEmpty, pcm.count % channels == 0 else { throw LabError.bound }
        var actual: [Float] = []
        var maxDelay: Int64 = 0
        var zeroCalls = 0
        func convert(_ source: UnsafePointer<UnsafePointer<UInt8>?>?, _ count: Int32) throws -> Int {
            let upper = swr_get_out_samples(swr, count)
            guard upper >= 0, upper <= 65536 else { throw LabError.bound }
            let capacity = max(1, Int(upper))
            var chunk = [Float](repeating: 0, count: capacity * channels)
            let got = chunk.withUnsafeMutableBytes { dst -> Int32 in
                var ptr: UnsafeMutablePointer<UInt8>? = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return withUnsafeMutablePointer(to: &ptr) {
                    swr_convert(swr, $0, Int32(capacity), source, count)
                }
            }
            guard got >= 0, got <= Int32(capacity) else { throw LabError.conversion }
            actual.append(contentsOf: chunk.prefix(Int(got) * channels))
            guard actual.count <= 65536 * channels else { throw LabError.bound }
            let delay = swr_get_delay(swr, Int64(inputRate))
            guard delay >= 0 else { throw LabError.conversion }
            maxDelay = max(maxDelay, delay)
            if count > 0 && got == 0 { zeroCalls += 1 }
            return Int(got)
        }
        let total = pcm.count / channels
        let sizes = [1, 7, 31, 127, 509, 1024, 3, 257]
        var cursor = 0, index = 0
        try pcm.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while cursor < total {
                let count = split ? min(sizes[index % sizes.count], total - cursor) : total
                var src: UnsafePointer<UInt8>? = base.advanced(by: cursor * channels * 4)
                _ = try withUnsafePointer(to: &src) { try convert($0, Int32(count)) }
                cursor += count
                index += 1
            }
        }
        let before = swr_get_delay(swr, Int64(inputRate))
        var tail = 0, calls = 0, drained = false
        for _ in 0..<32 {
            let n = try convert(nil, 0)
            calls += 1
            tail += n
            if n == 0 { drained = true; break }
        }
        guard drained, !actual.isEmpty, actual.allSatisfy({ $0.isFinite })
        else { throw LabError.bound }
        return RateResult(pcm: actual, tail: tail, maxDelayInputFrames: maxDelay,
                          delayBeforeDrain: before,
                          delayAfterDrain: swr_get_delay(swr, Int64(inputRate)),
                          zeroOutputCalls: zeroCalls, drainCalls: calls)
    }

    private func signal(_ t: Double, _ channel: Int) -> Double {
        0.30 * sin(2 * Double.pi * (997 + 43 * Double(channel)) * t + 0.17 * Double(channel))
        + 0.12 * cos(2 * Double.pi * (2711 + 61 * Double(channel)) * t)
    }

    func testG0F04BDifferentRateChunkInvariance() throws {
        let rates: [Int32] = [44100, 48000, 96000, 192000]
        let frames = 8193
        var profiles = 0, accepted = 0, exact = 0, errors = 0, compared = 0
        var aliasControls = 0
        for inputRate in rates {
            for outputRate in rates where inputRate != outputRate {
                for channels in [1, 2] {
                    profiles += 1
                    let label = "in=\(inputRate) out=\(outputRate) channels=\(channels)"
                    do {
                        var pcm: [Float] = []
                        pcm.reserveCapacity(frames * channels)
                        for i in 0..<frames {
                            for c in 0..<channels {
                                pcm.append(Float(signal(Double(i) / Double(inputRate), c)))
                            }
                        }
                        let whole = try convertRate(pcm, inputRate: inputRate, outputRate: outputRate,
                                                    channels: channels, split: false)
                        let split = try convertRate(pcm, inputRate: inputRate, outputRate: outputRate,
                                                    channels: channels, split: true)
                        let n = whole.pcm.count / channels
                        let m = split.pcm.count / channels
                        let idealCeil = Int((Int64(frames) * Int64(outputRate) + Int64(inputRate) - 1) / Int64(inputRate))
                        guard n == m, n > 512 else {
                            print("G0_F04B_COUNT \(label) whole=\(n) split=\(m) idealCeil=\(idealCeil)")
                            throw LabError.conversion
                        }
                        var unequal = 0, partitionPeak = 0.0, errorPeak = 0.0, squares = 0.0
                        var outputPeak = 0.0
                        for i in whole.pcm.indices {
                            let a = whole.pcm[i], b = split.pcm[i]
                            if a.bitPattern != b.bitPattern { unequal += 1 }
                            partitionPeak = max(partitionPeak, abs(Double(a) - Double(b)))
                            outputPeak = max(outputPeak, abs(Double(a)), abs(Double(b)))
                        }
                        // Interior only: exclude edge extension/transient response.
                        // Time oracle is independent of SWR and does not fit phase.
                        for i in 256..<(n - 256) {
                            for c in 0..<channels {
                                let reference = signal(Double(i) / Double(outputRate), c)
                                let error = Double(whole.pcm[i * channels + c]) - reference
                                squares += error * error
                                errorPeak = max(errorPeak, abs(error))
                            }
                        }
                        let rms = sqrt(squares / Double((n - 512) * channels))
                        let ok = abs(n - idealCeil) <= 1 && partitionPeak <= 1e-6
                            && rms <= 0.002 && errorPeak <= 0.01 && outputPeak <= 1.0
                        if unequal == 0 { exact += 1 }
                        if ok { accepted += 1 }
                        compared += whole.pcm.count
                        print("G0_F04B_CASE \(label) inputFrames=\(frames) whole=\(n) split=\(m) ceil=\(idealCeil) different=\(unequal) partitionPeak=\(partitionPeak) interiorRMS=\(rms) interiorPeakError=\(errorPeak) outputPeak=\(outputPeak) wholeTail=\(whole.tail) splitTail=\(split.tail) wholeMaxDelayIn=\(whole.maxDelayInputFrames) splitMaxDelayIn=\(split.maxDelayInputFrames) wholeBeforeDrain=\(whole.delayBeforeDrain) splitBeforeDrain=\(split.delayBeforeDrain) wholeAfterDrain=\(whole.delayAfterDrain) splitAfterDrain=\(split.delayAfterDrain) wholeDrainCalls=\(whole.drainCalls) splitDrainCalls=\(split.drainCalls) splitZeroCalls=\(split.zeroOutputCalls) wholeSHA256=\(hash(whole.pcm)) splitSHA256=\(hash(split.pcm)) accepted=\(ok)")
                    } catch {
                        errors += 1
                        print("G0_F04B_ERROR \(label) error=\(error)")
                    }
                }
                if inputRate > outputRate {
                    // Stopband observations are exploratory, not a conformance
                    // threshold: near-Nyquist transition width depends on ratio.
                    let frequency = (Double(inputRate) + Double(outputRate)) / 4
                    do {
                        let pcm = (0..<frames).map { Float(0.4 * sin(2 * Double.pi * frequency * Double($0) / Double(inputRate))) }
                        let result = try convertRate(pcm, inputRate: inputRate, outputRate: outputRate,
                                                     channels: 1, split: true)
                        let n = result.pcm.count
                        guard n > 512 else { throw LabError.bound }
                        let sum = result.pcm[256..<(n - 256)].reduce(0.0) { $0 + Double($1) * Double($1) }
                        let rms = sqrt(sum / Double(n - 512))
                        let attenuation = 20 * log10(max(rms, 1e-30) / (0.4 / sqrt(2.0)))
                        aliasControls += 1
                        print("G0_F04B_STOPBAND in=\(inputRate) out=\(outputRate) toneHz=\(frequency) outputFrames=\(n) interiorRMS=\(rms) relativeDB=\(attenuation) tail=\(result.tail) pcmSHA256=\(hash(result.pcm))")
                    } catch {
                        errors += 1
                        print("G0_F04B_ERROR stopband in=\(inputRate) out=\(outputRate) error=\(error)")
                    }
                }
            }
        }
        print("G0_F04B_SUMMARY profiles=\(profiles) accepted=\(accepted) exactPartitions=\(exact) comparedValues=\(compared) stopbandControls=\(aliasControls) errors=\(errors)")
        XCTAssertEqual(profiles, 24)
        XCTAssertEqual(accepted, 24, "Preserve any rate/count/partition/passband discrepancy as a G0 observation.")
        XCTAssertEqual(aliasControls, 6)
        XCTAssertEqual(errors, 0)
    }

    // F04E: default SWR transfer response, not an audio quality certification.
    // Coherent single tones at multiples of 25 Hz, 200 ms source, central
    // 160 ms measurement (four cycles per 25 Hz); exclude both filter edges.
    private func spectralProjection(_ pcm: [Float], rate: Int32, hz: Int,
                                    start: Int, end: Int) -> (sin: Double, cos: Double) {
        var s = 0.0, c = 0.0
        let omega = 2 * Double.pi * Double(hz) / Double(rate)
        for i in start..<end {
            let x = Double(pcm[i]), angle = omega * Double(i)
            s += x * sin(angle)
            c += x * cos(angle)
        }
        let scale = 2.0 / Double(end-start)
        return (s*scale,c*scale)
    }

    func testG0F04EDefaultSpectralSweep() throws {
        let rates: [Int32] = [44100,48000,96000,192000]
        let passFractions = [0.025,0.10,0.25,0.50,0.75,0.85,0.90,0.95,0.975,0.99]
        let nearStop = [1.005,1.01,1.025,1.05,1.075]
        let amplitude = 0.4
        func grid(_ hz: Double) -> Int { Int((hz/25).rounded())*25 }
        func db(_ ratio: Double) -> Double { 20*log10(max(ratio,1e-15)) }
        var planned = 0, observed = 0, passCount = 0, stopCount = 0
        var errors = 0, scalars = 0, lowBandWorstDB = 0.0
        var maxResidualDB = -300.0
        for inputRate in rates {
            for outputRate in rates where inputRate != outputRate {
                let inNyq = Int(inputRate)/2, outNyq = Int(outputRate)/2
                let edge = min(inNyq,outNyq)
                let pass = Set(passFractions.map { grid(Double(edge)*$0) }).sorted()
                var stop: [Int] = []
                if inputRate > outputRate {
                    let candidates = nearStop.map { grid(Double(outNyq)*$0) } + [
                        grid(Double(inNyq+outNyq)/2), grid(Double(inNyq)*0.995)
                    ]
                    stop = Set(candidates.filter { $0 > outNyq && $0 < inNyq }).sorted()
                }
                for hz in pass+stop {
                    planned += 1
                    let isStop = hz > outNyq
                    let label = "in=\(inputRate) out=\(outputRate) toneHz=\(hz) band=\(isStop ? "stop" : "pass") edgeFraction=\(Double(hz)/Double(edge))"
                    do {
                        let frames = Int(inputRate)/5
                        let pcm = (0..<frames).map {
                            Float(amplitude*sin(2*Double.pi*Double(hz)*Double($0)/Double(inputRate)))
                        }
                        let result = try convertRate(pcm,inputRate:inputRate,outputRate:outputRate,channels:1,split:true)
                        let nominal = Int(outputRate)/5
                        let start = Int(outputRate)/50
                        let end = nominal-start
                        guard abs(result.pcm.count-nominal)<=1, end<=result.pcm.count,
                              hz>0, hz<inNyq, start<end else { throw LabError.bound }
                        // Fold the source tone into output Nyquist. At DC or
                        // Nyquist the ordinary two-sided projection is singular;
                        // retain broadband RMS and mark tone metrics unavailable.
                        let remainder = hz % Int(outputRate)
                        let folded = min(remainder,Int(outputRate)-remainder)
                        let validTone = folded>0 && folded<outNyq
                        let fit = validTone ? spectralProjection(result.pcm,rate:outputRate,hz:folded,start:start,end:end) : (sin:0.0,cos:0.0)
                        let gain = hypot(fit.sin,fit.cos)/amplitude
                        let toneDB = validTone ? db(gain) : -300
                        var squares = 0.0, residual = 0.0
                        let omega = 2*Double.pi*Double(folded)/Double(outputRate)
                        for i in start..<end {
                            let x=Double(result.pcm[i])
                            squares += x*x
                            let error=x-fit.sin*sin(omega*Double(i))-fit.cos*cos(omega*Double(i))
                            residual += error*error
                        }
                        let rmsDB = db(sqrt(squares/Double(end-start))/(amplitude/sqrt(2.0)))
                        let residualDB = db(sqrt(residual/Double(end-start))/(amplitude/sqrt(2.0)))
                        // First and higher image candidates k*inputRate ± f
                        // within output Nyquist; report the strongest projection.
                        var imageHz = 0, imageDB = -300.0
                        if outputRate > inputRate {
                            var images = Set<Int>()
                            for k in 1...(outNyq/Int(inputRate)+1) {
                                for candidate in [k*Int(inputRate)-hz,k*Int(inputRate)+hz] {
                                    if candidate>0 && candidate<outNyq && candidate != folded { images.insert(candidate) }
                                }
                            }
                            for f in images.sorted() {
                                let p=spectralProjection(result.pcm,rate:outputRate,hz:f,start:start,end:end)
                                let level=db(hypot(p.sin,p.cos)/amplitude)
                                if level>imageDB { imageDB=level; imageHz=f }
                            }
                        }
                        guard rmsDB.isFinite,residualDB.isFinite,toneDB.isFinite,imageDB.isFinite else { throw LabError.conversion }
                        if isStop { stopCount += 1 } else {
                            passCount += 1
                            if Double(hz)/Double(edge)<=0.75 { lowBandWorstDB=max(lowBandWorstDB,abs(toneDB)) }
                            maxResidualDB=max(maxResidualDB,residualDB)
                        }
                        observed += 1; scalars += result.pcm.count
                        let phase = validTone ? atan2(fit.cos,fit.sin) : 0
                        print("G0_F04E_CASE \(label) inputFrames=\(frames) outputFrames=\(result.pcm.count) measuredFrames=\(end-start) foldedHz=\(folded) toneValid=\(validTone) toneDB=\(toneDB) rmsDB=\(rmsDB) residualDB=\(residualDB) phaseRad=\(phase) imageHz=\(imageHz) imageDB=\(imageDB) tail=\(result.tail) pcmSHA256=\(hash(result.pcm))")
                    } catch {
                        errors += 1
                        print("G0_F04E_ERROR \(label) error=\(error)")
                    }
                }
            }
        }
        print("G0_F04E_SUMMARY planned=\(planned) observed=\(observed) pass=\(passCount) stop=\(stopCount) outputValues=\(scalars) lowBandWorstAbsDB=\(lowBandWorstDB) maxPassResidualDB=\(maxResidualDB) errors=\(errors)")
        XCTAssertEqual(passCount,120)
        XCTAssertGreaterThanOrEqual(stopCount,36)
        XCTAssertEqual(observed,planned)
        XCTAssertEqual(errors,0)
        // No invented spectral pass/fail limits. Report actual transition
        // width, alias and imaging measurements for later policy decisions.
    }
}
