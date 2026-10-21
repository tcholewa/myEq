import MyEqCore
import SwiftUI

@MainActor
final class OutputMeterModel: ObservableObject {
  @Published private(set) var envelope = OutputMeterEnvelope()
  private var lastUpdate = ProcessInfo.processInfo.systemUptime

  func update(_ levels: OutputLevels) {
    let now = ProcessInfo.processInfo.systemUptime
    var next = envelope
    next.update(levels, elapsed: now - lastUpdate)
    lastUpdate = now
    if next != envelope { envelope = next }
  }
}

/// Isolates 60 Hz meter observation from the graph and editable band controls.
struct StereoOutputMeter: View {
  @ObservedObject var model: OutputMeterModel

  var body: some View {
    HStack(spacing: 14) {
      Text("Output").font(.caption).foregroundStyle(.secondary)
      VStack(spacing: 5) {
        channel("L", decibels: model.envelope.leftDB, peakDB: model.envelope.leftPeakDB)
        channel("R", decibels: model.envelope.rightDB, peakDB: model.envelope.rightPeakDB)
      }
      Text(String(format: "Guard %.1f dB", model.envelope.reductionDB))
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(model.envelope.reductionDB > 0.1 ? .orange : .secondary)
        .frame(width: 95, alignment: .trailing)
    }
    .help(
      "Left and right output levels after EQ and peak protection, from −60 to 0 dBFS. White peak markers hold for one second, then fall slowly."
    )
  }

  private func channel(_ label: String, decibels: Double, peakDB: Double) -> some View {
    HStack(spacing: 8) {
      Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary).frame(width: 9)
      GeometryReader { proxy in
        let fraction = (decibels - OutputMeterEnvelope.floorDB) / -OutputMeterEnvelope.floorDB
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.07))
          LinearGradient(
            stops: [
              .init(color: .mint, location: 0), .init(color: .mint, location: 0.8),
              .init(color: .yellow, location: 0.9), .init(color: .orange, location: 0.98),
              .init(color: .red, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
          )
          .mask(alignment: .leading) {
            Rectangle().frame(width: proxy.size.width * fraction)
          }
        }
        .clipShape(Capsule())
        .overlay(alignment: .leading) {
          if peakDB > OutputMeterEnvelope.floorDB {
            let peakFraction = (peakDB - OutputMeterEnvelope.floorDB) / -OutputMeterEnvelope.floorDB
            RoundedRectangle(cornerRadius: 1)
              .fill(.white)
              .frame(width: 2, height: proxy.size.height)
              .offset(x: max(0, min(proxy.size.width - 2, proxy.size.width * peakFraction - 1)))
          }
        }
      }.frame(width: 180, height: 6)
      Text(
        decibels > OutputMeterEnvelope.floorDB ? String(format: "%.1f dBFS", decibels) : "−∞ dBFS"
      )
      .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
      .frame(width: 72, alignment: .trailing)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label == "L" ? "Left output" : "Right output")
    .accessibilityValue(
      (decibels > OutputMeterEnvelope.floorDB ? String(format: "%.1f dBFS", decibels) : "Silent")
        + (peakDB > OutputMeterEnvelope.floorDB ? String(format: ", peak %.1f dBFS", peakDB) : ""))
  }
}
