import AppKit
import MyEqCore
import SwiftUI

struct MenuBarPanel: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    VStack(spacing: 18) {
      HStack(spacing: 10) {
        EqualizerMark().frame(width: 33, height: 33)
          .background(RoundedRectangle(cornerRadius: 10).fill(Studio.accent.opacity(0.07)))
        VStack(alignment: .leading, spacing: 4) {
          Text("myEq").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.5)
          StatusLabel(state: model.engineStatus.state)
        }
        Spacer()
        PowerControl(model: model, compact: true)
      }
      OutputSelector(model: model, compact: true)
      if let detail = model.engineStatus.state.detail {
        VStack(alignment: .leading, spacing: 10) {
          Label(detail, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Studio.accent)
          if model.installationIssue == nil {
            HStack {
              Button("Background Items") { model.showAudioSetup() }
              Spacer()
              Button("Retry") { model.retryAudio() }
            }.buttonStyle(StudioButtonStyle(compact: true))
          }
        }.padding(12).background(
          RoundedRectangle(cornerRadius: 12).fill(Studio.accent.opacity(0.05)))
      }
      presetSection
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          SectionCaption(model.saved.current.autoPreamp ? "Auto preamp" : "Preamp")
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(format: "%+.1f", model.effectivePreamp))
              .font(.system(size: 18, weight: .medium, design: .monospaced))
            Text("dB").font(.system(size: 10)).foregroundStyle(Studio.secondary)
          }
        }
        Spacer()
        Rectangle().fill(Studio.line).frame(width: 1, height: 31)
        Spacer()
        VStack(alignment: .leading, spacing: 6) {
          SectionCaption("Stereo output")
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(format: "%.1f", model.engineStatus.sampleRate / 1000))
              .font(.system(size: 18, weight: .medium, design: .monospaced))
            Text("kHz").font(.system(size: 10)).foregroundStyle(Studio.secondary)
          }
        }
      }.padding(.horizontal, 12)
      Button {
        model.closeMenu()
        openWindow(id: "equalizer")
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        HStack {
          Text("Open equalizer")
          Spacer()
          Text("⌘⇧E").font(.system(size: 10, weight: .regular)).opacity(0.45)
          Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
        }.frame(maxWidth: .infinity).padding(.vertical, 2)
      }
      .buttonStyle(StudioButtonStyle())
      .keyboardShortcut("e", modifiers: [.command, .shift])
      HStack {
        PopupMenuButton {
          let menu = ActionMenu()
          menu.choice(
            "Launch at Login", selected: model.launchAtLogin, enabled: model.isInstalledApp
          ) {
            model.setLaunchAtLogin(!model.launchAtLogin)
          }
          menu.choice("Background Items…") { model.showAudioSetup() }
          return menu
        } label: {
          Label("Options", systemImage: "gearshape").font(.system(size: 10))
        }
        .fixedSize()
        Spacer()
        Button("Quit myEq") { NSApp.terminate(nil) }
          .buttonStyle(.plain).font(.system(size: 10)).keyboardShortcut("q")
      }.foregroundStyle(Studio.secondary)
    }
    .padding(20).frame(width: 354)
    .foregroundStyle(Studio.ink).tint(Studio.accent)
    .background(Studio.background)
    .background(
      EditorVisibilityObserver(onChange: model.setMenuVisible, onWindow: { model.menuWindow = $0 })
    )
  }
  private var presetSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        SectionCaption("Your sound")
        Spacer()
        if model.isModified {
          Circle().fill(Studio.accent).frame(width: 4, height: 4)
          Text("Edited").font(.system(size: 9)).foregroundStyle(Studio.accent)
        }
      }
      PopupMenuButton {
        let menu = ActionMenu()
        for preset in model.allPresets {
          menu.choice(preset.name, selected: preset.id == model.saved.current.id) {
            model.selectPreset(preset.id)
          }
        }
        return menu
      } label: {
        HStack {
          Text(model.saved.current.name).font(.system(size: 23, weight: .medium))
            .tracking(-0.6).lineLimit(1)
          Spacer()
          Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            .foregroundStyle(Studio.secondary)
        }.foregroundStyle(Studio.ink).contentShape(Rectangle())
      }
      .accessibilityLabel("Choose preset").accessibilityValue(model.saved.current.name)
      .help(model.saved.current.name)
      MiniResponseGraph(values: model.menuCurve, enabled: model.saved.enabled)
        .frame(height: 90)
    }
    .padding(15).background(RoundedRectangle(cornerRadius: 14).fill(Studio.surface))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.line))
  }

}

struct MiniResponseGraph: View {
  let values: [Double]
  let enabled: Bool
  var body: some View {
    Canvas { context, size in
      let plot = CGRect(x: 1, y: 4, width: size.width - 2, height: size.height - 22)
      for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
        var line = Path()
        let x = plot.minX + fraction * plot.width
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(line, with: .color(.white.opacity(0.035)), lineWidth: 1)
      }
      var zero = Path()
      zero.move(to: CGPoint(x: plot.minX, y: plot.midY))
      zero.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
      context.stroke(
        zero, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
      var curve = Path()
      for (index, value) in values.enumerated() {
        let point = CGPoint(
          x: plot.minX + Double(index) / Double(max(1, values.count - 1)) * plot.width,
          y: plot.midY - min(24, max(-24, value)) / 48 * plot.height)
        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
      }
      if !values.isEmpty {
        var fill = curve
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        fill.closeSubpath()
        context.fill(
          fill,
          with: .linearGradient(
            Gradient(colors: [Studio.accent.opacity(enabled ? 0.15 : 0.04), .clear]),
            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        context.stroke(
          curve, with: .color(Studio.accent.opacity(enabled ? 0.9 : 0.3)),
          style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
      }
      for (text, fraction) in [("20", 0.03), ("1k", 0.57), ("20k", 0.95)] {
        context.draw(
          Text(text).font(.system(size: 8, design: .monospaced)).foregroundColor(
            Studio.secondary.opacity(0.7)),
          at: CGPoint(x: plot.minX + fraction * plot.width, y: size.height - 5))
      }
    }
    .accessibilityLabel("Preset frequency response")
    .accessibilityValue(enabled ? "Equalizer enabled" : "Equalizer bypassed")
  }
}
