import Foundation

/// Renews an authenticated session independently of potentially blocking HAL discovery.
/// This queue never runs audio IO; stop drains it before the connection is destroyed.
final class SessionHeartbeat {
  private let queue = DispatchQueue(label: "com.tc.myEq.session-heartbeat", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<Bool>()
  private let lock = NSLock()
  private var result: Result<Int, AudioFailure> = .success(1)
  private var timer: DispatchSourceTimer?

  init(poll: @escaping () -> Result<Int, AudioFailure>) {
    queue.setSpecific(key: queueKey, value: true)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    self.timer = timer
    timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
    timer.setEventHandler { [weak self] in
      guard let self, self.timer != nil else { return }
      let next = poll()
      self.lock.lock()
      self.result = next
      self.lock.unlock()
      // Latch failure/manual bypass/disconnection until the engine consumes it.
      if case .success(1) = next { return }
      self.timer?.cancel()
      self.timer = nil
    }
    timer.resume()
  }

  deinit { stop() }

  func read() throws -> Int {
    lock.lock()
    let current = result
    lock.unlock()
    return try current.get()
  }

  func stop() {
    let cancel = {
      self.timer?.cancel()
      self.timer = nil
    }
    if DispatchQueue.getSpecific(key: queueKey) == true {
      cancel()
    } else {
      queue.sync(execute: cancel)
    }
  }
}
