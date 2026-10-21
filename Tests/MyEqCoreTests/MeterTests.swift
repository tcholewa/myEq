import CDSP
import XCTest

@testable import MyEqCore

final class MeterTests: XCTestCase {
  func testStereoPeaksRetainTransientsUntilConsumed() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    meq_set_metering_enabled(dsp, true)
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
    meq_set_metering_enabled(dsp, true)
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

  func testMeterVisibilityNeverChangesAudioOrHealthCounters() {
    let reference = meq_create()!
    let toggled = meq_create()!
    defer {
      meq_destroy(reference)
      meq_destroy(toggled)
    }
    var bands = EQPreset.botaniq.bands.map(\.native)
    for dsp in [reference, toggled] {
      XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    }
    meq_set_metering_enabled(reference, true)
    for block in 0..<80 {
      let visible = (block / 7) % 2 != 0
      meq_set_metering_enabled(toggled, visible)
      if block == 40 {
        bands[0].gain = 12
        for dsp in [reference, toggled] { XCTAssertTrue(meq_submit(dsp, bands, 8, -3)) }
      }
      var expected = (0..<512).map { Float(2 * sin(Double(block * 512 + $0) * 0.17)) }
      if block == 30 { expected[0] = .nan }
      var actual = expected
      meq_process(reference, &expected, 256)
      meq_process(toggled, &actual, 256)
      XCTAssertEqual(actual, expected, "Meter visibility changed audio in block \(block)")
      let health = meq_meter(toggled)
      XCTAssertEqual(health.callbacks, UInt64(block + 1))
      XCTAssertEqual(health.faults, meq_meter(reference).faults)
      if !visible {
        XCTAssertEqual(health.peakLeft, 0)
        XCTAssertEqual(health.peakRight, 0)
        XCTAssertEqual(health.reduction, 0)
      }
    }
    XCTAssertGreaterThan(meq_meter(toggled).faults, 0)
  }

  func testResumeDiscardsHiddenAndPreviousVisiblePeaks() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    func pulse(_ amplitude: Float) {
      var samples = [Float](repeating: 0, count: 256)
      samples[0] = amplitude
      samples[1] = amplitude / 2
      meq_process(dsp, &samples, 128)
    }
    pulse(0.75)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0, "Visual metering must default off")
    meq_set_metering_enabled(dsp, true)
    pulse(0.5)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0.5)
    meq_set_metering_enabled(dsp, false)
    pulse(0.75)
    XCTAssertEqual(meq_take_meter(dsp).peakLeft, 0)
    meq_set_metering_enabled(dsp, true)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0)
    pulse(0.125)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0.125)
    XCTAssertEqual(meq_meter(dsp).peakRight, 0.0625)
    // Even an entire hide/show cycle between two callbacks starts a fresh interval.
    meq_set_metering_enabled(dsp, false)
    meq_set_metering_enabled(dsp, true)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0)
    pulse(0.0625)
    XCTAssertEqual(meq_take_meter(dsp).peakLeft, 0.0625)
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
    meter.update(OutputLevels(active: true), elapsed: 20)
    XCTAssertEqual(meter.leftDB, OutputMeterEnvelope.floorDB)
    XCTAssertEqual(meter.rightDB, OutputMeterEnvelope.floorDB)
    XCTAssertEqual(meter.leftPeakDB, OutputMeterEnvelope.floorDB)
    XCTAssertEqual(meter.rightPeakDB, OutputMeterEnvelope.floorDB)
  }

  func testPeakHoldsThenFallsUsingOnlyTimeAfterHoldExpires() {
    var meter = OutputMeterEnvelope()
    meter.update(OutputLevels(left: 0.5, right: 0.125, active: true), elapsed: 0)
    let leftPeak = meter.leftPeakDB
    let rightPeak = meter.rightPeakDB

    meter.update(OutputLevels(active: true), elapsed: 0.75)
    XCTAssertEqual(meter.leftPeakDB, leftPeak)
    XCTAssertEqual(meter.rightPeakDB, rightPeak)
    XCTAssertEqual(meter.leftDB, leftPeak - 18, accuracy: 1e-6)

    meter.update(OutputLevels(active: true), elapsed: 0.5)
    XCTAssertEqual(meter.leftPeakDB, leftPeak - 1.5, accuracy: 1e-6)
    XCTAssertEqual(meter.rightPeakDB, rightPeak - 1.5, accuracy: 1e-6)
    meter.update(OutputLevels(active: true), elapsed: 0.25)
    XCTAssertEqual(meter.leftPeakDB, leftPeak - 3, accuracy: 1e-6)
    XCTAssertGreaterThan(meter.leftPeakDB, meter.leftDB)
    XCTAssertGreaterThan(meter.rightPeakDB, meter.rightDB)
  }

  func testNewPeaksRestartEachChannelHoldIndependently() {
    var meter = OutputMeterEnvelope()
    meter.update(OutputLevels(left: 0.25, right: 0.5, active: true), elapsed: 0)
    let halfAmplitudeDB = meter.rightPeakDB
    meter.update(OutputLevels(active: true), elapsed: 0.75)
    meter.update(OutputLevels(left: 0.5, active: true), elapsed: 0.25)
    meter.update(OutputLevels(active: true), elapsed: 0.5)
    XCTAssertEqual(meter.leftPeakDB, halfAmplitudeDB, accuracy: 1e-6)
    XCTAssertEqual(meter.rightPeakDB, halfAmplitudeDB - 3, accuracy: 1e-6)

    meter.update(OutputLevels(right: 1, active: true), elapsed: 0.5)
    meter.update(OutputLevels(active: true), elapsed: 0.25)
    XCTAssertEqual(meter.leftPeakDB, halfAmplitudeDB - 1.5, accuracy: 1e-6)
    XCTAssertEqual(meter.rightPeakDB, 0)
  }

  func testPeakDecayIsFrameRateIndependentAndIgnoresInvalidElapsedTime() {
    var sixty = OutputMeterEnvelope()
    sixty.update(OutputLevels(left: 0.5, right: 0.125, active: true), elapsed: 0)
    var thirty = sixty
    var delayed = sixty
    let leftPeak = sixty.leftPeakDB
    let rightPeak = sixty.rightPeakDB
    for _ in 0..<180 { sixty.update(OutputLevels(active: true), elapsed: 1 / 60) }
    for _ in 0..<90 { thirty.update(OutputLevels(active: true), elapsed: 1 / 30) }
    delayed.update(OutputLevels(active: true), elapsed: 3)
    for meter in [sixty, thirty, delayed] {
      XCTAssertEqual(meter.leftPeakDB, leftPeak - 12, accuracy: 1e-6)
      XCTAssertEqual(meter.rightPeakDB, rightPeak - 12, accuracy: 1e-6)
    }
    let before = delayed
    for elapsed in [-1.0, .nan, .infinity] {
      delayed.update(OutputLevels(active: true), elapsed: elapsed)
      XCTAssertEqual(delayed, before)
    }
  }
}
