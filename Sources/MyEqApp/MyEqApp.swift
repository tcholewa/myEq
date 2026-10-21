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
    .defaultSize(width: 1180, height: 900)
    .defaultPosition(.center)
    .windowStyle(.hiddenTitleBar)
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
      MenuBarPanel(model: model).preferredColorScheme(.dark)
    } label: {
      Image(nsImage: Studio.statusIcon)
        .accessibilityLabel("myEq · \(model.engineStatus.state.title)")
        .help("myEq · \(model.engineStatus.state.title)")
    }.menuBarExtraStyle(.window)
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
