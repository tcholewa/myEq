import CDSP
import XCTest

@testable import MyEqCore

final class MeterTests: XCTestCase {
  func testStereoPeaksRetainTransientsUntilConsumed() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    var pulse = [Float](repeating: 0, count: 256)
    pulse[0] = 0.25
    pulse[21] = -0.5
    meq_process(dsp, &pulse, 128)
    for _ in 0..<8 {
      var silence = [Float](repeating: 0, count: 256)
      meq_process(dsp, &silence, 128)
    }
    let health = meq_meter(dsp)
    XCTAssertEqual(health.peakLeft, 0.25, accuracy: 1e-6)
    XCTAssertEqual(health.peakRight, 0.5, accuracy: 1e-6)
    let interval = meq_take_meter(dsp)
    XCTAssertEqual(interval.peakLeft, health.peakLeft)
    XCTAssertEqual(interval.peakRight, health.peakRight)
    let drained = meq_take_meter(dsp)
    XCTAssertEqual(drained.peakLeft, 0)
    XCTAssertEqual(drained.peakRight, 0)
    XCTAssertEqual(drained.callbacks, 9)
    XCTAssertEqual(drained.faults, 0)
  }

  func testMeterReadsPostLimiterStereoSamples() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    var samples = [Float](repeating: 0, count: 256)
    samples[0] = 4
    samples[1] = 1
    meq_process(dsp, &samples, 128)
    let meter = meq_take_meter(dsp)
    XCTAssertEqual(meter.peakLeft, samples[96], accuracy: 1e-6)
    XCTAssertEqual(meter.peakRight, samples[97], accuracy: 1e-6)
    XCTAssertEqual(meter.peakRight / meter.peakLeft, 0.25, accuracy: 1e-6)
    XCTAssertLessThanOrEqual(meter.peakLeft, Float(pow(10, -0.5 / 20)) + 1e-6)
    XCTAssertGreaterThan(meter.reduction, 12)
    XCTAssertEqual(meq_take_meter(dsp).reduction, 0)
  }

  func testIndependentAttackAndFrameRateIndependentRelease() {
    var sixty = OutputMeterEnvelope()
    let peak = OutputLevels(left: 0.5, right: 0.125, active: true)
    sixty.update(peak, elapsed: 1 / 60)
    XCTAssertEqual(sixty.leftDB, -6.0206, accuracy: 0.0001)
    XCTAssertEqual(sixty.rightDB, -18.0618, accuracy: 0.0001)
    var thirty = sixty
    for _ in 0..<60 { sixty.update(OutputLevels(active: true), elapsed: 1 / 60) }
    for _ in 0..<30 { thirty.update(OutputLevels(active: true), elapsed: 1 / 30) }
    XCTAssertEqual(sixty.leftDB, -30.0206, accuracy: 0.0001)
    XCTAssertEqual(sixty.leftDB, thirty.leftDB, accuracy: 1e-6)
    XCTAssertEqual(sixty.rightDB, thirty.rightDB, accuracy: 1e-6)
    sixty.update(OutputLevels(left: 0.5, right: 0, active: true), elapsed: 1 / 60)
    XCTAssertEqual(sixty.leftDB, -6.0206, accuracy: 0.0001)
    XCTAssertLessThan(sixty.rightDB, -42)
  }

  func testSilenceInvalidInputAndBypassReset() {
    var meter = OutputMeterEnvelope()
    meter.update(OutputLevels(left: 0.8, right: 0.4, reduction: 5, active: true), elapsed: 1 / 60)
    meter.update(OutputLevels(), elapsed: 0)
    XCTAssertEqual(meter, OutputMeterEnvelope())
    meter.update(
      OutputLevels(left: .nan, right: .infinity, reduction: .nan, active: true), elapsed: .nan)
    XCTAssertEqual(meter, OutputMeterEnvelope())
    meter.update(OutputLevels(left: 0.8, right: 0.4, active: true), elapsed: 1 / 60)
    meter.update(OutputLevels(active: true), elapsed: 10)
    XCTAssertEqual(meter.leftDB, OutputMeterEnvelope.floorDB)
    XCTAssertEqual(meter.rightDB, OutputMeterEnvelope.floorDB)
  }
}
