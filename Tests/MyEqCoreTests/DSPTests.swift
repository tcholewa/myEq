import XCTest
@testable import MyEqCore
import CDSP

final class DSPTests: XCTestCase {
    func render(_ bands: [EQBand], rate: Double = 48000, preamp: Double = 0, frames: Int = 48000, signal: (Int)->(Float,Float)) -> [Float] {
        let d=meq_create()!;defer{meq_destroy(d)}
        let b=bands.map(\.native)
        XCTAssertTrue(meq_prepare(d,rate,b,Int32(b.count),preamp))
        var samples=(0..<frames).flatMap {i -> [Float] in let (l,r)=signal(i);return [l,r]}
        meq_process(d,&samples,UInt32(frames));return samples
    }
    func testFlatAndStereoSeparation() {
        let result=render(EQPreset.flat.bands,frames:1000){$0==0 ? (0.25,0):(0,0)}
        XCTAssertEqual(result[48*2],0.25,accuracy:1e-6)
        XCTAssertEqual(result.enumerated().filter{$0.offset%2==1}.map{abs($0.element)}.max(),0)
        XCTAssertEqual(result.map{abs($0)}.reduce(0,+),0.25,accuracy:1e-6)
    }
    func testFilterAnchorsAndCombinedHeadroom() {
        let bell=EQBand(id:0,frequency:1000,gain:6,width:0.1)
        XCTAssertEqual(EQResponse.gain([bell],at:1000),6,accuracy:1e-6)
        XCTAssertLessThan(abs(EQResponse.gain([bell],at:2000)),0.1)
        XCTAssertEqual(EQResponse.autoPreamp([bell,EQBand(id:1,frequency:1000,gain:6,width:0.1)]),-12,accuracy:0.11)
        for type in [FilterType.lowCut,.highCut] {
            XCTAssertEqual(EQResponse.gain([EQBand(id:0,type:type,frequency:1000,width:1/sqrt(2))],at:1000),-3.0103,accuracy:0.001)
        }
        XCTAssertEqual(EQResponse.gain([EQBand(id:0,type:.lowShelf,frequency:1000,gain:6)],at:0),6,accuracy:0.001)
        XCTAssertEqual(EQResponse.gain([EQBand(id:0,type:.highShelf,frequency:1000,gain:6)],at:24000),6,accuracy:0.001)
    }
    func testMeasuredResponseMatchesPlot() {
        for rate in [44100.0,48000,96000,192000] {
            let bands=[EQBand(id:0,frequency:690,gain:-5,width:0.15)]
            let samples=render(bands,rate:rate,frames:Int(rate)){i in (Float(0.1*sin(2 * .pi*690*Double(i)/rate)),0)}
            let left=stride(from:Int(rate),to:samples.count,by:2).map{Double(samples[$0])}
            let rms=sqrt(left.reduce(0){$0+$1*$1}/Double(left.count))
            XCTAssertEqual(20*log10(rms/(0.1/sqrt(2))),EQResponse.gain(bands,at:690,sampleRate:rate),accuracy:0.03)
        }
    }
    func testLimiterCeilingAndLinking() {
        let samples=render(EQPreset.flat.bands,frames:3000){i in i==100 ? (10,5):(0,0)}
        XCTAssertLessThanOrEqual(samples.map{abs($0)}.max()!,Float(pow(10,-0.5/20))+1e-6)
        XCTAssertEqual(samples[148*2+1]/samples[148*2],0.5,accuracy:1e-6)
        XCTAssertGreaterThan(samples[148*2],0.9)
    }
    func testAllFiltersRemainFiniteAtExtremes() {
        for rate in [44100.0,48000,96000,192000] {
            for type in FilterType.allCases {
                for width in [type.widthRange.lowerBound,type.widthRange.upperBound] {
                    let b=(0..<8).map{EQBand(id:$0,type:type,frequency:$0%2==0 ? 20:20000,gain:$0%2==0 ? 24:-24,width:width)}
                    let s=render(b,rate:rate,frames:4096){i in (i==0 ? 0.1:0,0)}
                    XCTAssertTrue(s.allSatisfy(\.isFinite))
                    XCTAssertLessThanOrEqual(s.map{abs($0)}.max()!,1)
                }
            }
        }
    }
    func testRapidUpdatesAndQueuePressure() {
        let d=meq_create()!;defer{meq_destroy(d)}
        let b=EQPreset.flat.bands.map(\.native)
        XCTAssertTrue(meq_prepare(d,48000,b,8,0))
        for i in 0..<16 {XCTAssertTrue(meq_submit(d,b,8,Double(-i)))}
        XCTAssertFalse(meq_submit(d,b,8,0))
        var audio=[Float](repeating:0.1,count:4096)
        meq_process(d,&audio,2048)
        XCTAssertTrue(meq_submit(d,b,8,0))
        XCTAssertTrue(audio.allSatisfy(\.isFinite))
        let jumps=(1..<2048).map{abs(audio[$0*2]-audio[($0-1)*2])}
        XCTAssertLessThan(jumps.dropFirst(49).max()!,0.002)
    }
    func testNonFiniteInputIsContained() {
        let result=render(EQPreset.flat.bands,frames:1000){i in i==0 ? (.nan,.infinity):(0.1,0.2)}
        XCTAssertTrue(result.allSatisfy(\.isFinite))
    }
}
