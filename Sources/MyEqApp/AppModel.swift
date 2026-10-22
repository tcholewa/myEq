import AppKit
import MyEqCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()
  @Published var saved: SavedState
  @Published var engineStatus = EngineSnapshot()
  @Published var message: String?
  @Published var selectedBand: Int? = nil
  @Published var curves: [[Double]] = []
  @Published var combined: [Double] = []
  @Published var menuCurve: [Double] = []
  @Published var effectivePreamp = 0.0
  @Published var launchAtLogin = false
  @Published private(set) var isEditorVisible = false
  @Published private(set) var isMenuVisible = false
  weak var menuWindow: NSWindow?
  let engine = AudioEngine()
  let outputMeter = OutputMeterModel()
  private let store: PresetStore
  private var saveWork: DispatchWorkItem?
  private var graphWork: DispatchWorkItem?
  private var notifications: [NSObjectProtocol] = []
  private var savingAllowed = true
  private var recoverySetupIssue: String?
  private var recoveryReady = false
  private var preparingRecovery = false
  let previewMode: Bool
  let isInstalledApp =
    Bundle.main.bundleURL.resolvingSymlinksInPath().path == "/Applications/myEq.app"
  var installationIssue: String? {
    guard !previewMode, !isInstalledApp else { return nil }
    return
      "This copy is not installed. Quit it and open /Applications/myEq.app to use EQ and its audio helpers."
  }

  init(preview: Bool = false) {
    previewMode =
      preview || CommandLine.arguments.contains("--preview")
      || CommandLine.arguments.contains("--diagnose")
    store = PresetStore()
    var loaded = SavedState()
    var warning: String?
    if !previewMode {
      do { loaded = try store.load() } catch {
        do {
          let backup = try store.preserveInvalidFile()
          warning =
            "Settings could not be read. Flat settings were restored.\(backup.map { " The original file is preserved at \($0.path)." } ?? "")"
        } catch {
          savingAllowed = false
          warning =
            "Settings could not be read or backed up. Changes will not be saved: \(error.localizedDescription)"
        }
      }
    } else {
      loaded.current = .botaniq
    }
    saved = loaded
    message = warning
    launchAtLogin = isInstalledApp && SMAppService.mainApp.status == .enabled
    engine.onUpdate = { [weak self] status in
      guard let self, !self.previewMode else { return }
      var status = status
      if let issue = self.installationIssue ?? self.recoverySetupIssue {
        status.state = .error(issue)
      }
      let changedRate = self.engineStatus.sampleRate != status.sampleRate
      self.engineStatus = status
      if changedRate { self.refreshGraph() }
    }
    engine.onBypass = { [weak self] in self?.setEnabled(false) }
    engine.onSelectedOutput = { [weak self] uid in
      guard let self else { return }
      self.saved.preferredOutputUID = uid
      self.flush()
    }
    engine.onMeter = { [weak self] levels in
      guard let self, self.isEditorVisible else { return }
      self.outputMeter.update(levels)
    }
    let center = NSWorkspace.shared.notificationCenter
    notifications.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.engine.setSleeping(true) }
      })
    notifications.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.engine.setSleeping(false) }
      })
    notifications.append(
      center.addObserver(
        forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
      ) {
        [weak self] _ in Task { @MainActor in self?.engine.refreshLoginSession() }
      })
    notifications.append(
      center.addObserver(
        forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
      ) {
        [weak self] _ in Task { @MainActor in self?.engine.refreshLoginSession() }
      })
    refreshGraph()
    retryAudio()
  }
  private func prepareRecoveryAgent() async -> Bool {
    let service = SMAppService.agent(plistName: "com.tc.myEq.recovery.plist")
    do {
      let installationID = try InstallationMetadata.identifier()
      let registrationKey = "recoveryRegistrationID"
      var status = service.status
      if status == .enabled,
        UserDefaults.standard.string(forKey: registrationKey) != installationID
      {
        // Installer bootout removes the launchd job without clearing SMAppService's registration.
        // Wait for unregister to finish before refreshing this user's registration for the new install.
        NSLog("myEq: refreshing recovery helper registration after installation")
        do {
          try await service.unregister()
        } catch let error as NSError
          where error.domain == SMAppServiceErrorDomain && error.code == kSMErrorJobNotFound
        {
          // The installer may already have removed the job.
        }
        status = .notRegistered
      }
      // On first launch macOS can report notFound even when the bundled plist exists.
      // Checking only notRegistered silently skipped registration on this Mac.
      if status == .notRegistered || status == .notFound {
        let bundle = Bundle.main.bundleURL
        guard
          FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent(
              "Contents/Library/LaunchAgents/com.tc.myEq.recovery.plist"
            ).path),
          FileManager.default.isExecutableFile(
            atPath: bundle.appendingPathComponent("Contents/Helpers/myEqRecovery").path)
        else {
          throw NSError(
            domain: "com.tc.myEq.setup", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: "The recovery helper is missing. Reinstall myEq.pkg."
            ]
          )
        }
        NSLog("myEq: registering recovery helper from status %ld", status.rawValue)
        try service.register()
        NSLog("myEq: recovery helper registration succeeded; status %ld", service.status.rawValue)
      }
      if service.status == .requiresApproval {
        recoverySetupIssue =
          "Allow myEq in System Settings → General → Login Items & Extensions, then click Retry."
      } else if service.status == .enabled {
        recoverySetupIssue = nil
        UserDefaults.standard.set(installationID, forKey: registrationKey)
      } else {
        recoverySetupIssue = "The recovery helper is not registered yet. Click Retry to try again."
      }
    } catch {
      let error = error as NSError
      recoverySetupIssue =
        "Could not register the recovery helper: \(error.localizedDescription) (\(error.domain) \(error.code)). Click Retry to try again."
      NSLog("myEq: recovery helper registration failed: %@", error)
    }
    if let issue = recoverySetupIssue { engineStatus.state = .error(issue) }
    return recoverySetupIssue == nil
  }
  func retryAudio() {
    guard !previewMode, isInstalledApp, !preparingRecovery else { return }
    preparingRecovery = true
    recoveryReady = false
    Task {
      defer { preparingRecovery = false }
      recoveryReady = await prepareRecoveryAgent()
      engine.configure(
        preset: saved.current, enabled: saved.enabled && recoveryReady,
        outputUID: saved.preferredOutputUID, retry: recoveryReady)
    }
  }
  var allPresets: [EQPreset] { EQPreset.factory + saved.presets }
  var isModified: Bool { allPresets.first(where: { $0.id == saved.current.id }) != saved.current }
  var frequencyLimit: Double { min(20000, max(32000, engineStatus.sampleRate) * 0.45) }
  func setEditorVisible(_ visible: Bool) {
    guard isEditorVisible != visible else { return }
    isEditorVisible = visible
    engine.setEditorVisible(visible && !previewMode)
    outputMeter.reset()
    graphWork?.cancel()
    graphWork = nil
    if visible || isMenuVisible { refreshGraph() }
  }
  func setMenuVisible(_ visible: Bool) {
    guard isMenuVisible != visible else { return }
    isMenuVisible = visible
    // The menu has a static response preview; it never enables DSP metering.
    if visible {
      refreshGraph()
    } else if !isEditorVisible {
      graphWork?.cancel()
      graphWork = nil
    }
  }
  func closeMenu() {
    menuWindow?.orderOut(nil)
    setMenuVisible(false)
  }
  func edit(_ operation: (inout EQPreset) -> Void) {
    operation(&saved.current)
    changed()
  }
  func bandBinding<T: Equatable>(_ index: Int, _ path: WritableKeyPath<EQBand, T>) -> Binding<T> {
    Binding(
      get: { self.saved.current.bands[index][keyPath: path] },
      set: { value in
        // TextField may commit its unchanged initial value when focus moves away.
        guard value != self.saved.current.bands[index][keyPath: path] else { return }
        self.selectedBand = index
        self.edit { $0.bands[index][keyPath: path] = value }
      })
  }
  func setFilter(_ type: FilterType, index: Int) {
    edit {
      $0.bands[index].type = type
      $0.bands[index].width = type.defaultWidth
    }
  }
  func setEnabled(_ enabled: Bool) {
    saved.enabled = enabled
    if enabled { retryAudio() }
    changed()
  }
  func selectPreset(_ id: UUID) {
    guard let value = allPresets.first(where: { $0.id == id }) else { return }
    saved.current = value
    changed()
  }
  func savePreset(name: String, duplicate: Bool) {
    let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    guard !name.isEmpty else { return }
    var value = saved.current
    if duplicate || value.isFactory { value.id = UUID() }
    value.name = name
    if let index = saved.presets.firstIndex(where: { $0.id == value.id }) {
      saved.presets[index] = value
    } else {
      saved.presets.append(value)
    }
    saved.current = value
    changed()
  }
  func deletePreset() {
    guard !saved.current.isFactory else { return }
    saved.presets.removeAll { $0.id == saved.current.id }
    saved.current = .flat
    changed()
  }
  func setLaunchAtLogin(_ value: Bool) {
    guard isInstalledApp else {
      message = installationIssue
      return
    }
    do {
      if value {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = SMAppService.mainApp.status == .enabled
      if value && !launchAtLogin {
        message = "Allow myEq in System Settings → General → Login Items to enable launch at login."
      }
    } catch { message = "Could not change launch at login: \(error.localizedDescription)" }
  }
  private func changed() {
    guard saved.isValid else { return }
    if !previewMode && isInstalledApp && (!preparingRecovery || !saved.enabled) {
      engine.configure(
        preset: saved.current, enabled: saved.enabled && recoveryReady,
        outputUID: saved.preferredOutputUID)
    }
    refreshGraph()
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flush() }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }
  func flush() {
    guard !previewMode, savingAllowed else { return }
    do { try store.save(saved) } catch {
      message = "Settings could not be saved: \(error.localizedDescription)"
    }
  }
  func refreshGraph() {
    graphWork?.cancel()
    graphWork = nil
    guard isEditorVisible || isMenuVisible else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.isEditorVisible || self.isMenuVisible else { return }
      let rate = max(32000, self.engineStatus.sampleRate)
      let preset = self.saved.current
      self.effectivePreamp =
        preset.autoPreamp
        ? EQResponse.autoPreamp(preset.bands, sampleRate: rate) : preset.manualPreamp
      if self.isEditorVisible {
        self.curves = preset.bands.map { EQResponse.curve([$0], sampleRate: rate) }
        self.combined = EQResponse.curve(preset.bands, sampleRate: rate).map {
          $0 + self.effectivePreamp
        }
      }
      if self.isMenuVisible {
        self.menuCurve = EQResponse.curve(preset.bands, sampleRate: rate, count: 128).map {
          $0 + self.effectivePreamp
        }
      }
    }
    graphWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
  }
  func selectOutput(_ uid: String) {
    saved.preferredOutputUID = uid
    changed()
  }
  func showAudioSetup() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

let bandColors: [Color] = [
  Color(red: 0.96, green: 0.69, blue: 0.25), Color(red: 0.77, green: 0.85, blue: 0.31),
  Color(red: 0.40, green: 0.83, blue: 0.48), Color(red: 0.25, green: 0.79, blue: 0.67),
  Color(red: 0.28, green: 0.76, blue: 0.91), Color(red: 0.35, green: 0.54, blue: 0.95),
  Color(red: 0.64, green: 0.49, blue: 0.94), Color(red: 0.89, green: 0.47, blue: 0.68),
]
