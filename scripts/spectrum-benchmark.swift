// Synthetic/offscreen only: no hardware audio, installed app, routing, or saved preferences.
import AppKit
import CDSP
import Darwin
import Foundation

@main
struct SpectrumBenchmark {
  static func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
  }

  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let duration = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
    if CommandLine.arguments.contains("--render-only") {
      benchmarkRendering(duration: duration)
      return
    }
    let dsp = meq_create()!
    let bands = (0..<8).map { index in
      MEQBand(
        type: 0, enabled: true, frequency: 60 * pow(2, Double(index)),
        gain: index % 2 == 0 ? 4 : -4, width: 0.3)
    }
    precondition(meq_prepare(dsp, 48000, bands, 8, -12))
    let reader = meq_spectrum_reader_create(dsp)!
    let worker = DispatchQueue(label: "benchmark.spectrum", qos: .utility)
    let monitor = InputSpectrumMonitor(queue: worker)
    monitor.setDSP(dsp)
    let model = InputSpectrumModel()
    let view = SpectrumLayerView()
    view.frame = CGRect(x: 0, y: 0, width: 1080, height: 198)
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    var deliveries = 0
    monitor.deliver = { frame in
      if frame != nil { deliveries += 1 }
      model.update(frame)
    }
    let audioQueue = DispatchQueue(label: "benchmark.synthetic-audio", qos: .userInteractive)
    let audio = DispatchSource.makeTimerSource(queue: audioQueue)
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 2)
    var position = 0
    audio.setEventHandler {
      for index in 0..<512 {
        let t = Double(position + index) / 48000
        let value = Float(
          0.17 * sin(2 * .pi * 80 * t) + 0.11 * sin(2 * .pi * 996 * t)
            + 0.04 * sin(2 * .pi * 7500 * t))
        samples[index * 2] = value
        samples[index * 2 + 1] = -value * 0.8
      }
      position += 512
      meq_process(dsp, samples, 512)
    }
    audio.schedule(
      deadline: .now(), repeating: .nanoseconds(10_666_667), leeway: .microseconds(100))
    audio.resume()
    for (mode, visible, reduced) in [
      ("spectrum_off", false, false), ("visible_30hz", true, false),
      ("reduced_motion_10hz", true, true), ("hidden", false, false),
    ] {
      view.bind(model, visible: visible, reducedMotion: reduced)
      monitor.configure(visible: visible, reducedMotion: reduced)
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      let stats = meq_spectrum_stats(reader)
      let count = deliveries
      let cpu = cpuTime()
      let start = ProcessInfo.processInfo.systemUptime
      RunLoop.main.run(until: Date().addingTimeInterval(duration))
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      let cpuPercent = (cpuTime() - cpu) / elapsed * 100
      let end = meq_spectrum_stats(reader)
      print(
        "{\"mode\":\"\(mode)\",\"seconds\":\(elapsed),\"cpu_percent_one_core\":\(cpuPercent),"
          + "\"captured_blocks\":\(end.capturedBlocks - stats.capturedBlocks),"
          + "\"snapshots\":\(end.published - stats.published),"
          + "\"delivered\":\(deliveries - count),\"dropped\":\(end.dropped - stats.dropped)}")
      if !visible {
        precondition(end.capturedBlocks == stats.capturedBlocks && deliveries == count)
      }
    }
    audio.cancel()
    audioQueue.sync {}
    monitor.shutdown()
    worker.sync {}
    view.disconnect()
    window.contentView = nil
    window.close()
    meq_spectrum_reader_destroy(reader)
    meq_destroy(dsp)
    samples.deallocate()
  }

  @MainActor
  static func benchmarkRendering(duration: Double) {
    let model = InputSpectrumModel()
    let view = SpectrumLayerView()
    view.frame = CGRect(x: 0, y: 0, width: 1080, height: 198)
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.bind(model, visible: true, reducedMotion: false)
    var delivered = 0
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
      MainActor.assumeIsolated {
        let phase = Double(delivered) / 30
        let levels = (0..<SpectrumFrame.pointCount).map { index -> Float in
          let x = Double(index) / Double(SpectrumFrame.pointCount - 1)
          return Float(-45 + 20 * sin(x * 12 + phase * 2) + 12 * cos(x * 31 - phase))
        }
        model.update(
          SpectrumFrame(
            levels: levels, sampleRate: 48000,
            timestamp: ProcessInfo.processInfo.systemUptime))
        delivered += 1
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let count = delivered
    let cpu = cpuTime()
    let start = ProcessInfo.processInfo.systemUptime
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    print(
      "{\"mode\":\"render_only_30hz\",\"points\":\(SpectrumFrame.pointCount),"
        + "\"seconds\":\(elapsed),\"cpu_percent_one_core\":\((cpuTime() - cpu) / elapsed * 100),"
        + "\"delivered\":\(delivered - count)}")
    timer.invalidate()
    view.disconnect()
    window.contentView = nil
    window.close()
  }
}
