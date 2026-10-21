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
  @Published var selectedBand = 0
  @Published var curves: [[Double]] = []
  @Published var combined: [Double] = []
  @Published var effectivePreamp = 0.0
  @Published var launchAtLogin = false
  @Published private(set) var isEditorVisible = false
  let engine = AudioEngine()
  let outputMeter = OutputMeterModel()
  private let store: PresetStore
  private var saveWork: DispatchWorkItem?
  private var graphWork: DispatchWorkItem?
  private var notifications: [NSObjectProtocol] = []
  private var savingAllowed = true
  let previewMode: Bool

  init() {
    previewMode =
      CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--diagnose")
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
    launchAtLogin = SMAppService.mainApp.status == .enabled
    engine.onUpdate = { [weak self] status in
      guard let self else { return }
      let changedRate = self.engineStatus.sampleRate != status.sampleRate
      self.engineStatus = status
      if changedRate { self.refreshGraph() }
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
    refreshGraph()
    if !previewMode { engine.configure(preset: saved.current, enabled: saved.enabled) }
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
    if visible { refreshGraph() }
  }
  func edit(_ operation: (inout EQPreset) -> Void) {
    operation(&saved.current)
    changed()
  }
  func bandBinding<T>(_ index: Int, _ path: WritableKeyPath<EQBand, T>) -> Binding<T> {
    Binding(
      get: { self.saved.current.bands[index][keyPath: path] },
      set: { value in self.edit { $0.bands[index][keyPath: path] = value } })
  }
  func setFilter(_ type: FilterType, index: Int) {
    edit {
      $0.bands[index].type = type
      $0.bands[index].width = type.defaultWidth
    }
  }
  func setEnabled(_ enabled: Bool) {
    saved.enabled = enabled
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
    if !previewMode { engine.configure(preset: saved.current, enabled: saved.enabled) }
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
    guard isEditorVisible else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.isEditorVisible else { return }
      let rate = max(32000, self.engineStatus.sampleRate)
      let preset = self.saved.current
      self.effectivePreamp =
        preset.autoPreamp
        ? EQResponse.autoPreamp(preset.bands, sampleRate: rate) : preset.manualPreamp
      self.curves = preset.bands.map { EQResponse.curve([$0], sampleRate: rate) }
      self.combined = EQResponse.curve(preset.bands, sampleRate: rate).map {
        $0 + self.effectivePreamp
      }
    }
    graphWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
  }
  func showPrivacySettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
  }
}

let bandColors: [Color] = [
  Color(red: 0.96, green: 0.69, blue: 0.25), Color(red: 0.77, green: 0.85, blue: 0.31),
  Color(red: 0.40, green: 0.83, blue: 0.48), Color(red: 0.25, green: 0.79, blue: 0.67),
  Color(red: 0.28, green: 0.76, blue: 0.91), Color(red: 0.35, green: 0.54, blue: 0.95),
  Color(red: 0.64, green: 0.49, blue: 0.94), Color(red: 0.89, green: 0.47, blue: 0.68),
]
