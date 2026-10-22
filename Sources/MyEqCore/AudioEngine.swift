import CDSP
import CoreAudio
import CoreGraphics
import Foundation

public struct AudioOutput: Equatable, Identifiable {
  public let id: String
  public let name: String
}

public enum DriverStatus: String {
  case missing, reloadRequired, ready
}

public struct EngineSnapshot: Equatable {
  public var outputs: [AudioOutput] = []
  public var selectedOutputUID: String?
  public var driverStatus: DriverStatus = .missing
  public var state: AudioEngineState = .starting
  public var outputName = "Connecting to audio…"
  public var sampleRate: Double = 48000
  public var preamp: Double = 0
  public init() {}
}

public final class AudioEngine {
  public var onUpdate: ((EngineSnapshot) -> Void)?
  public var onBypass: (() -> Void)?
  public var onSelectedOutput: ((String) -> Void)?
  public var onMeter: ((OutputLevels) -> Void)?
  private let queue = DispatchQueue(label: "com.tc.myEq.audio-control", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var meterMonitor: OutputMeterMonitor?
  private var session: VirtualOutputSession?
  private var preferredOutputUID: String?
  private var route: OutputRoute?
  private var preset = EQPreset.flat
  private var applied: EQPreset?
  private var enabled = false
  private var sleeping = false
  private var loginEligible: Bool?
  private var reconnecting = false
  private var startupRetry = StartupRetry()
  private var blocked = false
  private var closing = false
  private var snapshot = EngineSnapshot()
  private var lastPublished: EngineSnapshot?
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

  public init() {
    queue.async { [weak self] in self?.beginMonitoring() }
  }
  private func beginMonitoring() {
    meterMonitor = OutputMeterMonitor(queue: queue) { [weak self] levels in
      self?.onMeter?(levels)
    }
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
          self.startupRetry.reset()
          self.reconnecting = false
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
  }
  public func configure(
    preset: EQPreset, enabled: Bool, outputUID: String? = nil, retry: Bool = false
  ) {
    guard preset.isValid else { return }
    queue.async { [weak self] in
      guard let self, !self.closing else { return }
      let toggled = self.enabled != enabled || self.preferredOutputUID != outputUID
      self.preferredOutputUID = outputUID
      if toggled || retry {
        self.blocked = false
        self.startupRetry.reset()
        self.reconnecting = false
      }
      self.preset = preset
      self.enabled = enabled
      if toggled || retry { self.tick() } else { self.applySettings() }
    }
  }
  public func setEditorVisible(_ visible: Bool) {
    queue.async { [weak self] in
      guard let self, !self.closing else { return }
      self.meterMonitor?.setVisible(visible)
    }
  }
  public func refreshLoginSession() {
    queue.async { [weak self] in self?.tick() }
  }
  public func setSleeping(_ sleeping: Bool) {
    queue.async { [weak self] in
      NSLog("myEq: system sleep=%d", sleeping)
      self?.sleeping = sleeping
      self?.blocked = false
      self?.startupRetry.reset()
      self?.reconnecting = false
      self?.tick()
    }
  }
  public func shutdown(completion: @escaping () -> Void) {
    queue.async {
      self.closing = true
      self.timer?.cancel()
      self.timer = nil
      self.meterMonitor?.shutdown()
      self.meterMonitor = nil
      for (var property, block) in self.listeners {
        AudioObjectRemovePropertyListenerBlock(HAL.system, &property, self.queue, block)
      }
      self.listeners.removeAll()
      self.stop()
      DispatchQueue.main.async(execute: completion)
    }
  }
  private func publish() {
    guard snapshot != lastPublished else { return }
    lastPublished = snapshot
    let value = snapshot
    DispatchQueue.main.async { [weak self] in self?.onUpdate?(value) }
  }
  private func stop() {
    startupRetry.interrupted()
    meterMonitor?.setDSP(nil)
    session?.stop()
    session = nil
    applied = nil
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
      let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
      let eligible = LoginEligibility.allows(
        uid: (dictionary?[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value,
        onConsole: dictionary?[kCGSessionOnConsoleKey as String] as? Bool,
        loginDone: dictionary?[kCGSessionLoginDoneKey as String] as? Bool,
        ownUID: getuid())
      if loginEligible != eligible {
        loginEligible = eligible
        NSLog("myEq: login session eligible=%d", eligible)
        blocked = false
        startupRetry.reset()
        reconnecting = false
      }
      // Quiesce before checking a heartbeat that may have expired during sleep/switch.
      if sleeping || !eligible {
        stop()
        snapshot.state =
          enabled
          ? .suspended(
            sleeping ? "Mac is sleeping." : "This login session is inactive.") : .bypassed
        return
      }

      let all = OutputRoute.all()
      snapshot.outputs = all.filter { $0.channels.reduce(0, +) == 2 }.map {
        AudioOutput(id: $0.uid, name: $0.name)
      }
      let ids = (try? HAL.ids(HAL.system, kAudioHardwarePropertyDevices)) ?? []
      let driverFound = ids.contains {
        (try? HAL.string($0, kAudioDevicePropertyDeviceUID)) == "com.tc.myEq.output"
      }
      snapshot.driverStatus =
        driverFound
        ? .ready
        : FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/myEq.driver")
          ? .reloadRequired : .missing
      var manuallyBypassed = false
      if let session {
        let health = try session.heartbeat()
        if health == 2 {
          enabled = false
          stop()
          preferredOutputUID = nil
          manuallyBypassed = true
        } else if health == 3 {
          stop()
          preferredOutputUID = nil
        }
      }
      let system = try OutputRoute.current()
      let selected = all.first { $0.uid == preferredOutputUID }
      let current = selected ?? (system?.physical == true ? system : nil) ?? all.first
      if let current, preferredOutputUID != current.uid {
        preferredOutputUID = current.uid
        let uid = current.uid
        DispatchQueue.main.async { [weak self] in self?.onSelectedOutput?(uid) }
      }
      if manuallyBypassed { DispatchQueue.main.async { [weak self] in self?.onBypass?() } }
      snapshot.selectedOutputUID = current?.uid
      if route != current {
        stop()
        route = current
        blocked = false
        startupRetry.reset()
        reconnecting = false
      }
      snapshot.outputName = current?.name ?? "No output connected"
      snapshot.sampleRate = current?.rate ?? 48000
      if !enabled {
        startupRetry.reset()
        stop()
        snapshot.state = .bypassed
        return
      }
      guard snapshot.driverStatus == .ready else {
        stop()
        snapshot.state = .suspended(
          snapshot.driverStatus == .missing
            ? "Install myEq.pkg to enable the virtual output driver and audio helpers."
            : "The driver is installed but not loaded. Reload Core Audio or restart your Mac, then Retry."
        )
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
        guard startupRetry.isReady(at: ProcessInfo.processInfo.systemUptime) else { return }
        snapshot.state = reconnecting ? .reconnecting : .starting
        publish()
        snapshot.preamp =
          preset.autoPreamp
          ? EQResponse.autoPreamp(preset.bands, sampleRate: current.rate) : preset.manualPreamp
        let newSession = VirtualOutputSession()
        try newSession.start(route: current, preset: preset, preamp: snapshot.preamp)
        session = newSession
        startupRetry.healthy(at: ProcessInfo.processInfo.systemUptime)
        meterMonitor?.setDSP(newSession.dsp)
        applied = preset
      } else {
        applySettings()
      }
      guard let session else { return }
      let meter = meq_meter(session.dsp)
      if meter.faults > 8 {
        throw AudioFailure(
          message:
            "Audio buffers changed unexpectedly. Ordinary playback has been restored. Retry to reconnect."
        )
      }
      startupRetry.healthy(at: ProcessInfo.processInfo.systemUptime)
      snapshot.state = .running
    } catch {
      let wasRunning = session != nil || reconnecting
      stop()
      if startupRetry.schedule(for: error, at: ProcessInfo.processInfo.systemUptime) {
        // Use the existing timer while authenticated helpers and routing settle.
        reconnecting = wasRunning
        snapshot.state = reconnecting ? .reconnecting : .starting
        NSLog("myEq: retrying audio connection: %@", error.localizedDescription)
      } else {
        blocked = true
        snapshot.state = .error(error.localizedDescription)
        NSLog("myEq: audio startup/session failed: %@", error.localizedDescription)
      }
    }
  }
  public static func diagnostics() -> String {
    do {
      guard let route = try OutputRoute.current() else {
        return "No default audio output is available."
      }
      return
        "Backend: virtual output / shared memory\nOutput: \(route.name)\nSample rate: \(route.rate) Hz\nChannels: \(route.channels)\nFormat supported: \(route.supportedFormat)\nStatus: \(route.suspension ?? "Ready")"
    } catch { return error.localizedDescription }
  }
}

/// Bounded control-queue backoff; never retries permanently invalid configuration or identity.
struct StartupRetry {
  private var attempt = 0
  private var nextAttempt: TimeInterval = 0
  private var healthySince: TimeInterval?
  mutating func reset() {
    attempt = 0
    nextAttempt = 0
    healthySince = nil
  }
  mutating func interrupted() { healthySince = nil }
  mutating func healthy(at time: TimeInterval) {
    if healthySince == nil { healthySince = time }
    if let since = healthySince, time - since >= 30 {
      reset()
      healthySince = time
    }
  }
  func isReady(at time: TimeInterval) -> Bool { time >= nextAttempt }
  mutating func schedule(for error: Error, at time: TimeInterval) -> Bool {
    guard (error as? AudioFailure)?.retryableConnection == true, attempt < 4 else { return false }
    healthySince = nil
    nextAttempt = time + 0.25 * pow(2, Double(attempt))
    attempt += 1
    return true
  }
}

// Screen lock is not an eligibility input; console ownership and completed login are.
enum LoginEligibility {
  static func allows(uid: UInt32?, onConsole: Bool?, loginDone: Bool?, ownUID: UInt32) -> Bool {
    ownUID >= 500 && uid == ownUID && onConsole == true && loginDone == true
  }
}
