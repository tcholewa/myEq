import MyEqCore
import SwiftUI

struct BandStrip: View {
  @ObservedObject var model: AppModel
  let index: Int
  var compact = false
  private var band: EQBand { model.saved.current.bands[index] }
  private var color: Color { bandColors[index] }
  private var selected: Bool { model.selectedBand == index }
  @State private var hovering = false

  var body: some View {
    VStack(spacing: compact ? 8 : 10) {
      HStack {
        Button {
          model.selectedBand = index
        } label: {
          HStack(spacing: 6) {
            Circle().fill(band.enabled ? color : Studio.secondary).frame(width: 5, height: 5)
            Text(String(format: "%02d", index + 1))
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
          }.foregroundStyle(selected ? color : Studio.secondary)
        }.buttonStyle(.plain).accessibilityLabel("Select band \(index + 1)")
        Spacer()
        Button {
          model.edit { $0.bands[index].enabled.toggle() }
        } label: {
          Image(systemName: "power").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(band.enabled ? color : Studio.secondary)
            .frame(width: 23, height: 23)
            .background(Circle().fill(band.enabled ? color.opacity(0.10) : .white.opacity(0.025)))
        }.buttonStyle(.plain)
          .accessibilityLabel("\(band.enabled ? "Disable" : "Enable") band \(index + 1)")
          .accessibilityValue(band.enabled ? "On" : "Off")
      }
      PopupMenuButton {
        let menu = ActionMenu()
        for type in FilterType.allCases {
          menu.choice(type.name, selected: band.type == type) {
            model.setFilter(type, index: index)
          }
        }
        return menu
      } label: {
        HStack(spacing: 6) {
          FilterGlyph(type: band.type).stroke(color.opacity(0.8), lineWidth: 1.3)
            .frame(width: 20, height: 12)
          Text(band.type.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            .foregroundStyle(Studio.secondary)
        }.foregroundStyle(Studio.secondary).padding(.vertical, 4).contentShape(Rectangle())
      }
      .accessibilityLabel("Filter for band \(index + 1)").accessibilityValue(band.type.name)
      VStack(spacing: 4) {
        NumericField(
          label: "Band \(index + 1) frequency", value: model.bandBinding(index, \.frequency),
          range: 20...model.frequencyLimit, decimals: 0, suffix: "Hz", large: true)
        Text(frequencyRegion).font(.system(size: 8, weight: .medium)).tracking(1)
          .foregroundStyle(Studio.secondary.opacity(0.65))
      }
      GainFader(
        value: model.bandBinding(index, \.gain), color: color,
        enabled: band.enabled && band.type.hasGain
      )
      .frame(height: compact ? 80 : 106).accessibilityLabel("Band \(index + 1) gain")
      NumericField(
        label: "Band \(index + 1) gain", value: model.bandBinding(index, \.gain),
        range: -24...24, decimals: 1, suffix: "dB", signed: true, tint: color
      )
      .disabled(!band.type.hasGain)
      Rectangle().fill(Studio.line).frame(height: 1).padding(.vertical, 1)
      HStack(spacing: 5) {
        WidthKnob(
          value: model.bandBinding(index, \.width), range: band.type.widthRange,
          defaultValue: band.type.defaultWidth, color: color
        )
        .frame(width: 29, height: 29)
        .accessibilityLabel("Band \(index + 1) \(band.type.widthLabel)")
        VStack(alignment: .leading, spacing: 2) {
          Text(band.type == .bell ? "WIDTH · OCT" : band.type.widthLabel.uppercased())
            .font(.system(size: 7, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Studio.secondary)
          NumericField(
            label: "Band \(index + 1) \(band.type.widthLabel)",
            value: model.bandBinding(index, \.width), range: band.type.widthRange,
            decimals: 3, suffix: "", inset: false)
        }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(
          selected ? color.opacity(0.055) : (hovering ? Studio.raised.opacity(0.6) : Studio.surface)
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? color.opacity(0.38) : Studio.line)
    )
    .overlay(alignment: .top) {
      Capsule().fill(color.opacity(selected ? 0.9 : (band.enabled ? 0.32 : 0.08)))
        .frame(width: 26, height: 2)
    }
    .opacity(band.enabled ? 1 : 0.5)
    .onHover { hovering = $0 }
    .simultaneousGesture(TapGesture().onEnded { model.selectedBand = index })
    .frame(maxWidth: .infinity)
    .contextMenu {
      Button("Reset gain to 0 dB") { model.edit { $0.bands[index].gain = 0 } }
        .disabled(!band.type.hasGain)
      Button("Reset \(band.type.widthLabel.lowercased())") {
        model.edit { $0.bands[index].width = band.type.defaultWidth }
      }
    }
  }
  private var frequencyRegion: String {
    switch band.frequency {
    case ..<80: return "SUB"
    case ..<250: return "BASS"
    case ..<1000: return "LOW MID"
    case ..<3000: return "MID"
    case ..<8000: return "PRESENCE"
    default: return "AIR"
    }
  }
}

struct NumericField: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let decimals: Int
  let suffix: String
  var large = false
  var signed = false
  var tint = Studio.ink
  var inset = true
  @FocusState private var focused: Bool
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      TextField(
        label,
        value: Binding(
          get: { value },
          set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } }),
        format: .number.grouping(.never).precision(.fractionLength(decimals))
          .sign(strategy: signed ? .always(includingZero: false) : .automatic)
      )
      .textFieldStyle(.plain).multilineTextAlignment(.trailing)
      .font(.system(size: large ? 20 : 11, weight: large ? .medium : .regular, design: .monospaced))
      .foregroundStyle(tint).focused($focused).accessibilityLabel(label)
      .onSubmit { focused = false }
      if !suffix.isEmpty {
        Text(suffix).font(.system(size: large ? 9 : 8)).foregroundStyle(Studio.secondary)
      }
    }
    .padding(.horizontal, inset ? 7 : 0).padding(.vertical, inset ? (large ? 4 : 6) : 0)
    .background(
      RoundedRectangle(cornerRadius: 7).fill(inset && !large ? .black.opacity(0.20) : .clear)
    )
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? tint.opacity(0.45) : .clear))
  }
}

struct GainFader: View {
  @Binding var value: Double
  let color: Color
  let enabled: Bool
  @State private var isDragging = false
  var body: some View {
    GeometryReader { proxy in
      let height = max(1, proxy.size.height - 18)
      let y = 9 + (24 - value) / 48 * height
      ZStack {
        ForEach(-4..<5) { mark in
          HStack {
            Rectangle().fill(.white.opacity(mark == 0 ? 0.26 : 0.07))
              .frame(width: mark == 0 ? 12 : 5, height: 1)
            Spacer()
            Rectangle().fill(.white.opacity(mark == 0 ? 0.26 : 0.07))
              .frame(width: mark == 0 ? 12 : 5, height: 1)
          }.position(x: proxy.size.width / 2, y: 9 + Double(mark + 4) / 8 * height)
        }
        Capsule().fill(.black.opacity(0.48)).frame(width: 4, height: height)
          .overlay(Capsule().strokeBorder(.white.opacity(0.025)))
        Capsule().fill(color.opacity(0.55)).frame(width: 2, height: abs(y - proxy.size.height / 2))
          .position(x: proxy.size.width / 2, y: (y + proxy.size.height / 2) / 2)
        RoundedRectangle(cornerRadius: 5)
          .fill(
            LinearGradient(
              colors: [Color(white: 0.30), Color(white: 0.20)],
              startPoint: .top, endPoint: .bottom)
          )
          .frame(width: 30, height: 18)
          .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(isDragging ? 0.25 : 0.12))
          )
          .overlay(Capsule().fill(color).frame(width: 17, height: 2))
          .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
          .position(x: proxy.size.width / 2, y: y)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { gesture in
          guard enabled else { return }
          isDragging = true
          value = min(24, max(-24, 24 - (gesture.location.y - 9) / height * 48))
        }.onEnded { _ in isDragging = false }
      )
      .onTapGesture(count: 2) { if enabled { value = 0 } }
    }
    .opacity(enabled ? 1 : 0.3).accessibilityElement()
    .accessibilityValue(String(format: "%+.1f decibels", value))
    .accessibilityAdjustableAction { direction in
      guard enabled else { return }
      value = min(24, max(-24, value + (direction == .increment ? 0.5 : -0.5)))
    }
    .help("Drag to adjust gain. Double-click to reset to 0 dB.")
  }
}

struct WidthKnob: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let defaultValue: Double
  let color: Color
  @State private var start: Double?
  private var normalized: Double {
    min(1, max(0, log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)))
  }
  private func setNormalized(_ position: Double) {
    value = range.lowerBound * pow(range.upperBound / range.lowerBound, min(1, max(0, position)))
  }
  var body: some View {
    ZStack {
      Circle().trim(from: 0, to: 0.75)
        .stroke(.white.opacity(0.10), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(135))
      Circle().trim(from: 0, to: normalized * 0.75)
        .stroke(color.opacity(0.65), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(135))
      Circle().fill(Studio.raised).padding(4)
      Capsule().fill(color).frame(width: 1.5, height: 5).offset(y: -7)
        .rotationEffect(.degrees(-135 + normalized * 270))
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { gesture in
        if start == nil { start = normalized }
        setNormalized((start ?? normalized) - gesture.translation.height / 120)
      }.onEnded { _ in start = nil }
    )
    .onTapGesture(count: 2) { value = defaultValue }
    .accessibilityElement().accessibilityValue(String(format: "%.3f", value))
    .accessibilityAdjustableAction { direction in
      setNormalized(normalized + (direction == .increment ? 0.025 : -0.025))
    }
    .help("Drag up or down to adjust. Double-click to reset.")
  }
}
