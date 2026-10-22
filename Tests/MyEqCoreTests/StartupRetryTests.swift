import XCTest

@testable import MyEqCore

final class StartupRetryTests: XCTestCase {
  private let transient = AudioFailure(message: "Helper is starting", retryableConnection: true)

  func testColdStartBackoffIsBoundedAndDoesNotSpinOnHealthTicks() {
    var retry = StartupRetry()
    var time = 100.0
    XCTAssertTrue(retry.isReady(at: time))
    for delay in [0.25, 0.5, 1.0, 2.0] {
      XCTAssertTrue(retry.schedule(for: transient, at: time))
      XCTAssertFalse(retry.isReady(at: time))
      XCTAssertFalse(retry.isReady(at: time + delay - 0.001))
      time += delay
      XCTAssertTrue(retry.isReady(at: time))
    }
    XCTAssertFalse(retry.schedule(for: transient, at: time))
    XCTAssertFalse(retry.schedule(for: transient, at: time + 60))
  }

  func testExplicitResetCancelsPendingDelayAndRestoresBudget() {
    var retry = StartupRetry()
    for _ in 0..<4 { XCTAssertTrue(retry.schedule(for: transient, at: 100)) }
    retry.reset()
    XCTAssertTrue(retry.isReady(at: 100))
    XCTAssertTrue(retry.schedule(for: transient, at: 100))
    XCTAssertTrue(retry.isReady(at: 100.25))
  }

  func testPermanentErrorsDoNotRetryOrConsumeTransientBudget() {
    var retry = StartupRetry()
    XCTAssertFalse(retry.schedule(for: AudioFailure(message: "Signature mismatch"), at: 100))
    XCTAssertFalse(retry.schedule(for: NSError(domain: "HAL", code: 1), at: 100))
    XCTAssertTrue(retry.isReady(at: 100))
    XCTAssertTrue(retry.schedule(for: transient, at: 100))
    XCTAssertTrue(retry.isReady(at: 100.25))
  }
  func testShortLivedReconnectsDoNotResetBudget() {
    var retry = StartupRetry()
    for attempt in 0..<4 {
      let time = Double(attempt * 10)
      XCTAssertTrue(retry.schedule(for: transient, at: time))
      retry.healthy(at: time + 2)
      retry.healthy(at: time + 5)
    }
    XCTAssertFalse(retry.schedule(for: transient, at: 40))
  }
  func testThirtyHealthySecondsRestoreBudget() {
    var retry = StartupRetry()
    for _ in 0..<4 { XCTAssertTrue(retry.schedule(for: transient, at: 0)) }
    retry.healthy(at: 10)
    retry.healthy(at: 39.999)
    XCTAssertFalse(retry.schedule(for: transient, at: 39.999))
    retry.healthy(at: 40)
    XCTAssertTrue(retry.schedule(for: transient, at: 41))
  }
  func testConsoleOwnershipDoesNotDependOnLockOrVisibility() {
    for _ in 0..<10 {
      XCTAssertTrue(
        LoginEligibility.allows(uid: 501, onConsole: true, loginDone: true, ownUID: 501))
    }
    XCTAssertFalse(LoginEligibility.allows(uid: 502, onConsole: true, loginDone: true, ownUID: 501))
    XCTAssertFalse(
      LoginEligibility.allows(uid: 501, onConsole: false, loginDone: true, ownUID: 501))
    XCTAssertFalse(
      LoginEligibility.allows(uid: 501, onConsole: true, loginDone: false, ownUID: 501))
    XCTAssertFalse(LoginEligibility.allows(uid: nil, onConsole: nil, loginDone: nil, ownUID: 501))
  }

  func testSuspendedTimeDoesNotCountAsHealthyPlayback() {
    var retry = StartupRetry()
    for _ in 0..<4 { XCTAssertTrue(retry.schedule(for: transient, at: 0)) }
    retry.healthy(at: 5)
    retry.interrupted()
    retry.healthy(at: 100)
    XCTAssertFalse(retry.schedule(for: transient, at: 101))
    retry.healthy(at: 130)
    XCTAssertTrue(retry.schedule(for: transient, at: 131))
  }

}
