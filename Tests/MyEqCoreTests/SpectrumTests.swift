import CDSP
import XCTest

@testable import MyEqCore

final class SpectrumTests: XCTestCase {
  func testCalibratedToneAndOppositePhaseStereo() {
    let analyzer = SpectrumAnalyzer(sampleRate: 48000, frames: 8192)!
    let frequency = 170.0 * 48000 / 8192
    func fill(right: Float) {
      for i in 0..<analyzer.frames {
        let value = Float(0.5 * sin(2 * .pi * frequency * Double(i) / 48000))
        analyzer.samples[2 * i] = value
        analyzer.samples[2 * i + 1] = value * right
      }
    }
    fill(right: 1)
    let stereo = analyzer.analyze()
    XCTAssertEqual(stereo.max()!, -6.0206, accuracy: 0.03)
    let peak = stereo.indices.max { stereo[$0] < stereo[$1] }!
    let plottedHz = 20 * pow(1000, Double(peak) / Double(SpectrumFrame.pointCount - 1))
    XCTAssertEqual(plottedHz, frequency, accuracy: frequency * 0.06)
    fill(right: -1)
    XCTAssertEqual(analyzer.analyze(), stereo, "Power averaging must not cancel opposite phases")
    fill(right: 0)
    XCTAssertEqual(analyzer.analyze().max()!, -9.0309, accuracy: 0.03)
  }

  func testAllRatesSilenceAndInvalidSamples() {
    for rate in [32000.0, 44100, 48000, 96000, 192000] {
      let frames = 1 << max(12, min(15, Int(log2(rate * 0.171).rounded())))
      let analyzer = SpectrumAnalyzer(sampleRate: rate, frames: frames)!
      XCTAssertTrue(analyzer.analyze().allSatisfy { $0 == -90 })
      for i in 0..<frames {
        let value = Float(0.25 * sin(2 * .pi * 31 * Double(i) / Double(frames)))
        analyzer.samples[2 * i] = value
        analyzer.samples[2 * i + 1] = -value
      }
      let values = analyzer.analyze()
      XCTAssertEqual(values.count, 64)
      XCTAssertTrue(values.allSatisfy { $0.isFinite && (-90...0).contains($0) })
      XCTAssertGreaterThan(values.max()!, -16)
      analyzer.samples[0] = .nan
      analyzer.samples[1] = .infinity
      XCTAssertTrue(analyzer.analyze().allSatisfy(\.isFinite))
    }
    XCTAssertNil(SpectrumAnalyzer(sampleRate: .nan, frames: 8192))
    XCTAssertNil(SpectrumAnalyzer(sampleRate: 48000, frames: 7777))
  }

  func testCoarseBandsPreserveNarrowTonesAcrossFrequencyRange() {
    let analyzer = SpectrumAnalyzer(sampleRate: 48000, frames: 8192)!
    let halfBandRatio = pow(1000, 0.5 / Double(SpectrumFrame.pointCount - 1))
    for bin in [5, 13, 39, 170, 511, 1537, 3000] {
      let frequency = Double(bin) * 48000 / Double(analyzer.frames)
      for i in 0..<analyzer.frames {
        let value = Float(0.25 * sin(2 * .pi * Double(bin * i) / Double(analyzer.frames)))
        analyzer.samples[2 * i] = value
        analyzer.samples[2 * i + 1] = value
      }
      let values = analyzer.analyze()
      let peak = values.indices.max { values[$0] < values[$1] }!
      let center = 20 * pow(1000, Double(peak) / Double(SpectrumFrame.pointCount - 1))
      XCTAssertEqual(values[peak], -12.0412, accuracy: 0.03)
      XCTAssertGreaterThanOrEqual(frequency, center / halfBandRatio)
      XCTAssertLessThanOrEqual(frequency, center * halfBandRatio)
    }
  }

  func testEnvelopeUsesElapsedTimeAndFallsToSilence() {
    let loud = [Float](repeating: -12, count: SpectrumFrame.pointCount)
    let silence = [Float](repeating: -90, count: SpectrumFrame.pointCount)
    var fast = SpectrumEnvelope()
    var slow = SpectrumEnvelope()
    for _ in 0..<30 { fast.update(loud, elapsed: 1.0 / 30) }
    for _ in 0..<10 { slow.update(loud, elapsed: 0.1) }
    XCTAssertEqual(fast.levels[0], slow.levels[0], accuracy: 0.001)
    fast.update(silence, elapsed: 0.25)
    XCTAssertLessThan(fast.levels[0], -55)
    for _ in 0..<100 { fast.update(silence, elapsed: 1.0 / 30) }
    XCTAssertEqual(fast.levels[0], -90)
  }

  func testCaptureIsBeforeEQAndReaderOutlivesDSP() {
    let dsp = meq_create()!
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, -24))
    let reader = meq_spectrum_reader_create(dsp)!
    defer { meq_spectrum_reader_destroy(reader) }
    let format = meq_spectrum_format(reader)
    meq_spectrum_set_enabled(reader, true)
    meq_spectrum_request(reader)
    var samples = [Float](repeating: 0.5, count: Int(format.frames) * 2)
    meq_process(dsp, &samples, format.frames)
    XCTAssertLessThan(samples.last!, 0.04)
    meq_destroy(dsp)
    var info = MEQSpectrumSnapshot()
    XCTAssertTrue(meq_spectrum_take(reader, &samples, format.frames, &info))
    XCTAssertTrue(samples.allSatisfy { $0 == 0.5 })
  }

  func testCaptureAndSnapshotPressureNeverChangeAudio() {
    for rate in [32000.0, 44100, 48000, 96000, 192000] {
      let reference = meq_create()!
      let visual = meq_create()!
      let bands = EQPreset.botaniq.bands.map(\.native)
      XCTAssertTrue(meq_prepare(reference, rate, bands, 8, -4.8))
      XCTAssertTrue(meq_prepare(visual, rate, bands, 8, -4.8))
      let reader = meq_spectrum_reader_create(visual)!
      defer {
        meq_spectrum_reader_destroy(reader)
        meq_destroy(visual)
        meq_destroy(reference)
      }
      for block in 0..<240 {
        if block % 120 == 0 { meq_spectrum_set_enabled(reader, (block / 120) % 2 == 0) }
        meq_spectrum_request(reader)  // Leave the consumer stalled to exercise full slots.
        var a = (0..<1024).map { sample in
          Float(1.2 * sin(Double(block * 1024 + sample) * 0.037))
        }
        if block == 59 { a[0] = .nan }
        var b = a
        meq_process(reference, &a, 512)
        meq_process(visual, &b, 512)
        XCTAssertEqual(a, b)
      }
      XCTAssertGreaterThan(meq_spectrum_stats(reader).dropped, 0)
      XCTAssertEqual(meq_meter(reference).faults, meq_meter(visual).faults)
    }
  }

  @MainActor
  func testHiddenCaptureStopsAndStaleDeliveriesAreRejected() async {
    let dsp = meq_create()!
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    let reader = meq_spectrum_reader_create(dsp)!
    let worker = DispatchQueue(label: "test.spectrum.worker")
    let monitor = InputSpectrumMonitor(queue: worker)
    defer {
      monitor.shutdown()
      worker.sync {}
      meq_destroy(dsp)
      meq_spectrum_reader_destroy(reader)
    }
    monitor.setDSP(dsp)
    var samples = [Float](repeating: 0.2, count: 16384)
    meq_process(dsp, &samples, 8192)
    XCTAssertEqual(meq_spectrum_stats(reader).capturedBlocks, 0)
    monitor.configure(visible: true)
    worker.sync {}  // Analyzer prepared and first snapshot requested.
    samples = .init(repeating: 0.2, count: 16384)
    meq_process(dsp, &samples, 8192)
    let frame = expectation(description: "Visible spectrum arrives")
    var received = false
    monitor.deliver = { value in
      if value != nil && !received {
        received = true
        frame.fulfill()
      }
    }
    await fulfillment(of: [frame], timeout: 1)
    monitor.configure(visible: false)
    let count = meq_spectrum_stats(reader).capturedBlocks
    let stale = expectation(description: "No stale frames after hide")
    stale.isInverted = true
    monitor.deliver = { if $0 != nil { stale.fulfill() } }
    for _ in 0..<8 { meq_process(dsp, &samples, 8192) }
    await fulfillment(of: [stale], timeout: 0.15)
    XCTAssertEqual(meq_spectrum_stats(reader).capturedBlocks, count)
  }

  func testDetachDoesNotWaitForBlockedWorker() {
    let dsp = meq_create()!
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    let worker = DispatchQueue(label: "test.spectrum.blocked")
    let gate = DispatchSemaphore(value: 0)
    worker.async { gate.wait() }
    let monitor = InputSpectrumMonitor(queue: worker)
    monitor.setDSP(dsp)
    monitor.configure(visible: true)
    monitor.setDSP(nil)
    meq_destroy(dsp)
    monitor.shutdown()
    gate.signal()
    worker.sync {}
  }

  func testMonitorDestructionDisablesCapture() {
    let dsp = meq_create()!
    XCTAssertTrue(meq_prepare(dsp, 48000, EQPreset.flat.bands.map(\.native), 8, 0))
    let reader = meq_spectrum_reader_create(dsp)!
    defer {
      meq_spectrum_reader_destroy(reader)
      meq_destroy(dsp)
    }
    let worker = DispatchQueue(label: "test.spectrum.destruction")
    var monitor: InputSpectrumMonitor? = InputSpectrumMonitor(queue: worker)
    monitor!.setDSP(dsp)
    monitor!.configure(visible: true)
    worker.sync {}
    monitor = nil
    var samples = [Float](repeating: 0.2, count: 16384)
    meq_process(dsp, &samples, 8192)
    XCTAssertEqual(meq_spectrum_stats(reader).capturedBlocks, 0)
  }
}
