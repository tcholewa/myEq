import XCTest

@testable import MyEqCore

final class RouteTests: XCTestCase {
  func testStereoRoutesAndCallSuspension() {
    XCTAssertNil(
      RoutePolicy.suspension(
        isBluetooth: false, microphoneActive: false, channels: 2, sampleRate: 48000,
        supportedTransport: true, supportedFormat: true))
    XCTAssertNil(
      RoutePolicy.suspension(
        isBluetooth: true, microphoneActive: false, channels: 2, sampleRate: 44100,
        supportedTransport: true, supportedFormat: true))
    XCTAssertNotNil(
      RoutePolicy.suspension(
        isBluetooth: true, microphoneActive: true, channels: 2, sampleRate: 48000,
        supportedTransport: true, supportedFormat: true))
    XCTAssertNotNil(
      RoutePolicy.suspension(
        isBluetooth: true, microphoneActive: false, channels: 1, sampleRate: 16000,
        supportedTransport: true, supportedFormat: true))
  }
  func testUnsupportedRoutesNeverCapture() {
    XCTAssertNotNil(
      RoutePolicy.suspension(
        isBluetooth: false, microphoneActive: false, channels: 8, sampleRate: 48000,
        supportedTransport: true, supportedFormat: true))
    XCTAssertNotNil(
      RoutePolicy.suspension(
        isBluetooth: false, microphoneActive: false, channels: 2, sampleRate: 48000,
        supportedTransport: false, supportedFormat: true))
    XCTAssertNotNil(
      RoutePolicy.suspension(
        isBluetooth: false, microphoneActive: false, channels: 2, sampleRate: 48000,
        supportedTransport: true, supportedFormat: false))
    XCTAssertNotNil(
      RoutePolicy.suspension(
        isBluetooth: false, microphoneActive: false, channels: 2, sampleRate: .nan,
        supportedTransport: true, supportedFormat: true))
  }
  func testExternalRouteBypassResumesWhenTargetReturns() {
    var bypass = ExternalRouteBypass()
    XCTAssertFalse(bypass.isActive)
    XCTAssertFalse(bypass.shouldResume(systemDefaultUID: "adam", availableUIDs: ["adam", "bt"]))

    bypass.engage(targetUID: "adam")
    XCTAssertTrue(bypass.isActive)
    XCTAssertEqual(bypass.targetUID, "adam")
    // Stay bypassed while macOS routes to Bluetooth, another device, or an absent target.
    XCTAssertFalse(bypass.shouldResume(systemDefaultUID: "bt", availableUIDs: ["adam", "bt"]))
    XCTAssertFalse(bypass.shouldResume(systemDefaultUID: nil, availableUIDs: ["adam", "bt"]))
    XCTAssertFalse(bypass.shouldResume(systemDefaultUID: "adam", availableUIDs: ["bt"]))
    XCTAssertTrue(bypass.isActive)

    // Resume automatically once macOS returns default output to the target device.
    XCTAssertTrue(bypass.shouldResume(systemDefaultUID: "adam", availableUIDs: ["adam", "bt"]))
    XCTAssertFalse(bypass.isActive)
    XCTAssertNil(bypass.targetUID)

    // Explicit clear (e.g. manual off or output selection in myEq) prevents auto-resume.
    bypass.engage(targetUID: "adam")
    bypass.clear()
    XCTAssertFalse(bypass.isActive)
    XCTAssertFalse(bypass.shouldResume(systemDefaultUID: "adam", availableUIDs: ["adam", "bt"]))
  }
}
