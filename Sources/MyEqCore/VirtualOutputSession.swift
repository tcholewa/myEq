import AudioToolbox
import CDSP
import CTransport
import CoreAudio
import Foundation

/// All lifecycle calls run on the engine's control queue. The IOProc is C++ only.
final class VirtualOutputSession {
  let dsp = meq_create()!
  private var connection: OpaquePointer?
  private var renderer: OpaquePointer?
  private var io: AudioDeviceIOProcID?
  private var device: AudioObjectID = 0
  private var started = false
  private var volume: HardwareVolume?
  deinit {
    stop()
    meq_destroy(dsp)
  }

  private func checked(_ operation: (UnsafeMutablePointer<CChar>, Int) -> Bool) throws {
    var error = [CChar](repeating: 0, count: 512)
    guard operation(&error, error.count) else {
      throw AudioFailure(message: String(cString: error))
    }
  }
  func start(route: OutputRoute, preset: EQPreset, preamp: Double) throws {
    do {
      let bands = preset.bands.map(\.native)
      guard meq_prepare(dsp, route.rate, bands, Int32(bands.count), preamp) else {
        throw AudioFailure(message: "Invalid equalizer configuration.")
      }
      try checked {
        connection = meq_connect($0, $1)
        return connection != nil
      }
      try checked { meq_open_transport(connection, route.rate, route.name, $0, $1) }
      device = route.id
      let preferred =
        (try? HAL.ids(
          device, kAudioDevicePropertyPreferredChannelsForStereo,
          scope: kAudioObjectPropertyScopeOutput)) ?? [1, 2]
      guard preferred.count == 2, Set(preferred) == Set([UInt32(1), UInt32(2)]) else {
        throw AudioFailure(message: "This output's preferred stereo channels are unsupported.")
      }
      func location(_ channel: Int) -> MEQChannel {
        var remaining = channel
        for (index, count) in route.channels.enumerated() {
          if remaining < count {
            return MEQChannel(buffer: Int32(index), channel: Int32(remaining), stride: Int32(count))
          }
          remaining -= count
        }
        return MEQChannel(buffer: -1, channel: 0, stride: 0)
      }
      let frames = try HAL.scalar(device, kAudioDevicePropertyBufferFrameSize, UInt32(0))
      try checked {
        renderer = meq_renderer_create(
          connection, dsp, route.rate, frames,
          location(Int(preferred[0]) - 1), location(Int(preferred[1]) - 1), $0, $1)
        return renderer != nil
      }
      try HAL.check(
        AudioDeviceCreateIOProcID(
          device, meq_output_callback,
          UnsafeMutableRawPointer(renderer), &io), "Creating physical output callback")
      try disableInputs()
      volume = HardwareVolume(device: device)
      syncVolume()
      try HAL.check(AudioDeviceStart(device, io), "Starting physical output")
      started = true
      for _ in 0..<100 {
        if meq_transport_health(renderer).callbacks > 0 { break }
        Thread.sleep(forTimeInterval: 0.005)
      }
      try checked { meq_activate_route(connection, route.uid, $0, $1) }
    } catch {
      stop()
      throw error
    }
  }
  /// 1 healthy, 2 manual output selection, 3 disconnected destination.
  func heartbeat() throws -> Int {
    syncVolume()
    if meq_transport_health(renderer).invalidSamples > 8 {
      throw AudioFailure(
        message: "Invalid audio buffers. Ordinary playback has been restored; Retry to reconnect.")
    }
    var error = [CChar](repeating: 0, count: 512)
    let state = meq_heartbeat(connection, &error, error.count)
    if state == 0 { throw AudioFailure(message: String(cString: error)) }
    return Int(state)
  }
  private func syncVolume() {
    guard let connection, let volume else { return }
    var requested: Float = 1
    var muted = false
    if meq_volume_request(connection, &requested, &muted) { volume.set(requested, muted: muted) }
    let values = volume.read()
    meq_volume_state(
      connection, !volume.volumeElements.isEmpty, !volume.muteElements.isEmpty,
      values.volume, values.muted)
  }
  private func disableInputs() throws {
    let streams = try HAL.ids(
      device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    guard !streams.isEmpty else { return }
    var property = HAL.address(
      kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
    let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    let size = offset + streams.count * MemoryLayout<UInt32>.size
    let memory = UnsafeMutableRawPointer.allocate(
      byteCount: size,
      alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
    defer { memory.deallocate() }
    memory.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let usage = memory.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    usage.pointee.mIOProc = unsafeBitCast(io!, to: UnsafeMutableRawPointer.self)
    usage.pointee.mNumberStreams = UInt32(streams.count)
    try HAL.check(
      AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(size), memory),
      "Disabling physical microphone inputs")
  }
  func stop() {
    // Restore defaults before stopping our physical renderer.
    if let connection { meq_close_transport(connection) }
    if let io {
      if started { AudioDeviceStop(device, io) }
      AudioDeviceDestroyIOProcID(device, io)
    }
    io = nil
    started = false
    if let renderer { meq_renderer_destroy(renderer) }
    renderer = nil
    if let connection { meq_disconnect(connection) }
    connection = nil
    volume = nil
  }
}

private final class HardwareVolume {
  let device: AudioObjectID
  let volumeElements: [UInt32]
  let muteElements: [UInt32]
  init(device: AudioObjectID) {
    self.device = device
    func elements(_ selector: AudioObjectPropertySelector) -> [UInt32] {
      func supported(_ element: UInt32) -> Bool {
        var property = AudioObjectPropertyAddress(
          mSelector: selector,
          mScope: kAudioObjectPropertyScopeOutput, mElement: element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &property)
          && AudioObjectIsPropertySettable(device, &property, &settable) == noErr
          && settable.boolValue
      }
      if supported(0) { return [0] }
      return supported(1) && supported(2) ? [1, 2] : []
    }
    volumeElements = elements(kAudioDevicePropertyVolumeScalar)
    muteElements = elements(kAudioDevicePropertyMute)
  }
  private func get<T: BitwiseCopyable>(
    _ selector: AudioObjectPropertySelector, _ element: UInt32, _ initial: T
  ) -> T {
    var p = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(device, &p, 0, nil, &size, &v)
    return v
  }
  private func put<T: BitwiseCopyable>(
    _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: T
  ) {
    var p = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    var v = value
    AudioObjectSetPropertyData(device, &p, 0, nil, UInt32(MemoryLayout<T>.size), &v)
  }
  func read() -> (volume: Float, muted: Bool) {
    let values = volumeElements.map { get(kAudioDevicePropertyVolumeScalar, $0, Float(1)) }
    return (
      values.max() ?? 1,
      !muteElements.isEmpty
        && muteElements.allSatisfy { get(kAudioDevicePropertyMute, $0, UInt32(0)) != 0 }
    )
  }
  func set(_ volume: Float, muted: Bool) {
    let old = read().volume
    for e in volumeElements {
      let balance = old > 0 ? get(kAudioDevicePropertyVolumeScalar, e, Float(1)) / old : 1
      put(kAudioDevicePropertyVolumeScalar, e, min(1, max(0, volume * balance)))
    }
    for e in muteElements { put(kAudioDevicePropertyMute, e, UInt32(muted ? 1 : 0)) }
  }
}
