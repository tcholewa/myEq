import MyEqCore
import SwiftUI

struct EqualizerView: View {
  @ObservedObject var model: AppModel
  @State private var presetSheet = false
  @State private var presetName = ""
  @State private var duplicate = true
  @State private var confirmDelete = false
  @State private var selectionRegions: [SelectionRegion: CGRect] = [:]

  var body: some View {
    GeometryReader { geometry in
      editor(compact: geometry.size.height < 820)
    }
    .coordinateSpace(name: "equalizer")
    .onPreferenceChange(SelectionRegionsKey.self) { selectionRegions = $0 }
    .background(BandSelectionObserver(regions: selectionRegions) { model.selectedBand = $0 })
    .frame(minWidth: 1040, minHeight: 740)
    .foregroundStyle(Studio.ink)
    .background(Studio.background)
    .tint(Studio.accent)
    .sheet(isPresented: $presetSheet) { presetEditor }
    .confirmationDialog(
      "Delete \(model.saved.current.name)?", isPresented: $confirmDelete, titleVisibility: .visible
    ) {
      Button("Delete Preset", role: .destructive) { model.deletePreset() }
    }
  }

  private func editor(compact: Bool) -> some View {
    VStack(spacing: 0) {
      header(compact: compact)
      Rectangle().fill(Studio.line).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
          if let message = model.message { notice(message, dismissible: true) }
          if let detail = model.engineStatus.state.detail { notice(detail, dismissible: false) }
          presetBar
          responseSection(compact: compact)
          VStack(spacing: 10) {
            HStack {
              SectionCaption("Shape your sound")
              Spacer()
              Text("Drag to tune · Double-click a fader to reset")
                .font(.system(size: 10)).foregroundStyle(Studio.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
              ForEach(0..<8) { BandStrip(model: model, index: $0, compact: compact) }
            }
          }
        }.padding(.horizontal, 26).padding(.vertical, compact ? 8 : 20)
      }.selectionRegion(.content)
      footer
    }
  }
  private func header(compact: Bool) -> some View {
    HStack(spacing: 12) {
      EqualizerMark().frame(width: 34, height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Studio.accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Studio.accent.opacity(0.10)))
      Text("myEq").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.7)
      Rectangle().fill(Studio.line).frame(width: 1, height: 18).padding(.horizontal, 6)
      Text("Make it sound like you.").font(.system(size: 11)).foregroundStyle(Studio.secondary)
      Spacer()
      OutputSelector(model: model).frame(width: 244)
      PowerControl(model: model).padding(.leading, 8)
    }.padding(.horizontal, 26).padding(.vertical, compact ? 8 : 14)
  }
  private var presetBar: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 7) {
        SectionCaption("Your sound")
        PopupMenuButton {
          let menu = ActionMenu()
          for preset in model.allPresets {
            menu.choice(preset.name, selected: preset.id == model.saved.current.id) {
              model.selectPreset(preset.id)
            }
          }
          return menu
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.saved.current.name)
              .font(.system(size: 29, weight: .medium)).tracking(-0.9).lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.system(size: 11, weight: .semibold)).foregroundStyle(Studio.secondary)
            if model.isModified {
              Text("Edited").font(.system(size: 10, weight: .medium))
                .foregroundStyle(Studio.accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Studio.accent.opacity(0.08)))
            }
          }.foregroundStyle(Studio.ink).contentShape(Rectangle())
        }
        .fixedSize(
          horizontal: false, vertical: true
        )
        .accessibilityLabel("Choose preset").accessibilityValue(model.saved.current.name)
        .help(model.saved.current.name)
      }
      Spacer(minLength: 24)
      Text("8-band parametric EQ")
        .font(.system(size: 11)).foregroundStyle(Studio.secondary).padding(.trailing, 12)
      Button {
        duplicate = true
        presetName = model.saved.current.name + " copy"
        presetSheet = true
      } label: {
        Label("Save preset", systemImage: "plus")
      }.buttonStyle(StudioButtonStyle())
      PopupMenuButton {
        let menu = ActionMenu()
        let editable = !model.saved.current.isFactory
        menu.choice("Save Changes", enabled: editable) {
          model.savePreset(name: model.saved.current.name, duplicate: false)
        }
        menu.choice("Rename…", enabled: editable) {
          duplicate = false
          presetName = model.saved.current.name
          presetSheet = true
        }
        menu.choice("Delete…", enabled: editable) { confirmDelete = true }
        menu.separator()
        menu.choice("Restore Saved Preset") { model.selectPreset(model.saved.current.id) }
        menu.choice("Reset to Flat") { model.selectPreset(EQPreset.flat.id) }
        return menu
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
          .frame(width: 34, height: 34)
          .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.035)))
      }
      .frame(width: 34)
      .accessibilityLabel("Preset actions")
    }.frame(minHeight: 58)
  }
  private func responseSection(compact: Bool) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        SectionCaption("Frequency response")
        Text("STEREO").font(.system(size: 8, weight: .semibold)).tracking(1)
          .foregroundStyle(Studio.secondary.opacity(0.7))
          .padding(.horizontal, 6).padding(.vertical, 3)
          .overlay(Capsule().strokeBorder(Studio.line))
        Spacer()
        if let selected = model.selectedBand {
          let band = model.saved.current.bands[selected]
          Circle().fill(bandColors[band.id]).frame(width: 5, height: 5)
          Text("Band \(band.id + 1)  ·  \(Studio.frequency(band.frequency))")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Studio.ink.opacity(0.7))
          Rectangle().fill(Studio.line).frame(width: 1, height: 11).padding(.horizontal, 4)
        }
        Button {
          model.setSpectrumEnabled(!model.spectrumEnabled)
        } label: {
          Label("Spectrum", systemImage: "waveform.path")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(model.spectrumEnabled ? Studio.active.opacity(0.85) : Studio.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityLabel("Show output spectrum")
        .accessibilityValue(model.spectrumEnabled ? "On" : "Off")
        .help(
          "Filled bars show output after EQ and peak protection. Spectrum levels use a separate scale from EQ gain."
        )
        Capsule().fill(Studio.combinedResponse)
          .frame(width: 14, height: Studio.combinedResponseWidth)
        Text("Combined").font(.system(size: 10)).foregroundStyle(Studio.secondary)
      }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
      ResponseGraph(model: model).frame(height: compact ? 104 : 198)
        .selectionRegion(.graph)
        .padding(.horizontal, 12).padding(.bottom, 4)
      Rectangle().fill(Studio.line).frame(height: 1)
      preampBar
    }
    .background(
      RoundedRectangle(cornerRadius: 18).fill(
        LinearGradient(
          colors: [Studio.surface, Studio.surface.opacity(0.70)],
          startPoint: .topLeading, endPoint: .bottomTrailing))
    )
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Studio.line))
  }
  private var preampBar: some View {
    HStack(spacing: 14) {
      Image(systemName: "waveform.path").foregroundStyle(Studio.active).font(.system(size: 16))
      Text("Preamp").font(.system(size: 11, weight: .medium))
      Text(String(format: "%+.1f", model.effectivePreamp))
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .foregroundStyle(Studio.accent).frame(width: 46, alignment: .trailing)
      Text("dB").font(.system(size: 10)).foregroundStyle(Studio.secondary)
      Slider(
        value: Binding(
          get: {
            model.saved.current.autoPreamp
              ? model.effectivePreamp : model.saved.current.manualPreamp
          }, set: { value in model.edit { $0.manualPreamp = value } }), in: -60...12
      )
      .disabled(model.saved.current.autoPreamp)
      .controlSize(.small).accessibilityLabel("Manual preamp")
      Toggle(
        "Auto",
        isOn: Binding(
          get: { model.saved.current.autoPreamp },
          set: { value in model.edit { $0.autoPreamp = value } })
      ).toggleStyle(StudioSwitchStyle()).font(.system(size: 11))
        .help("Automatically leaves headroom for boosted frequencies")
      Rectangle().fill(Studio.line).frame(width: 1, height: 18).padding(.horizontal, 4)
      Label("Peak protection", systemImage: "checkmark.shield")
        .font(.system(size: 10)).foregroundStyle(Studio.secondary)
        .help("Stereo-linked sample-peak limiter · −0.5 dBFS ceiling · 1 ms lookahead")
    }.padding(.horizontal, 20).padding(.vertical, 13)
  }
  private var footer: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Studio.line).frame(height: 1)
      HStack(spacing: 14) {
        StatusLabel(state: model.engineStatus.state)
        Rectangle().fill(Studio.line).frame(width: 1, height: 12)
        Text(String(format: "%.1f kHz", model.engineStatus.sampleRate / 1000))
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.secondary)
        Text("STEREO").font(.system(size: 8, weight: .semibold)).tracking(1.3)
          .foregroundStyle(Studio.secondary.opacity(0.65))
        Spacer()
        StereoOutputMeter(model: model.outputMeter)
      }.padding(.horizontal, 26).padding(.vertical, 13)
    }.background(Studio.background)
  }
  private func notice(_ detail: String, dismissible: Bool) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: dismissible ? "info.circle" : "exclamationmark.circle")
        .foregroundStyle(Studio.accent)
      Text(detail).font(.system(size: 11)).foregroundStyle(Studio.ink.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if dismissible {
        Button {
          model.message = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).accessibilityLabel("Dismiss message")
      } else if model.installationIssue == nil {
        Button("Background Items") { model.showAudioSetup() }
          .buttonStyle(StudioButtonStyle(compact: true))
        Button("Retry") { model.retryAudio() }.buttonStyle(StudioButtonStyle(compact: true))
      }
    }.padding(14).background(
      RoundedRectangle(cornerRadius: 12).fill(Studio.accent.opacity(0.055))
    ).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Studio.accent.opacity(0.12)))
  }
  private var presetEditor: some View {
    VStack(alignment: .leading, spacing: 20) {
      EqualizerMark().frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 7) {
        Text(duplicate ? "Make this sound yours." : "A new name. Same sound.")
          .font(.system(size: 23, weight: .medium)).tracking(-0.5)
        Text(
          duplicate ? "Save your settings as a personal preset." : "Rename your personal preset."
        )
        .font(.system(size: 12)).foregroundStyle(Studio.secondary)
      }
      TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
        .controlSize(.large).onSubmit { savePreset() }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { presetSheet = false }.buttonStyle(StudioButtonStyle())
        Button("Save preset") { savePreset() }.buttonStyle(StudioButtonStyle(prominent: true))
          .keyboardShortcut(.defaultAction)
          .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(28).frame(width: 390).foregroundStyle(Studio.ink).background(Studio.surface)
  }
  private func savePreset() {
    guard !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.savePreset(name: presetName, duplicate: duplicate)
    presetSheet = false
  }
}
