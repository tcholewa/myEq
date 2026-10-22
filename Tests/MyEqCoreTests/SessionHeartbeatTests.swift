import XCTest

@testable import MyEqCore

final class SessionHeartbeatTests: XCTestCase {
  func testRenewalContinuesWhileControlQueueIsStalled() {
    let renewals = expectation(description: "Independent renewals")
    renewals.expectedFulfillmentCount = 9
    let gate = DispatchSemaphore(value: 0)
    let entered = expectation(description: "HAL-like control work blocked")
    let control = DispatchQueue(label: "test.blocked-control")
    control.async {
      entered.fulfill()
      gate.wait()
    }
    defer { gate.signal() }
    wait(for: [entered], timeout: 2)
    let count = LockedCount()
    let heartbeat = SessionHeartbeat {
      if count.increment() <= 9 { renewals.fulfill() }
      return .success(1)
    }
    defer { heartbeat.stop() }
    // More than the existing 1.5-second lease watchdog interval passes with control blocked.
    wait(for: [renewals], timeout: 5)
    XCTAssertEqual(try heartbeat.read(), 1)
  }

  func testReadIsNonblockingAndStopDrainsAnInflightRequest() {
    let entered = expectation(description: "Request started")
    let stopStarted = expectation(description: "Stop started")
    let stopFinished = expectation(description: "Stop drained")
    let gate = DispatchSemaphore(value: 0)
    let finished = LockedCount()
    let heartbeat = SessionHeartbeat {
      entered.fulfill()
      gate.wait()
      return .success(1)
    }
    wait(for: [entered], timeout: 2)
    XCTAssertEqual(try heartbeat.read(), 1)  // Reads do not await XPC or acquire its queue.
    DispatchQueue.global().async {
      stopStarted.fulfill()
      heartbeat.stop()
      finished.increment()
      stopFinished.fulfill()
    }
    wait(for: [stopStarted], timeout: 2)
    XCTAssertEqual(finished.value, 0)
    gate.signal()
    wait(for: [stopFinished], timeout: 2)
    heartbeat.stop()  // Repeated teardown is safe.
  }

  func testFailuresAndManualBypassRemainLatched() {
    for health in [
      Result<Int, AudioFailure>.success(2), .success(3),
      .failure(AudioFailure(message: "timeout", retryableConnection: true)),
      .failure(AudioFailure(message: "signature mismatch")),
    ] {
      let entered = expectation(description: "Health result produced")
      let unexpectedPoll = expectation(description: "Unhealthy result stays latched")
      unexpectedPoll.isInverted = true
      let calls = LockedCount()
      let heartbeat = SessionHeartbeat {
        if calls.increment() == 1 { entered.fulfill() } else { unexpectedPoll.fulfill() }
        return health
      }
      wait(for: [entered], timeout: 2)
      wait(for: [unexpectedPoll], timeout: 0.4)
      heartbeat.stop()  // Joins the handler so its result has been published.
      XCTAssertEqual(calls.value, 1)
      for _ in 0..<3 {
        switch health {
        case .success(let expected): XCTAssertEqual(try heartbeat.read(), expected)
        case .failure(let expected):
          XCTAssertThrowsError(try heartbeat.read()) { error in
            XCTAssertEqual(
              (error as? AudioFailure)?.retryableConnection, expected.retryableConnection)
          }
        }
      }
    }
  }
}

private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  @discardableResult func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
