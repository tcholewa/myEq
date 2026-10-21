import CDSP
import CoreAudio
import Foundation

public struct EngineSnapshot {
  public var state: AudioEngineState = .bypassed
  public var outputName = "System output"
  public var sampleRate: Double = 48000
  public var preamp: Double = 0
  public var callbacks: UInt64 = 0
  public var faults: UInt64 = 0
  public init() {}
}

public final class AudioEngine {
  public var onUpdate: ((EngineSnapshot) -> Void)?
  public var onMeter: ((OutputLevels) -> Void)?
  private let queue = DispatchQueue(label: "com.tc.myEq.audio-control", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var meterTimer: DispatchSourceTimer?
  private var session: TapSession?
  private var route: OutputRoute?
  private var preset = EQPreset.flat
  private var applied: EQPreset?
  private var enabled = false
  private var sleeping = false
  private var blocked = false
  private var closing = false
  private var snapshot = EngineSnapshot()
  private var lastCallback: UInt64 = 0
  private var callbackChangedAt = Date()
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

  public init() {
    queue.async { [weak self] in self?.beginMonitoring() }
  }
  private func beginMonitoring() {
    for selector in [
      kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
      kAudioHardwarePropertyServiceRestarted,
    ] {
      var property = HAL.address(selector)
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        if selector == kAudioHardwarePropertyServiceRestarted {
          self.stop()
          self.route = nil
          self.blocked = false
        }
        self.tick()
      }
      if AudioObjectAddPropertyListenerBlock(HAL.system, &property, queue, block) == noErr {
        listeners.append((property, block))
      }
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
    let meterTimer = DispatchSource.makeTimerSource(queue: queue)
    meterTimer.schedule(deadline: .distantFuture)
    meterTimer.setEventHandler { [weak self] in self?.publishMeter() }
    meterTimer.resume()
    self.meterTimer = meterTimer
  }
  public func configure(preset: EQPreset, enabled: Bool) {
    guard preset.isValid else { return }
    queue.async { [weak self] in
      guard let self, !self.closing else { return }
      let toggled = self.enabled != enabled
      if toggled { self.blocked = false }
      self.preset = preset
      self.enabled = enabled
      if toggled { self.tick() } else { self.applySettings() }
    }
  }
  public func retry() {
    queue.async { [weak self] in
      self?.blocked = false
      self?.tick()
    }
  }
  public func setSleeping(_ sleeping: Bool) {
    queue.async { [weak self] in
      self?.sleeping = sleeping
      self?.blocked = false
      self?.tick()
    }
  }
  public func shutdown(completion: @escaping () -> Void) {
    queue.async {
      self.closing = true
      self.timer?.cancel()
      self.timer = nil
      self.meterTimer?.cancel()
      self.meterTimer = nil
      for (var property, block) in self.listeners {
        AudioObjectRemovePropertyListenerBlock(HAL.system, &property, self.queue, block)
      }
      self.listeners.removeAll()
      self.stop()
      DispatchQueue.main.async(execute: completion)
    }
  }
  private func publish() {
    let value = snapshot
    DispatchQueue.main.async { [weak self] in self?.onUpdate?(value) }
  }
  private func publishMeter() {
    guard !closing, let session else { return }
    let meter = meq_take_meter(session.dsp)
    let levels = OutputLevels(
      left: meter.peakLeft, right: meter.peakRight, reduction: meter.reduction, active: true)
    DispatchQueue.main.async { [weak self] in self?.onMeter?(levels) }
  }
  private func stop() {
    let wasRunning = session != nil
    if wasRunning { meterTimer?.schedule(deadline: .distantFuture) }
    session?.stop()
    session = nil
    applied = nil
    if wasRunning { DispatchQueue.main.async { [weak self] in self?.onMeter?(OutputLevels()) } }
  }
  private func applySettings() {
    guard applied != preset, let session, let route else { return }
    let preamp =
      preset.autoPreamp
      ? EQResponse.autoPreamp(preset.bands, sampleRate: route.rate) : preset.manualPreamp
    let native = preset.bands.map(\.native)
    if meq_submit(session.dsp, native, Int32(native.count), preamp) {
      applied = preset
      snapshot.preamp = preamp
    }
  }
  private func tick() {
    guard !closing else { return }
    defer { publish() }
    do {
      let current = try OutputRoute.current()
      if route != current {
        stop()
        route = current
        blocked = false
      }
      snapshot.outputName = current?.name ?? "No output connected"
      snapshot.sampleRate = current?.rate ?? 48000
      if !enabled {
        stop()
        snapshot.state = .bypassed
        return
      }
      if sleeping {
        stop()
        snapshot.state = .suspended("Mac is sleeping.")
        return
      }
      guard let current else {
        stop()
        snapshot.state = .suspended("Connect an audio output. EQ will resume automatically.")
        return
      }
      if let reason = current.suspension {
        stop()
        snapshot.state = .suspended(reason)
        return
      }
      guard !blocked else { return }
      if session == nil {
        snapshot.state = .starting
        publish()
        snapshot.preamp =
          preset.autoPreamp
          ? EQResponse.autoPreamp(preset.bands, sampleRate: current.rate) : preset.manualPreamp
        let newSession = TapSession()
        try newSession.start(route: current, preset: preset, preamp: snapshot.preamp)
        session = newSession
        meterTimer?.schedule(
          deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
        applied = preset
        lastCallback = 0
        callbackChangedAt = Date()
      } else {
        applySettings()
      }
      guard let session else { return }
      let meter = meq_meter(session.dsp)
      snapshot.callbacks = meter.callbacks
      snapshot.faults = meter.faults
      if meter.callbacks != lastCallback {
        lastCallback = meter.callbacks
        callbackChangedAt = Date()
      }
      // Zero samples are legitimate silence. Only callback/layout failures trigger recovery.
      if meter.faults > 8 {
        throw AudioFailure(
          message:
            "Audio buffers changed unexpectedly. Ordinary playback has been restored. Retry to reconnect."
        )
      }
      if Date().timeIntervalSince(callbackChangedAt) > 5 {
        if HAL.hasExternalPlayback(output: current.id) {
          throw AudioFailure(
            message:
              "The audio callback stopped while an application was playing. Ordinary playback has been restored. Retry to reconnect."
          )
        }
        callbackChangedAt = Date()
      }
      snapshot.state = .running
    } catch {
      stop()
      blocked = true
      snapshot.state = .error(error.localizedDescription)
    }
  }
  public static func diagnostics() -> String {
    do {
      guard let route = try OutputRoute.current() else {
        return "No default audio output is available."
      }
      return
        "Output: \(route.name)\nSample rate: \(route.rate) Hz\nChannels: \(route.channels)\nFormat supported: \(route.supportedFormat)\nStatus: \(route.suspension ?? "Ready")"
    } catch { return error.localizedDescription }
  }
}
