import MyEqCore
import SwiftUI

struct EqualizerView: View {
  @ObservedObject var model: AppModel
  @State private var presetSheet = false
  @State private var presetName = ""
  @State private var duplicate = true
  @State private var confirmDelete = false
  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.5)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let message = model.message {
            HStack(alignment: .top) {
              Image(systemName: "info.circle").foregroundStyle(.orange)
              Text(message).font(.callout)
              Spacer()
              Button {
                model.message = nil
              } label: {
                Image(systemName: "xmark")
              }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
            }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
          }
          if let detail = model.engineStatus.state.detail { statusBanner(detail) }
          if model.engineStatus.outputName.localizedCaseInsensitiveContains("eqMac") {
            Label(
              "An eqMac output is selected. Choose your physical speakers in macOS when replacing eqMac to avoid applying EQ twice.",
              systemImage: "info.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          presetBar
          preampBar
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("FREQUENCY RESPONSE").font(
                .system(size: 10, weight: .semibold, design: .rounded)
              ).tracking(1.6).foregroundStyle(.secondary)
              Spacer()
              HStack(spacing: 5) {
                Capsule().fill(.white.opacity(0.8)).frame(width: 15, height: 2)
                Text("Combined + preamp").font(.caption).foregroundStyle(.secondary)
              }
            }
            ResponseGraph(model: model).frame(height: 250)
          }.padding(18).background(
            Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
          HStack(alignment: .top, spacing: 8) {
            ForEach(0..<8) { BandStrip(model: model, index: $0) }
          }
          footer
        }.padding(24)
      }
    }
    .frame(minWidth: 980, minHeight: 760)
    .background(Color(red: 0.075, green: 0.085, blue: 0.10))
    .sheet(isPresented: $presetSheet) { presetEditor }
    .confirmationDialog(
      "Delete \(model.saved.current.name)?", isPresented: $confirmDelete, titleVisibility: .visible
    ) {
      Button("Delete Preset", role: .destructive) { model.deletePreset() }
    }
  }
  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "slider.horizontal.3").font(.system(size: 23, weight: .medium))
        .foregroundStyle(Color.mint)
        .frame(width: 44, height: 44).background(
          .mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 3) {
        Text("myEq").font(.system(size: 24, weight: .semibold, design: .rounded))
        Text("SYSTEM EQUALIZER").font(.system(size: 9, weight: .medium)).tracking(2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        HStack(spacing: 6) {
          Circle().fill(model.engineStatus.state == .running ? Color.mint : Color.secondary).frame(
            width: 6, height: 6)
          Text(model.engineStatus.state.title).font(.callout.weight(.medium))
        }
        Picker(
          "Output",
          selection: Binding(
            get: { model.engineStatus.selectedOutputUID ?? "" }, set: { model.selectOutput($0) })
        ) {
          if model.engineStatus.outputs.isEmpty { Text("No output connected").tag("") }
          ForEach(model.engineStatus.outputs) { Text($0.name).tag($0.id) }
        }.labelsHidden().frame(width: 220).controlSize(.small)
      }
      Toggle(
        "Enable EQ", isOn: Binding(get: { model.saved.enabled }, set: { model.setEnabled($0) })
      ).labelsHidden().toggleStyle(.switch).tint(.mint).accessibilityLabel("Enable equalizer")
        .disabled(model.installationIssue != nil)
    }.padding(.horizontal, 26).padding(.vertical, 20)
  }
  private var presetBar: some View {
    HStack(spacing: 12) {
      Text("Preset").font(.callout).foregroundStyle(.secondary)
      Picker(
        "Preset",
        selection: Binding(get: { model.saved.current.id }, set: { model.selectPreset($0) })
      ) {
        ForEach(model.allPresets) { Text($0.name).tag($0.id) }
      }.labelsHidden().frame(width: 240)
      if model.isModified { Text("Edited").font(.caption).foregroundStyle(.secondary) }
      Button("Save As…") {
        duplicate = true
        presetName = model.saved.current.name + " copy"
        presetSheet = true
      }
      Menu {
        Button("Save Changes") {
          model.savePreset(name: model.saved.current.name, duplicate: false)
        }.disabled(model.saved.current.isFactory)
        Button("Rename…") {
          duplicate = false
          presetName = model.saved.current.name
          presetSheet = true
        }.disabled(model.saved.current.isFactory)
        Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(
          model.saved.current.isFactory)
        Divider()
        Button("Restore Saved Preset") { model.selectPreset(model.saved.current.id) }
        Button("Reset to Flat") { model.selectPreset(EQPreset.flat.id) }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).frame(width: 25).accessibilityLabel("Preset actions")
      Spacer()
      Text("8 BANDS · STEREO").font(.system(size: 10, weight: .medium)).tracking(1.3)
        .foregroundStyle(.tertiary)
    }
  }
  private var preampBar: some View {
    HStack(spacing: 16) {
      Image(systemName: "waveform").foregroundStyle(.mint)
      Text("Preamp").font(.callout.weight(.medium))
      Slider(
        value: Binding(
          get: {
            model.saved.current.autoPreamp
              ? model.effectivePreamp : model.saved.current.manualPreamp
          }, set: { v in model.edit { $0.manualPreamp = v } }), in: -60...12
      )
      .disabled(model.saved.current.autoPreamp).tint(.mint).accessibilityLabel("Manual preamp")
      Text(String(format: "%+.1f dB", model.effectivePreamp)).font(
        .system(.callout, design: .monospaced)
      ).frame(width: 83, alignment: .trailing)
      Toggle(
        "Auto",
        isOn: Binding(
          get: { model.saved.current.autoPreamp }, set: { v in model.edit { $0.autoPreamp = v } })
      ).toggleStyle(.checkbox).tint(.mint)
      Divider().frame(height: 22)
      Label("Peak guard", systemImage: "checkmark.shield").font(.caption).foregroundStyle(
        .secondary
      ).help("Stereo-linked limiter · −0.5 dBFS ceiling · 1 ms lookahead")
    }.padding(14).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }
  private var footer: some View {
    HStack(spacing: 12) {
      Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
      Text(String(format: "%.1f kHz", model.engineStatus.sampleRate / 1000)).font(
        .caption.monospacedDigit()
      ).foregroundStyle(.secondary)
      Spacer()
      StereoOutputMeter(model: model.outputMeter)
    }
  }
  private func statusBanner(_ detail: String) -> some View {
    HStack {
      Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
      Text(detail).font(.callout)
      Spacer()
      if model.installationIssue == nil {
        Button("Background Items") { model.showAudioSetup() }
        Button("Retry") { model.engine.retry() }
      }
    }.padding(12).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }
  private var presetEditor: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(duplicate ? "Save a new preset" : "Rename preset").font(.title2.weight(.semibold))
      TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder).onSubmit {
        savePreset()
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { presetSheet = false }
        Button("Save") { savePreset() }.keyboardShortcut(.defaultAction).disabled(
          presetName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }.padding(24).frame(width: 360)
  }
  private func savePreset() {
    model.savePreset(name: presetName, duplicate: duplicate)
    presetSheet = false
  }
}

struct BandStrip: View {
  @ObservedObject var model: AppModel
  let index: Int
  private var band: EQBand { model.saved.current.bands[index] }
  private var color: Color { bandColors[index] }
  var body: some View {
    VStack(spacing: 13) {
      HStack {
        Text(String(format: "%02d", index + 1)).font(
          .system(size: 11, weight: .semibold, design: .monospaced)
        ).foregroundStyle(color)
        Spacer()
        Toggle("Band \(index+1)", isOn: model.bandBinding(index, \.enabled)).labelsHidden()
          .toggleStyle(.checkbox).tint(color)
      }
      Picker(
        "Filter for band \(index+1)",
        selection: Binding(get: { band.type }, set: { model.setFilter($0, index: index) })
      ) {
        ForEach(FilterType.allCases) { Text($0.name).tag($0) }
      }.labelsHidden().controlSize(.small)
      VStack(spacing: 5) {
        Text("FREQUENCY").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(
          .secondary)
        NumericField(
          label: "Band \(index+1) frequency", value: model.bandBinding(index, \.frequency),
          range: 20...model.frequencyLimit, decimals: 0, suffix: "Hz")
      }
      GainFader(
        value: model.bandBinding(index, \.gain), color: color,
        enabled: band.enabled && band.type.hasGain
      )
      .frame(height: 156)
      .accessibilityLabel("Band \(index+1) gain")
      NumericField(
        label: "Band \(index+1) gain", value: model.bandBinding(index, \.gain), range: -24...24,
        decimals: 1, suffix: "dB"
      ).disabled(!band.type.hasGain)
      VStack(spacing: 5) {
        Text(band.type.widthLabel.uppercased()).font(.system(size: 8, weight: .medium)).tracking(
          0.8
        ).foregroundStyle(.secondary)
        NumericField(
          label: "Band \(index+1) \(band.type.widthLabel)",
          value: model.bandBinding(index, \.width), range: band.type.widthRange, decimals: 3,
          suffix: "")
        Slider(value: model.bandBinding(index, \.width), in: band.type.widthRange).controlSize(
          .mini
        ).tint(color).accessibilityLabel("Band \(index+1) width")
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(color.opacity(band.enabled ? 0.045 : 0.015))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12).strokeBorder(
        color.opacity(model.selectedBand == index ? 0.5 : 0.12), lineWidth: 1)
    )
    .opacity(band.enabled ? 1 : 0.52)
    .onTapGesture { model.selectedBand = index }
    .frame(maxWidth: .infinity)
  }
}

struct NumericField: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let decimals: Int
  let suffix: String
  var body: some View {
    HStack(spacing: 2) {
      TextField(
        label,
        value: Binding(
          get: { value },
          set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } }),
        format: .number.precision(.fractionLength(decimals))
      )
      .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(
        .system(size: 12, weight: .medium, design: .monospaced)
      ).accessibilityLabel(label)
      if !suffix.isEmpty { Text(suffix).font(.system(size: 9)).foregroundStyle(.secondary) }
    }.padding(.horizontal, 6).padding(.vertical, 7).background(
      .black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
  }
}

struct GainFader: View {
  @Binding var value: Double
  let color: Color
  let enabled: Bool
  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height - 18
      let y = 9 + (24 - value) / 48 * height
      ZStack {
        ForEach(-4..<5) { mark in
          HStack {
            Rectangle().fill(.white.opacity(mark == 0 ? 0.25 : 0.08)).frame(
              width: mark == 0 ? 15 : 9, height: 1)
            Spacer()
            Rectangle().fill(.white.opacity(mark == 0 ? 0.25 : 0.08)).frame(
              width: mark == 0 ? 15 : 9, height: 1)
          }
          .position(x: proxy.size.width / 2, y: 9 + Double(mark + 4) / 8 * height)
        }
        Capsule().fill(.black.opacity(0.4)).frame(width: 5, height: height)
        Capsule().fill(color.opacity(0.65)).frame(width: 3, height: abs(y - proxy.size.height / 2))
          .position(x: proxy.size.width / 2, y: (y + proxy.size.height / 2) / 2)
        RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.19)).frame(width: 34, height: 20)
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.12))).overlay(
            Rectangle().fill(color).frame(width: 22, height: 2)
          ).position(x: proxy.size.width / 2, y: y)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { gesture in
          if enabled { value = min(24, max(-24, 24 - (gesture.location.y - 9) / height * 48)) }
        }
      )
      .onTapGesture(count: 2) { if enabled { value = 0 } }
    }
    .opacity(enabled ? 1 : 0.3)
    .accessibilityElement()
    .accessibilityValue(String(format: "%.1f decibels", value))
    .accessibilityAdjustableAction { direction in
      guard enabled else { return }
      value = min(24, max(-24, value + (direction == .increment ? 0.5 : -0.5)))
    }
  }
}
