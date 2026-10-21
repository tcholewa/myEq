import AudioToolbox
import CDSP
import CoreAudio
import Foundation

struct AudioFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum HAL {
  static let system = AudioObjectID(kAudioObjectSystemObject)
  static func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
  static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
      throw AudioFailure(
        message:
          "\(operation) failed (Core Audio \(status)). Check the selected output and driver installation, then Retry."
      )
    }
  }
  static func scalar<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws -> T {
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    var property = address(selector, scope)
    try check(
      AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "Reading audio device")
    return value
  }
  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws
    -> String
  {
    var property = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var result: Unmanaged<CFString>?
    try check(
      AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result), "Reading audio name")
    return result?.takeRetainedValue() as String? ?? "Unknown output"
  }
  static func ids(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws -> [AudioObjectID] {
    var property = address(selector, scope)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Reading audio list size")
    guard size > 0 else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try values.withUnsafeMutableBytes { p in
      try check(
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, p.baseAddress!),
        "Reading audio list")
    }
    return values
  }
  static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size),
      "Reading stream configuration")
    guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    try check(
      AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw), "Reading stream channels")
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
      .map { Int($0.mNumberChannels) }
  }
  static func headsetInputActive(output: AudioObjectID, uid: String) -> Bool {
    let processes = (try? ids(system, kAudioHardwarePropertyProcessObjectList)) ?? []
    for process in processes {
      let pid = try? scalar(process, kAudioProcessPropertyPID, pid_t(0))
      guard pid != getpid(),
        (try? scalar(process, kAudioProcessPropertyIsRunningInput, UInt32(0))) == 1
      else { continue }
      for input
        in (try? ids(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
        ?? []
      {
        if input == output || (try? string(input, kAudioDevicePropertyDeviceUID)) == uid {
          return true
        }
      }
    }
    return false
  }
  static func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
    try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
  }
  static func supportedPCM(_ format: AudioStreamBasicDescription) -> Bool {
    format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
      && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
      && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
  }
}

public struct RoutePolicy {
  public static func suspension(
    isBluetooth: Bool, microphoneActive: Bool, channels: Int, sampleRate: Double,
    supportedTransport: Bool, supportedFormat: Bool
  ) -> String? {
    if isBluetooth && (microphoneActive || channels != 2 || sampleRate < 32000) {
      return "Bluetooth headset microphone is in use. EQ will resume when stereo playback returns."
    }
    if !supportedTransport {
      return
        "This output is not supported. Choose built-in, wired, USB/HDMI, or Bluetooth stereo audio in macOS."
    }
    if channels != 2 {
      return
        "Choose a stereo output configuration in Audio MIDI Setup. Surround and multi-output devices are not supported."
    }
    if !supportedFormat || !sampleRate.isFinite || !(32000...192000).contains(sampleRate) {
      return "This audio format is not supported. Choose 32–192 kHz stereo PCM in Audio MIDI Setup."
    }
    return nil
  }
}

struct OutputRoute: Equatable {
  let id: AudioObjectID
  let uid: String
  let name: String
  let rate: Double
  let channels: [Int]
  let bufferFrames: UInt32
  let transport: UInt32
  let supportedFormat: Bool
  var bluetooth: Bool {
    [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport)
  }
  static func current() throws -> OutputRoute? {
    try read(HAL.scalar(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)))
  }
  static func read(_ id: AudioObjectID) throws -> OutputRoute? {
    guard id != 0 else { return nil }
    let streams = try HAL.ids(
      id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    let formats = try streams.map { try HAL.format($0) }
    return try OutputRoute(
      id: id, uid: HAL.string(id, kAudioDevicePropertyDeviceUID),
      name: HAL.string(id, kAudioObjectPropertyName),
      rate: HAL.scalar(id, kAudioDevicePropertyNominalSampleRate, Double(0)),
      channels: HAL.channels(id, scope: kAudioObjectPropertyScopeOutput),
      bufferFrames: HAL.scalar(id, kAudioDevicePropertyBufferFrameSize, UInt32(0)),
      transport: HAL.scalar(id, kAudioDevicePropertyTransportType, UInt32(0)),
      supportedFormat: formats.count == 1
        && formats.allSatisfy { HAL.supportedPCM($0) && $0.mChannelsPerFrame == 2 })
  }
  var physical: Bool {
    [
      kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt,
      kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeBluetooth,
      kAudioDeviceTransportTypeBluetoothLE,
    ].contains(transport)
  }
  static func all() -> [OutputRoute] {
    ((try? HAL.ids(HAL.system, kAudioHardwarePropertyDevices)) ?? []).compactMap { try? read($0) }
      .filter { $0.physical && !$0.channels.isEmpty }
  }
  var suspension: String? {
    return RoutePolicy.suspension(
      isBluetooth: bluetooth,
      microphoneActive: bluetooth && HAL.headsetInputActive(output: id, uid: uid),
      channels: channels.reduce(0, +), sampleRate: rate, supportedTransport: physical,
      supportedFormat: supportedFormat)
  }
}
