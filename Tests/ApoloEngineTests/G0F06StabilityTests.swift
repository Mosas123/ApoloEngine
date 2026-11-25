import AetherLibavutil
import CoreMedia
import Foundation
import XCTest

/// Exact integer reference on a deliberately bounded domain. No production
/// changes: the engine policy below models append/tail at equal sample rates.
final class G0F06StabilityTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func q(_ d:Int)->AVRational{AVRational(num:1,den:Int32(d))}
    private func nearest(_ x:Int64,_ mul:Int64,_ div:Int64)->Int64{
        let p=x*mul
        let magnitude=abs(p)
        let v=magnitude/div+(magnitude%div >= div-magnitude%div ? 1:0)
        return p<0 ? -v:v
    }
    func testG0F06DClockStability()throws{
        var stableProfiles=0,stableSteps=0,deltaProfiles=0,deltaSteps=0,offsetProfiles=0
        let rates=[44100,48000,96000,192000]
        let fixedSteps=8192
        let deltaCount=4096
        // Fixed additions only; variable increments are not covered by
        // av_add_stable's documented repeated-same-increment guarantee.
        for rate in rates{
            for scale in [600,1000,90000,rate]{
                for chunk in [1,257,960,1024]{
                    for origin:Int64 in [0,12345]{
                        stableProfiles+=1
                        var stable=origin,naive=origin
                        var maxStable:Int64=0,maxNaive:Int64=0,exactStable=0,exactNaive=0
                        let one=nearest(Int64(chunk),Int64(scale),Int64(rate))
                        var ref=origin
                        for i in 1...fixedSteps{
                            ref=origin+nearest(Int64(i*chunk),Int64(scale),Int64(rate))
                            stable=av_add_stable(q(scale),stable,q(rate),Int64(chunk))
                            naive+=one
                            let es=stable-ref,en=naive-ref
                            maxStable=max(maxStable,abs(es));maxNaive=max(maxNaive,abs(en))
                            if es==0{exactStable+=1};if en==0{exactNaive+=1}
                            stableSteps+=1
                        }
                        print("G0_F06D_STABLE rate=\(rate) scale=\(scale) chunk=\(chunk) origin=\(origin) steps=\(fixedSteps) subTick=\(Int64(chunk)*Int64(scale)<Int64(rate)) referenceEnd=\(ref) stableEndError=\(stable-ref) naiveEndError=\(naive-ref) stableMax=\(maxStable) naiveMax=\(maxNaive) stableExact=\(exactStable) naiveExact=\(exactNaive)")
                    }
                }
            }
        }
        // Compare source-clock rescale, actual equal-rate append policy,
        // a stateful delta control and an explicit anchor. Missing PTS is
        // never passed to av_rescale_delta (API requires a valid timestamp).
        for rate in rates{
            for scale in [1000,90000,rate]{
                for origin:Int64 in [0,12345]{
                    for scenario in ["fixed","irregular","gap","missing"]{
                        deltaProfiles+=1
                        var cursor=origin,running:Int64=0,last=Int64.min
                        var previousRaw:Int64?,previousEngine:Int64?,previousDelta:Int64?,previousAnchor:Int64?
                        var previousN:Int64=0
                        var rawJumps=0,engineJumps=0,deltaJumps=0,anchorJumps=0,missingCount=0
                        var rawMax:Int64=0,engineMax:Int64=0,deltaMax:Int64=0
                        var engineErrorMax:Int64=0,deltaErrorMax:Int64=0
                        var deltaFirst:Int64=0,firstError:Int64=0
                        var gapRaw:Int64=0,gapEngine:Int64=0,gapDelta:Int64=0
                        var lastEngine:Int64=0,lastDelta:Int64=0,lastAnchor:Int64=0
                        for i in 0..<deltaCount{
                            let n:Int64=scenario=="fixed" ? 1024:[257,960,1024,1152,511][i%5]
                            let gap=i==deltaCount/2 && scenario=="gap" ? Int64(rate/20):0
                            cursor+=gap
                            let pts=nearest(cursor,Int64(scale),Int64(rate))
                            let raw=av_rescale_q(pts,q(scale),q(rate))
                            let missing=scenario=="missing" && i>=deltaCount/2 && i<deltaCount/2+16
                            let engine=missing ? running:raw
                            let delta:Int64
                            if missing{
                                missingCount+=1
                                delta=last
                                last+=n
                            }else{
                                delta=av_rescale_delta(q(scale),pts,q(rate),Int32(n),&last,q(rate))
                            }
                            if i==0{deltaFirst=delta;firstError=delta-cursor}
                            // Independent anchor uses known synthetic physical
                            // sample positions, not a proposed production gap detector.
                            let anchor=cursor
                            if let pr=previousRaw,let pe=previousEngine,let pd=previousDelta,let pa=previousAnchor{
                                let jr=raw-(pr+previousN)-gap
                                let je=engine-(pe+previousN)-gap
                                let jd=delta-(pd+previousN)-gap
                                let ja=anchor-(pa+previousN)-gap
                                if jr != 0{rawJumps+=1};if je != 0{engineJumps+=1}
                                if jd != 0{deltaJumps+=1};if ja != 0{anchorJumps+=1}
                                rawMax=max(rawMax,abs(jr));engineMax=max(engineMax,abs(je));deltaMax=max(deltaMax,abs(jd))
                                if gap != 0{gapRaw=raw-pr-previousN;gapEngine=engine-pe-previousN;gapDelta=delta-pd-previousN}
                            }
                            engineErrorMax=max(engineErrorMax,abs(engine-cursor))
                            deltaErrorMax=max(deltaErrorMax,abs(delta-cursor))
                            previousRaw=raw;previousEngine=engine;previousDelta=delta;previousAnchor=anchor
                            previousN=n;lastEngine=engine;lastDelta=delta;lastAnchor=anchor
                            cursor+=n;running+=n;deltaSteps+=1
                        }
                        // Model an additional tail of 17 samples: compare
                        // current runningSamples PTS to last emitted end.
                        let tailCurrent=running
                        let tailError=tailCurrent-cursor
                        let tailGap=tailCurrent-(lastEngine+previousN)
                        let deltaTailGap=last-(lastDelta+previousN)
                        let anchorTailGap=cursor-(lastAnchor+previousN)
                        print("G0_F06D_DELTA rate=\(rate) scale=\(scale) origin=\(origin) scenario=\(scenario) steps=\(deltaCount) missing=\(missingCount) deltaFirst=\(deltaFirst) firstError=\(firstError) rawJumps=\(rawJumps) engineJumps=\(engineJumps) deltaJumps=\(deltaJumps) anchorJumps=\(anchorJumps) rawMax=\(rawMax) engineMax=\(engineMax) deltaMax=\(deltaMax) engineErrorMax=\(engineErrorMax) deltaErrorMax=\(deltaErrorMax) gapRaw=\(gapRaw) gapEngine=\(gapEngine) gapDelta=\(gapDelta) endEngineError=\(lastEngine+previousN-cursor) endDeltaError=\(lastDelta+previousN-cursor) tailError=\(tailError) tailGap=\(tailGap) deltaTailGap=\(deltaTailGap) anchorTailGap=\(anchorTailGap)")
                    }
                }
            }
        }
        // CoreMedia's real arithmetic at the current preferred scale 600,
        // compared to exact integer microsecond offsets at sample resolution.
        for rate in rates{
            for us:Int64 in [-1700,-700,-1,0,1,700,1700,1250000]{
                for start:Int64 in [0,12345]{
                    offsetProfiles+=1
                    let offset=CMTime(seconds:Double(us)/1000000,preferredTimescale:600)
                    let combined=CMTime(value:start,timescale:Int32(rate))+offset
                    let ticks=CMTimeConvertScale(combined,timescale:Int32(rate),method:.roundHalfAwayFromZero).value
                    let expected=start+nearest(us,Int64(rate),1000000)
                    print("G0_F06D_OFFSET rate=\(rate) us=\(us) start=\(start) offsetValue=\(offset.value) offsetScale=\(offset.timescale) actualTicks=\(ticks) referenceTicks=\(expected) errorTicks=\(ticks-expected)")
                }
            }
        }
        print("G0_F06D_SUMMARY stableProfiles=\(stableProfiles) stableSteps=\(stableSteps) deltaProfiles=\(deltaProfiles) deltaSteps=\(deltaSteps) offsetProfiles=\(offsetProfiles)")
        XCTAssertEqual(stableProfiles,128)
        XCTAssertEqual(stableSteps,1048576)
        XCTAssertEqual(deltaProfiles,96)
        XCTAssertEqual(deltaSteps,393216)
        XCTAssertEqual(offsetProfiles,64)
        // Completeness assertions only; measured deviations are findings.
    }
}
