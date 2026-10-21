import XCTest

@testable import MyEqCore

final class StartupRetryTests: XCTestCase {
  private let transient = AudioFailure(message: "Helper is starting", retryableStartup: true)

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

  func testDisableOrSuccessfulStartResetsRetryBudgetAndPendingDelay() {
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
}
