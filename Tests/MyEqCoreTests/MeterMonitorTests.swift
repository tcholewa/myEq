import CDSP
import XCTest

@testable import MyEqCore

final class MeterMonitorTests: XCTestCase {
  @MainActor
  func testPollingFollowsVisibilityAndSessionLifetime() async {
    let queue = DispatchQueue(label: "test.meter-monitor")
    let dsp = meq_create()!
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    var receive: (OutputLevels) -> Void = { _ in }
    let monitor = OutputMeterMonitor(queue: queue) { receive($0) }
    defer {
      queue.sync { monitor.shutdown() }
      meq_destroy(dsp)
    }
    func pulse() {
      var samples = [Float](repeating: 0, count: 256)
      samples[0] = 0.5
      meq_process(dsp, &samples, 128)
    }

    let hidden = expectation(description: "No deliveries while initially hidden")
    hidden.isInverted = true
    receive = { _ in hidden.fulfill() }
    queue.sync {
      monitor.setDSP(dsp)
      pulse()
    }
    await fulfillment(of: [hidden], timeout: 0.1)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0)
    XCTAssertEqual(meq_meter(dsp).callbacks, 1)

    let visible = expectation(description: "Visible meter receives fresh audio")
    receive = { if $0.active && $0.left == 0.5 { visible.fulfill() } }
    queue.sync {
      monitor.setVisible(true)
      pulse()
    }
    await fulfillment(of: [visible], timeout: 1)

    let hiddenAgain = expectation(description: "Hiding stops deliveries")
    hiddenAgain.isInverted = true
    receive = { _ in hiddenAgain.fulfill() }
    queue.sync {
      monitor.setVisible(false)
      pulse()
    }
    await fulfillment(of: [hiddenAgain], timeout: 0.1)
    XCTAssertEqual(meq_meter(dsp).peakLeft, 0)

    let resumed = expectation(description: "Reopening resumes without hidden peaks")
    var didResume = false
    receive = {
      if $0.active && !didResume {
        didResume = true
        XCTAssertEqual($0.left, 0)
        resumed.fulfill()
      }
    }
    queue.sync { monitor.setVisible(true) }
    await fulfillment(of: [resumed], timeout: 1)

    let detached = expectation(description: "Stopping audio clears the visible meter")
    receive = { if !$0.active { detached.fulfill() } }
    queue.sync { monitor.setDSP(nil) }
    await fulfillment(of: [detached], timeout: 1)
    let noSession = expectation(description: "No polling after session detaches")
    noSession.isInverted = true
    receive = { _ in noSession.fulfill() }
    await fulfillment(of: [noSession], timeout: 0.1)
  }

  @MainActor
  func testHidingInvalidatesAlreadyQueuedMainThreadDeliveries() async {
    let queue = DispatchQueue(label: "test.meter-delivery")
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    let obsolete = expectation(description: "Old visible samples must not arrive after hiding")
    obsolete.isInverted = true
    let monitor = OutputMeterMonitor(queue: queue) { _ in obsolete.fulfill() }
    defer { queue.sync { monitor.shutdown() } }
    queue.sync {
      monitor.setDSP(dsp)
      monitor.setVisible(true)
      var samples = [Float](repeating: 0.25, count: 256)
      meq_process(dsp, &samples, 128)
    }
    // Keep the main queue occupied while the real timer enqueues updates, then
    // hide before allowing those deliveries to execute.
    let hidden = DispatchSemaphore(value: 0)
    let hide = DispatchWorkItem {
      XCTAssertEqual(meq_meter(dsp).peakLeft, 0, "The timer must have consumed the pulse")
      monitor.setVisible(false)
      hidden.signal()
    }
    queue.asyncAfter(deadline: .now() + 0.1, execute: hide)
    XCTAssertEqual(hidden.wait(timeout: .now() + 1), .success)
    await fulfillment(of: [obsolete], timeout: 0.1)
  }
}
