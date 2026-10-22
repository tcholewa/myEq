import AppKit
import MyEqCore
import SwiftUI

enum Studio {
  static let background = Color(red: 0.055, green: 0.060, blue: 0.068)
  static let surface = Color(red: 0.085, green: 0.092, blue: 0.104)
  static let raised = Color(red: 0.12, green: 0.13, blue: 0.145)
  static let ink = Color(red: 0.94, green: 0.93, blue: 0.89)
  static let secondary = Color(red: 0.57, green: 0.59, blue: 0.61)
  static let accent = Color(red: 0.91, green: 0.79, blue: 0.57)
  static let active = Color(red: 0.60, green: 0.79, blue: 0.65)
  static let line = Color.white.opacity(0.075)
  static let statusIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      for (x, y) in [(4.0, 11.0), (10.0, 6.0), (16.0, 9.0)] {
        let stem = NSBezierPath()
        stem.lineWidth = 1.2
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: x, y: 3))
        stem.line(to: NSPoint(x: x, y: 15))
        stem.stroke()
        NSBezierPath(
          roundedRect: NSRect(x: x - 2.5, y: y - 1.2, width: 5, height: 2.4),
          xRadius: 0.9, yRadius: 0.9
        ).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }()

  static func statusColor(_ state: AudioEngineState) -> Color {
    switch state {
    case .running: return active
    case .error, .suspended: return .orange
    case .starting, .reconnecting: return accent
    case .bypassed: return secondary
    }
  }
  static func frequency(_ value: Double) -> String {
    value >= 1000
      ? String(format: "%.2g kHz", value / 1000) : String(format: "%.0f Hz", value)
  }
}

struct SectionCaption: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title.uppercased())
      .font(.system(size: 9, weight: .semibold)).tracking(1.6)
      .foregroundStyle(Studio.secondary)
  }
}

struct EqualizerMark: View {
  var color = Studio.accent
  var body: some View {
    Canvas { context, size in
      let positions: [CGFloat] = [0.34, 0.64, 0.43]
      for index in 0..<3 {
        let x = size.width * CGFloat(index + 1) / 4
        var line = Path()
        line.move(to: CGPoint(x: x, y: size.height * 0.16))
        line.addLine(to: CGPoint(x: x, y: size.height * 0.84))
        context.stroke(
          line, with: .color(color.opacity(0.36)),
          style: StrokeStyle(lineWidth: size.width * 0.045, lineCap: .round))
        let thumb = CGRect(
          x: x - size.width * 0.075,
          y: size.height * positions[index] - size.height * 0.04,
          width: size.width * 0.15, height: size.height * 0.08)
        context.fill(
          Path(roundedRect: thumb, cornerRadius: size.width * 0.025),
          with: .color(color))
      }
    }.accessibilityHidden(true)
  }
}

struct StudioButtonStyle: ButtonStyle {
  var prominent = false
  var compact = false
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: compact ? 11 : 12, weight: .medium))
      .padding(.horizontal, compact ? 10 : 14)
      .padding(.vertical, compact ? 7 : 10)
      .foregroundStyle(prominent ? Studio.background : Studio.ink)
      .background(
        RoundedRectangle(cornerRadius: compact ? 8 : 10)
          .fill(
            prominent ? Studio.ink : Color.white.opacity(configuration.isPressed ? 0.10 : 0.055))
      )
      .overlay(
        RoundedRectangle(cornerRadius: compact ? 8 : 10)
          .strokeBorder(prominent ? .clear : Studio.line)
      )
      .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.35)
  }
}

struct PowerControl: View {
  @ObservedObject var model: AppModel
  var compact = false
  var body: some View {
    Button {
      model.setEnabled(!model.saved.enabled)
    } label: {
      HStack(spacing: 9) {
        Image(systemName: "power")
          .font(.system(size: compact ? 15 : 13, weight: .semibold))
        if !compact {
          Text(model.saved.enabled ? "EQ on" : "Bypassed").font(
            .system(size: 12, weight: .semibold))
        }
      }
      .foregroundStyle(model.saved.enabled ? Studio.background : Studio.secondary)
      .frame(width: compact ? 40 : 102, height: 40)
      .background(
        RoundedRectangle(cornerRadius: compact ? 13 : 12)
          .fill(model.saved.enabled ? Studio.accent : Studio.raised)
      )
      .overlay(RoundedRectangle(cornerRadius: compact ? 13 : 12).strokeBorder(.white.opacity(0.07)))
    }
    .buttonStyle(.plain)
    .disabled(model.installationIssue != nil)
    .accessibilityLabel(model.saved.enabled ? "Bypass equalizer" : "Enable equalizer")
    .accessibilityValue(model.saved.enabled ? "Enabled" : "Bypassed")
    .help(model.saved.enabled ? "Bypass EQ · ⌘E" : "Enable EQ · ⌘E")
  }
}

struct OutputSelector: View {
  @ObservedObject var model: AppModel
  var compact = false
  var body: some View {
    PopupMenuButton {
      let menu = ActionMenu()
      if model.engineStatus.outputs.isEmpty {
        menu.choice(
          model.engineStatus.state == .starting ? "Connecting to audio…" : "No output connected",
          enabled: false
        ) {}
      }
      for output in model.engineStatus.outputs {
        menu.choice(output.name, selected: output.id == model.engineStatus.selectedOutputUID) {
          model.selectOutput(output.id)
        }
      }
      return menu
    } label: {
      HStack(spacing: 11) {
        Image(systemName: "hifispeaker")
          .font(.system(size: compact ? 18 : 16, weight: .light))
          .foregroundStyle(Studio.accent)
        VStack(alignment: .leading, spacing: 4) {
          SectionCaption(compact ? "Output" : "Playing through")
          Text(model.engineStatus.outputName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Studio.ink).lineLimit(1)
        }
        Spacer(minLength: 10)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(Studio.secondary)
      }
      .padding(.horizontal, compact ? 14 : 12).padding(.vertical, compact ? 14 : 8)
      .background(RoundedRectangle(cornerRadius: 12).fill(compact ? Studio.surface : .clear))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(compact ? Studio.line : .clear))
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Audio output")
    .accessibilityValue(model.engineStatus.outputName)
    .help("\(model.engineStatus.outputName) · Choose speakers or headphones")
  }
}

struct StatusLabel: View {
  let state: AudioEngineState
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(Studio.statusColor(state)).frame(width: 5, height: 5)
      Text(state.title).font(.system(size: 11, weight: .medium))
        .foregroundStyle(Studio.secondary)
    }
  }
}

struct FilterGlyph: Shape {
  let type: FilterType
  func path(in rect: CGRect) -> Path {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
    return Path { path in
      switch type {
      case .bell:
        path.move(to: p(0, 0.8))
        path.addCurve(to: p(0.5, 0.15), control1: p(0.36, 0.8), control2: p(0.32, 0.15))
        path.addCurve(to: p(1, 0.8), control1: p(0.68, 0.15), control2: p(0.64, 0.8))
      case .lowShelf:
        path.move(to: p(0, 0.2))
        path.addLine(to: p(0.25, 0.2))
        path.addCurve(to: p(0.75, 0.8), control1: p(0.5, 0.2), control2: p(0.5, 0.8))
        path.addLine(to: p(1, 0.8))
      case .highShelf:
        path.move(to: p(0, 0.8))
        path.addLine(to: p(0.25, 0.8))
        path.addCurve(to: p(0.75, 0.2), control1: p(0.5, 0.8), control2: p(0.5, 0.2))
        path.addLine(to: p(1, 0.2))
      case .lowCut:
        path.move(to: p(0.1, 1))
        path.addCurve(to: p(0.7, 0.2), control1: p(0.4, 1), control2: p(0.4, 0.2))
        path.addLine(to: p(1, 0.2))
      case .highCut:
        path.move(to: p(0, 0.2))
        path.addLine(to: p(0.3, 0.2))
        path.addCurve(to: p(0.9, 1), control1: p(0.6, 0.2), control2: p(0.6, 1))
      }
    }
  }
}
