import AetherLibavutil
import Foundation
import XCTest

/// F06A: independent integer oracle, not a copy of FFmpeg's implementation.
final class G0F06ClockTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APOLO_G0_LAB"]=="1")
    }
    private func q(_ n:Int32,_ d:Int32)->AVRational{AVRational(num:n,den:d)}
    // Full-width unsigned product and quotient; positive numerator/denominator,
    // nearest ties away from zero. Overflow sentinel follows public API.
    private func oracle(_ x:Int64,_ b:UInt64,_ c:UInt64,mode:Int=5)->Int64 {
        let product=x.magnitude.multipliedFullWidth(by:b)
        guard product.high<c else{return Int64.min}
        let division=c.dividingFullWidth(product)
        var v=division.quotient
        let rem=division.remainder
        let increment:Bool
        switch mode{
        case 0: increment=false
        case 1: increment=rem != 0
        case 2: increment=x<0 && rem != 0
        case 3: increment=x>=0 && rem != 0
        default: increment=rem>=c-rem
        }
        if increment{
            guard v<UInt64.max else{return Int64.min}
            v+=1
        }
        guard v<=UInt64(Int64.max) else{return Int64.min}
        return x<0 ? -Int64(v):Int64(v)
    }
    func testG0F06AClock()throws {
        let bases=[q(1,1000),q(1,44100),q(1,48000),q(1,96000),q(1,192000),q(1,90000),q(1,1000000),q(1001,30000)]
        let stamps:[Int64]=[-1000000000000,-123456789,-90001,-12345,-1024,-3,-2,-1,0,1,2,3,1024,12345,90001,123456789,1000000000000]
        let modes:[(Int,AVRounding)]=[(0,AV_ROUND_ZERO),(1,AV_ROUND_INF),(2,AV_ROUND_DOWN),(3,AV_ROUND_UP),(5,AV_ROUND_NEAR_INF)]
        var qCount=0,qExact=0,roundCount=0,roundExact=0,cmpCount=0,cmpExact=0,edges=0,edgeExact=0
        for a in bases{
            for b in bases{
                let mul=UInt64(a.num)*UInt64(b.den)
                let div=UInt64(a.den)*UInt64(b.num)
                var mismatches=0
                for x in stamps{
                    qCount+=1
                    let actual=av_rescale_q(x,a,b),expected=oracle(x,mul,div)
                    if actual==expected{qExact+=1}else{mismatches+=1;print("G0_F06A_MISMATCH kind=q x=\(x) from=\(a.num)/\(a.den) to=\(b.num)/\(b.den) actual=\(actual) expected=\(expected)")}
                    for (m,flag) in modes{
                        roundCount+=1
                        let actual=av_rescale_q_rnd(x,a,b,flag)
                        let expected=oracle(x,mul,div,mode:m)
                        if actual==expected{roundExact+=1}else{mismatches+=1;print("G0_F06A_MISMATCH kind=round mode=\(m) x=\(x) from=\(a.num)/\(a.den) to=\(b.num)/\(b.den) actual=\(actual) expected=\(expected)")}
                    }
                    // Exact rational cross multiplication: all selected
                    // products fit Int64, including the non-unit numerator.
                    for y in stamps{
                        let lhs=x*Int64(mul),rhs=y*Int64(div)
                        let expected:Int32=lhs<rhs ? -1 : lhs>rhs ? 1:0
                        let actual=av_compare_ts(x,a,y,b)
                        cmpCount+=1
                        if actual==expected{cmpExact+=1}else{mismatches+=1;print("G0_F06A_MISMATCH kind=compare x=\(x) y=\(y) from=\(a.num)/\(a.den) to=\(b.num)/\(b.den) actual=\(actual) expected=\(expected)")}
                    }
                }
                print("G0_F06A_PAIR from=\(a.num)/\(a.den) to=\(b.num)/\(b.den) timestamps=\(stamps.count) mismatches=\(mismatches) origin12345=\(av_rescale_q(12345,a,b))")
            }
        }
        // Large multiplier paths, exact half ties, positive overflow.
        // No invalid denominators or undefined assertion-triggering arguments.
        let large:[(Int64,Int64,Int64)]=[
            (Int64.max,1,1),(Int64.max,2,1),(Int64.max,2,2),
            (Int64.max,3,2),(Int64.max,1,2),(Int64.max,Int64.max,Int64.max),
            (Int64.max,4294967297,4294967296),
            (9007199254740993,4294967297,4294967296),
            (-9007199254740993,4294967297,4294967296),
            (1,1,2),(-1,1,2),(3,1,2),(-3,1,2),
            (1234567890123456,1000000000000,1000000000001),
            (0,Int64.max,1),(Int64.max,0,1)
        ]
        for (x,b,c) in large{
            for (m,flag) in modes{
                edges+=1
                let actual=av_rescale_rnd(x,b,c,flag)
                let expected=oracle(x,UInt64(b),UInt64(c),mode:m)
                if actual==expected{edgeExact+=1}
                print("G0_F06A_EDGE x=\(x) b=\(b) c=\(c) mode=\(m) actual=\(actual) expected=\(expected) exact=\(actual==expected)")
            }
        }
        let pass=AVRounding(rawValue:AV_ROUND_NEAR_INF.rawValue | AV_ROUND_PASS_MINMAX.rawValue)
        for x in [Int64.min,Int64.max]{
            edges+=1
            let actual=av_rescale_rnd(x,48000,1000,pass)
            if actual==x{edgeExact+=1}
            print("G0_F06A_SENTINEL x=\(x) actual=\(actual) exact=\(actual==x)")
        }
        print("G0_F06A_SUMMARY qCount=\(qCount) qExact=\(qExact) roundCount=\(roundCount) roundExact=\(roundExact) cmpCount=\(cmpCount) cmpExact=\(cmpExact) edges=\(edges) edgeExact=\(edgeExact)")
        XCTAssertEqual(qCount,1088)
        XCTAssertEqual(roundCount,5440)
        XCTAssertEqual(cmpCount,18496)
        XCTAssertEqual(edges,82)
        // Completeness only: preserve and inspect numerical discrepancies.
    }
}
