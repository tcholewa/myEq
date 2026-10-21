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
          "\(operation) failed (Core Audio \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording, then Retry."
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
  static func ownProcess() throws -> AudioObjectID {
    var pid = getpid()
    var result: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    try check(
      AudioObjectGetPropertyData(
        system, &property, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &result),
      "Finding myEq audio process")
    guard result != 0 else {
      throw AudioFailure(message: "Core Audio could not identify myEq. Quit and reopen the app.")
    }
    return result
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
  static func hasExternalPlayback(output: AudioObjectID) -> Bool {
    for process in (try? ids(system, kAudioHardwarePropertyProcessObjectList)) ?? [] {
      guard (try? scalar(process, kAudioProcessPropertyPID, pid_t(0))) != getpid(),
        (try? scalar(process, kAudioProcessPropertyIsRunningOutput, UInt32(0))) == 1
      else { continue }
      if ((try? ids(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
        ?? []).contains(output)
      {
        return true
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
  let transport: UInt32
  let supportedFormat: Bool
  var bluetooth: Bool {
    [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport)
  }
  static func current() throws -> OutputRoute? {
    let id = try HAL.scalar(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    guard id != 0 else { return nil }
    let streams = try HAL.ids(
      id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    let formats = try streams.map { try HAL.format($0) }
    return try OutputRoute(
      id: id, uid: HAL.string(id, kAudioDevicePropertyDeviceUID),
      name: HAL.string(id, kAudioObjectPropertyName),
      rate: HAL.scalar(id, kAudioDevicePropertyNominalSampleRate, Double(0)),
      channels: HAL.channels(id, scope: kAudioObjectPropertyScopeOutput),
      transport: HAL.scalar(id, kAudioDevicePropertyTransportType, UInt32(0)),
      supportedFormat: formats.count == 1
        && formats.allSatisfy { HAL.supportedPCM($0) && $0.mChannelsPerFrame == 2 })
  }
  var suspension: String? {
    let supported = [
      kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt,
      kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeBluetooth,
      kAudioDeviceTransportTypeBluetoothLE,
    ].contains(transport)
    return RoutePolicy.suspension(
      isBluetooth: bluetooth,
      microphoneActive: bluetooth && HAL.headsetInputActive(output: id, uid: uid),
      channels: channels.reduce(0, +), sampleRate: rate, supportedTransport: supported,
      supportedFormat: supportedFormat)
  }
}

// All methods run on AudioEngine's serial control queue. C++ alone handles IO.
final class TapSession {
  let dsp = meq_create()!
  private var tap: AudioObjectID = 0
  private var aggregate: AudioObjectID = 0
  private var io: AudioDeviceIOProcID?
  private var started = false
  deinit {
    stop()
    meq_destroy(dsp)
  }

  func start(route: OutputRoute, preset: EQPreset, preamp: Double) throws {
    stop()
    do {
      let native = preset.bands.map(\.native)
      guard meq_prepare(dsp, route.rate, native, Int32(native.count), preamp) else {
        throw AudioFailure(message: "Invalid equalizer configuration.")
      }
      let description = CATapDescription(
        excludingProcesses: [try HAL.ownProcess()], deviceUID: route.uid, stream: 0)
      description.name = "myEq System Mix"
      description.isPrivate = true
      description.muteBehavior = .mutedWhenTapped
      try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Creating system-audio tap")
      let tapFormat = try HAL.scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
      guard HAL.supportedPCM(tapFormat), tapFormat.mChannelsPerFrame == 2 else {
        throw AudioFailure(
          message: "The system mix is not stereo Float32 PCM. Select a stereo output and Retry.")
      }
      let specification: [String: Any] = [
        kAudioAggregateDeviceNameKey: "myEq Private Playback",
        kAudioAggregateDeviceUIDKey: "com.tc.myEq.session.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceMainSubDeviceKey: route.uid,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: route.uid]],
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
        kAudioAggregateDeviceTapAutoStartKey: true,
      ]
      try HAL.check(
        AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate),
        "Creating private playback device")
      var alive = false
      for _ in 0..<100 {
        if (try? HAL.scalar(aggregate, kAudioDevicePropertyDeviceIsAlive, UInt32(0))) == 1 {
          alive = true
          break
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      guard alive else {
        throw AudioFailure(
          message:
            "The audio device did not become ready. Ordinary playback has been restored; try again."
        )
      }
      let inputs = try HAL.channels(aggregate, scope: kAudioObjectPropertyScopeInput)
      let outputs = try HAL.channels(aggregate, scope: kAudioObjectPropertyScopeOutput)
      // The physical device's own input streams precede the appended tap.
      let tapBuffers = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 2 : 1
      let tapStart = inputs.count - tapBuffers
      guard tapStart >= 0, inputs.suffix(tapBuffers).reduce(0, +) == 2, outputs.reduce(0, +) == 2
      else {
        throw AudioFailure(
          message: "The audio stream layout is unsupported. Ordinary playback has been restored.")
      }
      func location(_ channel: Int, in buffers: [Int], startingAt start: Int = 0) -> MEQChannel {
        var remaining = channel
        for i in start..<buffers.count {
          if remaining < buffers[i] {
            return MEQChannel(
              buffer: Int32(i), channel: Int32(remaining), stride: Int32(buffers[i]))
          }
          remaining -= buffers[i]
        }
        return MEQChannel(buffer: -1, channel: 0, stride: 0)
      }
      let preferred =
        (try? HAL.ids(
          route.id, kAudioDevicePropertyPreferredChannelsForStereo,
          scope: kAudioObjectPropertyScopeOutput)) ?? [1, 2]
      guard preferred.count == 2, Set(preferred) == Set([UInt32(1), UInt32(2)]) else {
        throw AudioFailure(message: "The output's preferred stereo channels are unsupported.")
      }
      meq_layout(
        dsp, location(0, in: inputs, startingAt: tapStart),
        location(1, in: inputs, startingAt: tapStart), location(Int(preferred[0]) - 1, in: outputs),
        location(Int(preferred[1]) - 1, in: outputs))
      try HAL.check(
        AudioDeviceCreateIOProcID(aggregate, meq_audio_callback, UnsafeMutableRawPointer(dsp), &io),
        "Creating audio callback")
      try disablePhysicalInputs()
      try HAL.check(AudioDeviceStart(aggregate, io), "Starting system-audio playback")
      started = true
    } catch {
      stop()
      throw error
    }
  }

  private func disablePhysicalInputs() throws {
    var property = HAL.address(
      kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    try HAL.check(
      AudioObjectGetPropertyDataSize(aggregate, &property, 0, nil, &size),
      "Reading input stream usage")
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
    let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    usage.pointee.mIOProc = unsafeBitCast(io!, to: UnsafeMutableRawPointer.self)
    try HAL.check(
      AudioObjectGetPropertyData(aggregate, &property, 0, nil, &size, raw), "Reading input usage")
    let count = Int(usage.pointee.mNumberStreams)
    // Audio stream count can differ from buffer count for planar PCM.
    let streams = try HAL.ids(
      aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    guard count == streams.count, count > 0 else {
      throw AudioFailure(message: "Cannot isolate the system-audio input stream.")
    }
    let flags = raw.advanced(
      by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    ).assumingMemoryBound(to: UInt32.self)
    for i in 0..<count { flags[i] = i == count - 1 ? 1 : 0 }
    try HAL.check(
      AudioObjectSetPropertyData(aggregate, &property, 0, nil, size, raw),
      "Disabling microphone inputs")
  }

  func stop() {
    if let io {
      if started { AudioDeviceStop(aggregate, io) }
      AudioDeviceDestroyIOProcID(aggregate, io)
    }
    io = nil
    started = false
    if aggregate != 0 {
      AudioHardwareDestroyAggregateDevice(aggregate)
      aggregate = 0
    }
    if tap != 0 {
      AudioHardwareDestroyProcessTap(tap)
      tap = 0
    }
  }
}
