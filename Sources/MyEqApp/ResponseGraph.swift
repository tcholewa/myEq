import MyEqCore
import SwiftUI

struct ResponseGraph: View {
  @ObservedObject var model: AppModel
  @State private var dragging: Int?
  private let left: CGFloat = 34
  private let right: CGFloat = 12
  private let top: CGFloat = 12
  private let bottom: CGFloat = 26
  var body: some View {
    GeometryReader { proxy in
      let frequencyLimit = model.frequencyLimit
      let plot = CGRect(
        x: left, y: top, width: proxy.size.width - left - right,
        height: proxy.size.height - top - bottom)
      Canvas { context, _ in
        guard model.isEditorVisible else { return }
        func x(_ f: Double) -> CGFloat {
          plot.minX + log(f / 20) / log(frequencyLimit / 20) * plot.width
        }
        func y(_ db: Double) -> CGFloat { plot.midY - db / 24 * plot.height / 2 }
        for db in stride(from: -24, through: 24, by: 12) {
          var path = Path()
          path.move(to: CGPoint(x: plot.minX, y: y(Double(db))))
          path.addLine(to: CGPoint(x: plot.maxX, y: y(Double(db))))
          context.stroke(path, with: .color(.white.opacity(db == 0 ? 0.16 : 0.045)), lineWidth: 1)
          context.draw(
            Text(db == 0 ? "0 dB" : "\(db>0 ? "+":"")\(db)").font(
              .system(size: 9, design: .monospaced)
            ).foregroundColor(Studio.secondary.opacity(0.8)),
            at: CGPoint(x: plot.minX - 8, y: y(Double(db))),
            anchor: .trailing)
        }
        for frequency in [
          20.0, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 2000,
          3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 20000,
        ] where frequency <= frequencyLimit {
          let major = [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000].contains(frequency)
          var path = Path()
          path.move(to: CGPoint(x: x(frequency), y: plot.minY))
          path.addLine(to: CGPoint(x: x(frequency), y: plot.maxY))
          context.stroke(path, with: .color(.white.opacity(major ? 0.055 : 0.018)), lineWidth: 1)
          if major {
            context.draw(
              Text(frequency >= 1000 ? "\(Int(frequency/1000))k" : "\(Int(frequency))").font(
                .system(size: 9, design: .monospaced)
              ).foregroundColor(Studio.secondary.opacity(0.8)),
              at: CGPoint(x: x(frequency), y: plot.maxY + 14))
          }
        }
        func curvePath(_ values: [Double]) -> Path {
          Path { path in
            for (i, value) in values.enumerated() {
              let point = CGPoint(
                x: plot.minX + Double(i) / Double(max(1, values.count - 1)) * plot.width,
                y: y(max(-24, min(24, value))))
              if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
          }
        }
        for (index, values) in model.curves.enumerated()
        where model.saved.current.bands[index].enabled {
          var fill = curvePath(values)
          fill.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
          fill.addLine(to: CGPoint(x: plot.minX, y: y(0)))
          fill.closeSubpath()
          context.fill(
            fill,
            with: .color(bandColors[index].opacity(index == model.selectedBand ? 0.09 : 0.035)))
          context.stroke(
            curvePath(values),
            with: .color(bandColors[index].opacity(index == model.selectedBand ? 0.9 : 0.40)),
            lineWidth: index == model.selectedBand ? 1.7 : 1)
        }
        context.stroke(
          curvePath(model.combined), with: .color(Studio.ink.opacity(0.95)),
          style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        for band in model.saved.current.bands where band.enabled {
          let point = CGPoint(
            x: x(min(band.frequency, frequencyLimit)), y: y(band.type.hasGain ? band.gain : 0))
          let selected = band.id == model.selectedBand
          let radius: CGFloat = selected ? 7 : 4
          let rect = CGRect(
            x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
          if selected {
            var guide = Path()
            guide.move(to: CGPoint(x: point.x, y: plot.minY))
            guide.addLine(to: CGPoint(x: point.x, y: plot.maxY))
            context.stroke(
              guide, with: .color(bandColors[band.id].opacity(0.18)),
              style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            context.fill(
              Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)),
              with: .color(bandColors[band.id].opacity(0.10)))
          }
          context.fill(Path(ellipseIn: rect), with: .color(bandColors[band.id]))
          if selected {
            context.draw(
              Text("\(band.id + 1)").font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Studio.background), at: point)
          }
        }
      }
      .background(
        InputSpectrumView(
          model: model.inputSpectrum,
          visible: model.isEditorVisible && model.spectrumEnabled
        ).allowsHitTesting(false)
      )
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { gesture in
          if dragging == nil {
            let candidates = model.saved.current.bands.filter(\.enabled).map {
              band -> (Int, Double) in
              let x =
                plot.minX + log(min(band.frequency, frequencyLimit) / 20) / log(frequencyLimit / 20)
                * plot.width
              let y = plot.midY - (band.type.hasGain ? band.gain : 0) / 24 * plot.height / 2
              return (band.id, hypot(x - gesture.startLocation.x, y - gesture.startLocation.y))
            }
            guard let closest = candidates.min(by: { $0.1 < $1.1 }), closest.1 < 24 else {
              model.selectedBand = nil
              return
            }
            dragging = closest.0
            model.selectedBand = closest.0
          }
          guard let index = dragging else { return }
          let normalized = min(1, max(0, (gesture.location.x - plot.minX) / plot.width))
          model.edit {
            $0.bands[index].frequency = 20 * pow(frequencyLimit / 20, normalized)
            if $0.bands[index].type.hasGain {
              $0.bands[index].gain = max(
                -24, min(24, (plot.midY - gesture.location.y) / plot.height * 48))
            }
          }
        }.onEnded { _ in dragging = nil }
      )
      .accessibilityLabel(
        "Equalizer frequency response. Use the band controls below for precise editing.")
    }
  }
}
