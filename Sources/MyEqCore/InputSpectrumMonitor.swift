import CDSP
import Foundation

private final class SpectrumSource {
  let reader: OpaquePointer
  let format: MEQSpectrumSnapshot
  init?(_ dsp: OpaquePointer) {
    guard let reader = meq_spectrum_reader_create(dsp) else { return nil }
    self.reader = reader
    format = meq_spectrum_format(reader)
  }
  deinit { meq_spectrum_reader_destroy(reader) }
}

/// Configuration is thread-safe. Utility work never holds the configuration lock or joins audio control.
final class InputSpectrumMonitor {
  var deliver: ((SpectrumFrame?) -> Void)?  // Set before use; invoked only on main.
  private let queue: DispatchQueue
  private let timer: DispatchSourceTimer
  private let lock = NSLock()
  private var source: SpectrumSource?
  private var attachedDSP: OpaquePointer?
  private var visible = false
  private var reducedMotion = false
  private var stopped = false
  private var generation: UInt64 = 0
  private var pending: (UInt64, SpectrumFrame?)?
  private var deliveryQueued = false
  // Utility queue only, with independent ownership of native capture storage.
  private var workerSource: SpectrumSource?
  private var workerGeneration: UInt64 = 0
  private var analyzer: SpectrumAnalyzer?
  private var envelope = SpectrumEnvelope()
  private var lastTimestamp: TimeInterval?

  init(queue: DispatchQueue = DispatchQueue(label: "com.tc.myEq.spectrum", qos: .utility)) {
    self.queue = queue
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .distantFuture)
    timer.setEventHandler { [weak self] in self?.poll() }
    timer.resume()
  }
  deinit {
    if let source { meq_spectrum_set_enabled(source.reader, false) }
    timer.cancel()
  }

  func setDSP(_ dsp: OpaquePointer?) {
    lock.lock()
    guard !stopped, dsp != attachedDSP else {
      lock.unlock()
      return
    }
    if let source { meq_spectrum_set_enabled(source.reader, false) }
    source = dsp.flatMap(SpectrumSource.init)
    attachedDSP = dsp
    reconfigureLocked()
    lock.unlock()
  }

  func configure(visible: Bool, reducedMotion: Bool = false) {
    lock.lock()
    guard !stopped, self.visible != visible || self.reducedMotion != reducedMotion else {
      lock.unlock()
      return
    }
    self.visible = visible
    self.reducedMotion = reducedMotion
    reconfigureLocked()
    lock.unlock()
  }

  func shutdown() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    visible = false
    if let source { meq_spectrum_set_enabled(source.reader, false) }
    source = nil
    attachedDSP = nil
    reconfigureLocked()
    lock.unlock()
  }

  private func reconfigureLocked() {
    generation &+= 1
    pending = nil
    let token = generation
    let source = source
    let visible = visible && !stopped
    let reduced = reducedMotion
    if let source { meq_spectrum_set_enabled(source.reader, visible) }
    queue.async { [weak self] in
      guard let self, self.isCurrent(token) else { return }
      self.timer.schedule(deadline: .distantFuture)
      self.workerSource = visible ? source : nil
      self.workerGeneration = token
      self.envelope = SpectrumEnvelope()
      self.lastTimestamp = nil
      self.analyzer = nil
      self.enqueue(nil, generation: token)
      guard visible, let source,
        let analyzer = SpectrumAnalyzer(
          sampleRate: source.format.sampleRate, frames: Int(source.format.frames))
      else { return }
      guard self.isCurrent(token) else { return }
      self.analyzer = analyzer
      meq_spectrum_request(source.reader)
      let period = reduced ? 100_000_000 : 33_333_333
      self.timer.schedule(
        deadline: .now() + .nanoseconds(period), repeating: .nanoseconds(period),
        leeway: .milliseconds(3))
    }
  }

  private func isCurrent(_ token: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == token
  }

  private func poll() {
    let token = workerGeneration
    guard isCurrent(token), let source = workerSource, let analyzer else { return }
    var info = MEQSpectrumSnapshot()
    if meq_spectrum_take(source.reader, analyzer.samples, UInt32(analyzer.frames), &info) {
      let age = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- info.capturedNS) / 1e9
      if age < 0.25 {
        let timestamp = ProcessInfo.processInfo.systemUptime - age
        let values = analyzer.analyze()
        envelope.update(values, elapsed: lastTimestamp.map { timestamp - $0 } ?? 1.0 / 30)
        lastTimestamp = timestamp
        enqueue(
          SpectrumFrame(
            levels: envelope.levels, sampleRate: info.sampleRate, timestamp: timestamp,
            sequence: info.sequence), generation: token)
      }
    }
    if isCurrent(token) { meq_spectrum_request(source.reader) }
  }

  private func enqueue(_ frame: SpectrumFrame?, generation token: UInt64) {
    lock.lock()
    guard generation == token else {
      lock.unlock()
      return
    }
    pending = (token, frame)
    guard !deliveryQueued else {
      lock.unlock()
      return
    }
    deliveryQueued = true
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let next = self.pending
      self.pending = nil
      self.deliveryQueued = false
      let valid = next?.0 == self.generation
      self.lock.unlock()
      if valid, let next { self.deliver?(next.1) }
    }
  }
}
