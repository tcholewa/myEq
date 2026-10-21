import AppKit
import MyEqCore
import SwiftUI

@main
struct MyEqApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AppModel.shared
  var body: some Scene {
    Window("myEq", id: "equalizer") {
      EqualizerView(model: model)
        .background(EditorVisibilityObserver(onChange: model.setEditorVisible))
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 1120, height: 850)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Equalizer") {
        Button(model.saved.enabled ? "Bypass Equalizer" : "Enable Equalizer") {
          model.setEnabled(!model.saved.enabled)
        }.keyboardShortcut("e", modifiers: [.command]).disabled(model.installationIssue != nil)
        Button("Reset to Flat") { model.selectPreset(EQPreset.flat.id) }.keyboardShortcut(
          "0", modifiers: [.command])
      }
    }
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      Image(
        systemName: model.engineStatus.state == .running
          ? "slider.horizontal.3" : "slider.horizontal.3"
      )
      .accessibilityLabel("myEq · \(model.engineStatus.state.title)")
    }
  }
}

struct MenuContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text("myEq · \(model.engineStatus.state.title)")
    Text(model.engineStatus.outputName)
    Divider()
    Toggle(
      "Enable Equalizer", isOn: Binding(get: { model.saved.enabled }, set: { model.setEnabled($0) })
    ).disabled(model.installationIssue != nil)
    Button("Open Equalizer…") {
      openWindow(id: "equalizer")
      NSApp.activate(ignoringOtherApps: true)
    }.keyboardShortcut("e", modifiers: [.command, .shift])
    Menu("Output") {
      ForEach(model.engineStatus.outputs) { output in
        Button {
          model.selectOutput(output.id)
        } label: {
          if output.id == model.engineStatus.selectedOutputUID {
            Label(output.name, systemImage: "checkmark")
          } else {
            Text(output.name)
          }
        }
      }
    }
    Menu("Preset") {
      ForEach(model.allPresets) { preset in
        Button {
          model.selectPreset(preset.id)
        } label: {
          if preset.id == model.saved.current.id {
            Label(preset.name, systemImage: "checkmark")
          } else {
            Text(preset.name)
          }
        }
      }
    }
    if model.engineStatus.state.detail != nil && model.installationIssue == nil {
      Button("Retry Audio") { model.retryAudio() }
    }
    Divider()
    Toggle(
      "Launch at Login",
      isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
    ).disabled(!model.isInstalledApp)
    Button("Quit myEq") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--diagnose") {
      print(AudioEngine.diagnostics())
      fflush(stdout)
      NSApp.terminate(nil)
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppModel.shared.flush()
    AppModel.shared.engine.shutdown { sender.reply(toApplicationShouldTerminate: true) }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
