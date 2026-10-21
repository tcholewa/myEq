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
}
