import AppKit
import MyEqCore
import SwiftUI

/// An injectable rendering policy for offscreen previews; nil uses macOS preferences.
struct MenuPanelAccessibility {
  var reduceTransparency = false
  var reduceMotion = false
  var increaseContrast = false
}

private struct MenuPanelAccessibilityKey: EnvironmentKey {
  static let defaultValue: MenuPanelAccessibility? = nil
}

extension EnvironmentValues {
  var menuPanelAccessibility: MenuPanelAccessibility? {
    get { self[MenuPanelAccessibilityKey.self] }
    set { self[MenuPanelAccessibilityKey.self] = newValue }
  }
}

/// A quick control surface. Editing and technical readouts belong in the equalizer window.
struct MenuBarPanel: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.menuPanelAccessibility) private var accessibilityOverride
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var focus: Control?
  private var accessibility: MenuPanelAccessibility {
    accessibilityOverride
      ?? MenuPanelAccessibility(
        reduceTransparency: reduceTransparency, reduceMotion: reduceMotion,
        increaseContrast: contrast == .increased)
  }
  private var borderWidth: CGFloat { accessibility.increaseContrast ? 1 : 0.5 }
  private var showsRecoveryActions: Bool {
    guard model.installationIssue == nil else { return false }
    if case .error = model.engineStatus.state { return true }
    return false
  }

  private enum Control: Hashable {
    case power, output, preset, setup, retry, editor, options, quit
  }

  private var controls: [Control] {
    var result: [Control] = model.installationIssue == nil ? [.power] : []
    result += [.output, .preset]
    if showsRecoveryActions {
      result += [.setup, .retry]
    }
    return result + [.editor, .options, .quit]
  }

  var body: some View {
    VStack(spacing: 0) {
      header.padding(16)
      VStack(spacing: 8) {
        VStack(spacing: 0) {
          outputRow
          Divider().padding(.leading, 48)
          presetRow
        }
        .background {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
              Color(nsColor: .controlBackgroundColor).opacity(
                accessibility.reduceTransparency ? 1 : 0.55))
        }
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: borderWidth)
            .allowsHitTesting(false)
        }
        if let detail = model.engineStatus.state.detail {
          notice(detail).transition(.opacity)
        }
        Button(action: showEqualizer) {
          HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").symbolRenderingMode(.hierarchical)
              .frame(width: 20)
            Text("Open Equalizer")
            Spacer()
            ShortcutHint("⇧⌘E")
          }
          .font(.system(.subheadline, design: .default))
          .padding(.horizontal, 12).frame(minHeight: 36)
          .contentShape(Rectangle())
        }
        .buttonStyle(MenuPanelButtonStyle())
        .focused($focus, equals: .editor)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .help("Open the full equalizer · ⇧⌘E")
      }
      .padding(.horizontal, 12).padding(.bottom, 8)
      Divider()
      footer.padding(.horizontal, 12).padding(.vertical, 6)
    }
    .environment(\.menuPanelAccessibility, accessibility)
    .frame(width: 344)
    .foregroundStyle(.primary)
    .background {
      if accessibility.reduceTransparency {
        Color(nsColor: .windowBackgroundColor)
      } else {
        Rectangle().fill(.ultraThinMaterial)
      }
    }
    // MenuBarExtra owns the window's outer corners, shadow and screen-edge positioning.
    .animation(
      accessibility.reduceMotion ? nil : .easeInOut(duration: 0.16),
      value: model.engineStatus.state.detail
    )
    .onMoveCommand(perform: moveFocus)
    .onExitCommand { model.closeMenu() }
    .onChange(of: model.isMenuVisible) { _, visible in
      if !visible { focus = nil }
    }
    .background(
      EditorVisibilityObserver(onChange: model.setMenuVisible, onWindow: { model.menuWindow = $0 })
    )
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "slider.horizontal.3")
        .font(.system(.title3, design: .default, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color.accentColor)
        .frame(width: 34, height: 34)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text("myEq").font(.system(.headline, design: .default))
        MenuPanelStatus(state: model.engineStatus.state)
      }
      Spacer(minLength: 12)
      Toggle(
        "Enable equalizer",
        isOn: Binding(
          get: { model.saved.enabled }, set: { model.setEnabled($0) }
        )
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.small)
      .disabled(model.installationIssue != nil)
      .focused($focus, equals: .power)
      .keyboardShortcut("e", modifiers: .command)
      .accessibilityHint("Bypass preserves your preset and keeps ordinary playback available.")
      .help(model.saved.enabled ? "Bypass equalizer · ⌘E" : "Enable equalizer · ⌘E")
    }
    .frame(minHeight: 38)
  }

  private var outputRow: some View {
    PopupMenuButton {
      let menu = ActionMenu()
      if model.engineStatus.outputs.isEmpty {
        menu.choice("No output connected", enabled: false) {}
      }
      for output in model.engineStatus.outputs {
        menu.choice(output.name, selected: output.id == model.engineStatus.selectedOutputUID) {
          model.selectOutput(output.id)
        }
      }
      return menu
    } label: {
      MenuPanelSelectionRow(
        title: "Output", value: model.engineStatus.outputName, symbol: "speaker.wave.2"
      )
    }
    .focused($focus, equals: .output)
    .accessibilityLabel("Audio output")
    .accessibilityValue(model.engineStatus.outputName)
    .accessibilityHint("Opens the list of speakers and headphones.")
    .help("\(model.engineStatus.outputName) · Choose speakers or headphones")
  }

  private var presetRow: some View {
    PopupMenuButton {
      let menu = ActionMenu()
      for preset in model.allPresets {
        menu.choice(preset.name, selected: preset.id == model.saved.current.id) {
          model.selectPreset(preset.id)
        }
      }
      return menu
    } label: {
      MenuPanelSelectionRow(
        title: "Preset", value: model.saved.current.name, symbol: "line.3.horizontal.decrease",
        edited: model.isModified
      )
    }
    .focused($focus, equals: .preset)
    .accessibilityLabel("Sound preset")
    .accessibilityValue(model.saved.current.name + (model.isModified ? ", edited" : ""))
    .accessibilityHint("Opens your presets. Selecting one replaces current edits.")
    .help("\(model.saved.current.name)\(model.isModified ? " · Edited" : "") · Choose preset")
  }

  private func notice(_ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(detail)
        .font(.system(.subheadline, design: .default))
        .fixedSize(horizontal: false, vertical: true)
      if showsRecoveryActions {
        HStack {
          Button("Audio Setup…") { model.showAudioSetup() }
            .focused($focus, equals: .setup)
          Spacer()
          Button("Retry") { model.retryAudio() }
            .focused($focus, equals: .retry)
        }
        .buttonStyle(.bordered).controlSize(.small)
      }
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(
        Color(nsColor: .separatorColor), lineWidth: borderWidth)
    }
  }

  private var footer: some View {
    HStack(spacing: 0) {
      PopupMenuButton {
        let menu = ActionMenu()
        menu.choice("Launch at Login", selected: model.launchAtLogin, enabled: model.isInstalledApp)
        {
          model.setLaunchAtLogin(!model.launchAtLogin)
        }
        menu.choice("Audio Setup…") { model.showAudioSetup() }
        return menu
      } label: {
        MenuPanelUtilityLabel(title: "Options", symbol: "gearshape")
      }
      .focused($focus, equals: .options)
      .accessibilityLabel("Options")
      .help("Launch at login and audio setup")
      Spacer()
      Button {
        NSApp.terminate(nil)
      } label: {
        HStack(spacing: 12) {
          Text("Quit myEq")
          ShortcutHint("⌘Q")
        }
        .font(.system(.caption, design: .default))
        .padding(.horizontal, 8).frame(minHeight: 30).contentShape(Rectangle())
      }
      .buttonStyle(MenuPanelButtonStyle())
      .focused($focus, equals: .quit)
      .keyboardShortcut("q")
    }
  }

  private func showEqualizer() {
    model.closeMenu()
    openWindow(id: "equalizer")
    NSApp.activate(ignoringOtherApps: true)
  }

  private func moveFocus(_ direction: MoveCommandDirection) {
    guard direction == .up || direction == .down else { return }
    let order = controls
    let step = direction == .down ? 1 : -1
    let current = focus.flatMap { order.firstIndex(of: $0) } ?? (step == 1 ? -1 : order.count)
    focus = order[(current + step + order.count) % order.count]
  }
}

private struct MenuPanelStatus: View {
  let state: AudioEngineState
  private var symbol: String {
    switch state {
    case .running: "checkmark.circle.fill"
    case .bypassed: "pause.circle"
    case .starting: "ellipsis.circle"
    case .suspended: "pause.circle.fill"
    case .error: "exclamationmark.circle.fill"
    }
  }
  private var color: Color {
    switch state {
    case .running: Color(nsColor: .systemGreen)
    case .error, .suspended: Color(nsColor: .systemOrange)
    default: .secondary
    }
  }
  var body: some View {
    Label {
      Text(state.title).modifier(MenuPanelSecondary())
    } icon: {
      Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(color)
    }
    .font(.system(.caption, design: .default))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Equalizer status")
    .accessibilityValue(state.title)
  }
}

private struct MenuPanelSelectionRow: View {
  let title: String
  let value: String
  let symbol: String
  var edited = false
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(.body, design: .default))
        .symbolRenderingMode(.hierarchical).modifier(MenuPanelSecondary())
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title).modifier(MenuPanelSecondary())
          if edited {
            Text("Edited").modifier(MenuPanelSecondary())
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
          }
        }
        .font(.system(.caption, design: .default))
        Text(value).font(.system(.body, design: .default, weight: .medium))
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 4)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(.caption2, design: .default, weight: .medium)).modifier(MenuPanelSecondary())
    }
    .padding(.horizontal, 12).padding(.vertical, 11)
    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    .contentShape(Rectangle())
    .modifier(MenuPanelHover())
  }
}

private struct MenuPanelUtilityLabel: View {
  let title: String
  let symbol: String
  var body: some View {
    Label(title, systemImage: symbol).symbolRenderingMode(.hierarchical)
      .font(.system(.caption, design: .default))
      .padding(.horizontal, 8).frame(minHeight: 30)
      .contentShape(Rectangle()).modifier(MenuPanelHover())
  }
}

private struct ShortcutHint: View {
  let value: String
  init(_ value: String) { self.value = value }
  var body: some View {
    Text(value).font(.system(.caption, design: .default)).modifier(MenuPanelSecondary())
      .accessibilityHidden(true)
  }
}

private struct MenuPanelSecondary: ViewModifier {
  @Environment(\.menuPanelAccessibility) private var accessibility
  func body(content: Content) -> some View {
    content.foregroundStyle(
      Color(nsColor: .labelColor).opacity(accessibility?.increaseContrast == true ? 1 : 0.74)
    )
  }
}

/// Color-only feedback avoids moving targets. Native button focus rings remain enabled.
private struct MenuPanelHover: ViewModifier {
  var pressed = false
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.isEnabled) private var enabled
  @Environment(\.menuPanelAccessibility) private var accessibilityOverride
  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            Color.primary.opacity(enabled && (pressed || hovering) ? (pressed ? 0.12 : 0.06) : 0)
          )
          .padding(3)
      }
      .overlay {
        if enabled && hovering
          && (accessibilityOverride?.increaseContrast ?? (contrast == .increased))
        {
          RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1).padding(3)
            .allowsHitTesting(false)
        }
      }
      .onHover { hovering = $0 }
      .animation(
        (accessibilityOverride?.reduceMotion ?? reduceMotion) ? nil : .easeOut(duration: 0.10),
        value: hovering)
  }
}

private struct MenuPanelButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.modifier(MenuPanelHover(pressed: configuration.isPressed))
  }
}
