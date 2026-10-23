// Design proposal only. Synthetic spectral data; no production views, DSP, or capture changes.
import AppKit
import ImageIO
import MyEqCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SpectrumProposal {
  struct Snapshot {
    let output: [Double]
    let source: [Double]
    let peaks: [Double]
    let time: Double
  }

  private struct Ballistics {
    var bar = -90.0
    var peak = -90.0
    var hold = 0.0
    mutating func update(_ target: Double, dt: Double) {
      bar = max(target, bar - 24 * dt)
      let falling = max(0, dt - hold)
      hold = max(0, hold - dt)
      peak = max(-90, peak - 6 * falling)
      if target > -90, target >= peak {
        peak = target
        hold = 1
      }
    }
  }

  static func snapshots(_ model: AppModel) -> [Snapshot] {
    var output = [Ballistics](repeating: Ballistics(), count: SpectrumFrame.pointCount)
    var source = output
    var result: [Snapshot] = []
    for frame in 0..<180 {
      let time = Double(frame) / 30
      for band in output.indices {
        let x = Double(band) / Double(output.count - 1)
        let frequency = 20 * pow(model.frequencyLimit / 20, x)
        let bass = 23 * exp(-pow((x - 0.23) / 0.16, 2))
        let mids = 12 * exp(-pow((x - 0.55) / 0.23, 2))
        let texture = 2 * sin(x * 47) + 2 * cos(x * 23)
        let burst = time < 1 ? 12.0 : -10.0
        let input = -61 + bass + mids + texture + burst
        let ghost = min(0, max(-90, input + model.effectivePreamp))
        let corrected = min(
          0,
          max(
            -90,
            ghost
              + EQResponse.gain(
                model.saved.current.bands, at: frequency, sampleRate: 48000)))
        source[band].update(ghost, dt: 1.0 / 30)
        output[band].update(corrected, dt: 1.0 / 30)
      }
      result.append(
        Snapshot(
          output: output.map(\.bar), source: source.map(\.bar),
          peaks: output.map(\.peak), time: time))
    }
    return result
  }

  static func attach(to root: NSView, snapshot: Snapshot, ghost: Bool) {
    func find(_ view: NSView) -> SpectrumLayerView? {
      if let spectrum = view as? SpectrumLayerView { return spectrum }
      for child in view.subviews { if let match = find(child) { return match } }
      return nil
    }
    guard let target = find(root) else { fatalError("Missing spectrum preview surface") }
    let overlay = NSHostingView(rootView: ProposalBars(snapshot: snapshot, ghost: ghost))
    overlay.frame = target.bounds
    overlay.autoresizingMask = [.width, .height]
    target.addSubview(overlay)
    overlay.layoutSubtreeIfNeeded()
    overlay.displayIfNeeded()
  }

  static func render(model: AppModel, directory: URL) throws {
    model.saved.enabled = true
    model.engineStatus.state = .running
    model.engineStatus.outputName = "ADAM Audio D3V"
    model.engineStatus.sampleRate = 48000
    model.setEditorVisible(true)
    DesignPreview.drain()
    model.outputMeter.update(OutputLevels(left: 0.28, right: 0.20, reduction: 0, active: true))
    let states = snapshots(model)
    // Show a source level change after the one-second burst, while the peak is still held.
    let still = states[47]
    for (name, width, height, ghost) in [
      ("editor-spectrum-proposal.png", 1180.0, 900.0, true),
      ("editor-spectrum-proposal-small.png", 1040.0, 740.0, true),
      ("editor-spectrum-proposal-output-only.png", 1180.0, 900.0, false),
    ] {
      try DesignPreview.render(
        EqualizerView(model: model), width: width, height: height,
        to: directory.appendingPathComponent(name),
        decorate: { attach(to: $0, snapshot: still, ghost: ghost) })
    }
    let gifURL = directory.appendingPathComponent("spectrum-proposal-motion.gif")
    guard
      let gif = CGImageDestinationCreateWithURL(
        gifURL as CFURL,
        UTType.gif.identifier as CFString, 60, nil)
    else { fatalError("Cannot create motion preview") }
    CGImageDestinationSetProperties(
      gif,
      [
        kCGImagePropertyGIFDictionary:
          [kCGImagePropertyGIFLoopCount: 0]
      ] as CFDictionary)
    for index in stride(from: 0, to: states.count, by: 3) {
      let state = states[index]
      let content = VStack(spacing: 8) {
        HStack {
          Text("OUTPUT SPECTRUM").font(.system(size: 11, weight: .semibold)).tracking(1.5)
          Spacer()
          Text("Synthetic design preview").font(.system(size: 11)).foregroundStyle(Studio.secondary)
        }.padding(.horizontal, 24).padding(.top, 18)
        ResponseGraph(model: model).frame(height: 220).padding(.horizontal, 12)
        HStack {
          Text(
            state.time < 1
              ? "Signal peak" : state.time < 2 ? "Bars falling · peak held" : "Peak markers falling"
          )
          Spacer()
          Text("Bars 24 dB/s  ·  Peaks hold 1 s, then 6 dB/s")
        }.font(.system(size: 11)).foregroundStyle(Studio.secondary)
          .padding(.horizontal, 24).padding(.bottom, 16)
      }.foregroundStyle(Studio.ink).background(Studio.surface)
      let url = directory.appendingPathComponent(
        String(format: "spectrum-proposal-frame-%02d.png", index / 3))
      try DesignPreview.render(
        content, width: 1000, height: 300, to: url,
        decorate: { attach(to: $0, snapshot: state, ghost: true) })
      guard
        let image = NSImage(contentsOf: url)?.cgImage(
          forProposedRect: nil, context: nil, hints: nil)
      else { fatalError("Cannot decode motion frame") }
      CGImageDestinationAddImage(
        gif, image,
        [
          kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: 0.1]
        ] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(gif))
    print(
      "Synthetic proposal: three editor PNGs and a six-second motion preview. Production audio unchanged."
    )
  }
}

private struct ProposalBars: View {
  let snapshot: SpectrumProposal.Snapshot
  let ghost: Bool
  var body: some View {
    Canvas { context, size in
      let plot = CGRect(x: 34, y: 12, width: size.width - 46, height: size.height - 38)
      let legendContext = context
      context.clip(to: Path(plot))
      let spacing = plot.width / CGFloat(SpectrumFrame.pointCount - 1)
      let width = spacing * 0.50
      let ghostWidth = spacing * 0.60 + 3
      let rows = max(1, Int(plot.height * 0.75 / 4))
      func normalized(_ db: Double) -> CGFloat { CGFloat(max(0, min(1, (db + 90) / 90))) }
      func height(_ db: Double) -> CGFloat {
        let count = Int(ceil(normalized(db) * CGFloat(rows)))
        return count > 0 ? CGFloat(count - 1) * 4 + 2.25 : 0
      }
      for index in snapshot.output.indices {
        let x = plot.minX + CGFloat(index) * spacing
        if ghost {
          let h = height(snapshot.source[index])
          let rect = CGRect(
            x: x - ghostWidth / 2, y: plot.maxY - h,
            width: ghostWidth, height: h)
          context.fill(
            Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.018)))
          context.stroke(
            Path(roundedRect: rect, cornerRadius: 1),
            with: .color(Color(red: 0.65, green: 0.69, blue: 0.72).opacity(0.15)), lineWidth: 0.65)
        }
        let count = Int(ceil(normalized(snapshot.output[index]) * CGFloat(rows)))
        for row in 0..<count {
          let rect = CGRect(
            x: x - width / 2, y: plot.maxY - CGFloat(row) * 4 - 1.75,
            width: width, height: 1.75)
          context.fill(
            Path(roundedRect: rect, cornerRadius: 0.55),
            with: .linearGradient(
              Gradient(stops: [
                .init(color: Color(red: 0.76, green: 0.85, blue: 0.76).opacity(0.44), location: 0),
                .init(
                  color: Color(red: 0.55, green: 0.71, blue: 0.59).opacity(0.34), location: 0.35),
                .init(
                  color: Color(red: 0.31, green: 0.49, blue: 0.40).opacity(0.22), location: 0.7),
                .init(color: Color(red: 0.13, green: 0.24, blue: 0.20).opacity(0.12), location: 1),
              ]), startPoint: CGPoint(x: 0, y: plot.minY + plot.height * 0.25),
              endPoint: CGPoint(x: 0, y: plot.maxY)))
        }
        let markerY = plot.maxY - normalized(snapshot.peaks[index]) * plot.height * 0.75
        let marker = CGRect(x: x - width / 2, y: markerY, width: width, height: 1)
        context.fill(
          Path(roundedRect: marker, cornerRadius: 0.5),
          with: .color(Color(red: 0.85, green: 0.90, blue: 0.84).opacity(0.30)))
      }
      let legend =
        ghost ? "OUTPUT   ·   SOURCE + PREAMP (OUTLINE)   ·   PEAK HOLD" : "OUTPUT   ·   PEAK HOLD"
      legendContext.draw(
        Text(legend).font(.system(size: 8, weight: .medium, design: .monospaced))
          .foregroundColor(Studio.secondary.opacity(0.8)),
        at: CGPoint(x: plot.maxX, y: 3), anchor: .topTrailing)
    }.allowsHitTesting(false)
  }
}
