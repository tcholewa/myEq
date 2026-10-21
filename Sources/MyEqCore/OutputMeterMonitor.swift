import CDSP
import Foundation

/// Owned by the audio control queue. No timer wakes or visual DSP work while hidden.
final class OutputMeterMonitor {
  private let timer: DispatchSourceTimer
  private let deliver: (OutputLevels) -> Void
  private var dsp: OpaquePointer?
  private var visible = false
  private var stopped = false
  // Only delivery validation crosses queues; this lock is never used by audio IO.
  private let deliveryLock = NSLock()
  private var generation: UInt64 = 0

  init(queue: DispatchQueue, deliver: @escaping (OutputLevels) -> Void) {
    self.deliver = deliver
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .distantFuture)
    timer.setEventHandler { [weak self] in self?.poll() }
    timer.resume()
  }

  deinit { timer.cancel() }

  func setVisible(_ visible: Bool) {
    guard !stopped, self.visible != visible else { return }
    self.visible = visible
    restart()
  }

  /// Detach before destroying the DSP. Switching devices invalidates queued UI data.
  func setDSP(_ dsp: OpaquePointer?) {
    guard !stopped, self.dsp != dsp else { return }
    if let old = self.dsp { meq_set_metering_enabled(old, false) }
    self.dsp = dsp
    restart()
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    if let dsp { meq_set_metering_enabled(dsp, false) }
    dsp = nil
    invalidateDelivery()
    timer.cancel()
  }

  private func restart() {
    timer.schedule(deadline: .distantFuture)
    invalidateDelivery()
    if let dsp { meq_set_metering_enabled(dsp, visible) }
    guard visible else { return }
    enqueue(OutputLevels())
    if dsp != nil {
      timer.schedule(
        deadline: .now() + .nanoseconds(16_666_667), repeating: .nanoseconds(16_666_667),
        leeway: .milliseconds(2))
    }
  }

  private func poll() {
    guard !stopped, visible, let dsp else { return }
    let meter = meq_take_meter(dsp)
    enqueue(
      OutputLevels(
        left: meter.peakLeft, right: meter.peakRight, reduction: meter.reduction, active: true))
  }

  private func invalidateDelivery() {
    deliveryLock.lock()
    generation &+= 1
    deliveryLock.unlock()
  }

  private func enqueue(_ levels: OutputLevels) {
    deliveryLock.lock()
    let token = generation
    deliveryLock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.deliveryLock.lock()
      let current = self.generation == token
      self.deliveryLock.unlock()
      guard current else { return }
      self.deliver(levels)
    }
  }
}
