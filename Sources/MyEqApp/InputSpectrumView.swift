import AppKit
import Combine
import MyEqCore
import QuartzCore
import SwiftUI

/// Frames travel directly to native drawing layers, without publishing editor state.
@MainActor
final class InputSpectrumModel {
  let updates = PassthroughSubject<SpectrumFrame?, Never>()
  private(set) var frame: SpectrumFrame?
  func update(_ frame: SpectrumFrame?) {
    self.frame = frame
    updates.send(frame)
  }
}

struct InputSpectrumView: NSViewRepresentable {
  let model: InputSpectrumModel
  let visible: Bool
  @Environment(\.accessibilityReduceMotion) private var reducedMotion

  func makeNSView(context: Context) -> SpectrumLayerView { SpectrumLayerView() }
  func updateNSView(_ view: SpectrumLayerView, context: Context) {
    view.bind(model, visible: visible, reducedMotion: reducedMotion)
  }
  static func dismantleNSView(_ view: SpectrumLayerView, coordinator: ()) { view.disconnect() }
}

@MainActor
final class SpectrumLayerView: NSView {
  private let plotLayer = CALayer()
  private let fill = CAGradientLayer()
  private let barMask = CAShapeLayer()
  private let tips = CAShapeLayer()
  private var current: SpectrumFrame?
  private var geometryDirty = false
  private var subscription: AnyCancellable?
  private weak var model: InputSpectrumModel?
  private var visible = false
  private var reducedMotion = false
  private var timer: Timer?
  private var lastPlotSize = CGSize.zero

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.isGeometryFlipped = true
    plotLayer.masksToBounds = true
    layer?.addSublayer(plotLayer)
    fill.colors = [
      NSColor(red: 0.86, green: 0.96, blue: 0.80, alpha: 0.88).cgColor,
      NSColor(red: 0.66, green: 0.86, blue: 0.66, alpha: 0.76).cgColor,
      NSColor(red: 0.35, green: 0.62, blue: 0.46, alpha: 0.58).cgColor,
      NSColor(red: 0.12, green: 0.25, blue: 0.20, alpha: 0.30).cgColor,
    ]
    fill.locations = [0, 0.35, 0.7, 1]
    fill.startPoint = CGPoint(x: 0.5, y: 0.25)
    fill.endPoint = CGPoint(x: 0.5, y: 1)
    fill.mask = barMask
    plotLayer.addSublayer(fill)
    tips.fillColor = NSColor(red: 0.80, green: 0.94, blue: 0.76, alpha: 0.82).cgColor
    plotLayer.addSublayer(tips)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func bind(_ model: InputSpectrumModel, visible: Bool, reducedMotion: Bool) {
    let changed = self.visible != visible || self.reducedMotion != reducedMotion
    self.visible = visible
    self.reducedMotion = reducedMotion
    if changed { clear() }
    if self.model !== model {
      self.model = model
      subscription = model.updates.sink { [weak self] in self?.receive($0) }
      receive(model.frame)
    }
    if !visible { clear() }
  }
  func disconnect() {
    visible = false
    subscription = nil
    model = nil
    clear()
  }
  deinit { timer?.invalidate() }

  private func clear() {
    timer?.invalidate()
    timer = nil
    current = nil
    geometryDirty = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    barMask.path = nil
    tips.path = nil
    CATransaction.commit()
  }

  private func receive(_ frame: SpectrumFrame?) {
    guard visible else { return }
    guard let frame, frame.levels.count == SpectrumFrame.pointCount,
      frame.timestamp.isFinite,
      frame.levels.contains(where: { $0.isFinite && $0 > SpectrumFrame.floorDB + 0.05 })
    else {
      clear()
      return
    }
    if let old = current, old.sampleRate != frame.sampleRate || frame.timestamp < old.timestamp {
      clear()
    }
    current = frame
    geometryDirty = true
    // Coalesce incoming frames and stale-data fading on one display cadence.
    if timer == nil { drawFrame(at: ProcessInfo.processInfo.systemUptime) }
    if timer == nil && current != nil {
      let timer = Timer(timeInterval: reducedMotion ? 0.1 : 1.0 / 30, repeats: true) {
        [weak self] _ in
        MainActor.assumeIsolated {
          self?.drawFrame(at: ProcessInfo.processInfo.systemUptime)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }
  }

  private func updateGeometry(_ frame: SpectrumFrame) {
    let bars = CGMutablePath()
    let caps = CGMutablePath()
    let size = plotLayer.bounds.size
    guard size.width > 0, size.height > 0 else {
      barMask.path = nil
      tips.path = nil
      return
    }
    // Keep the same logarithmic sample positions as the original spectrum line.
    let spacing = size.width / CGFloat(SpectrumFrame.pointCount - 1)
    let width = max(0.5, spacing * 0.68)
    let step: CGFloat = 4
    let segmentHeight: CGFloat = 2.5
    let rows = max(1, Int(size.height * 0.75 / step))
    for (index, db) in frame.levels.enumerated() {
      let level =
        db.isFinite
        ? CGFloat(
          max(
            0,
            min(
              1,
              (db - SpectrumFrame.floorDB) / -SpectrumFrame.floorDB))) : 0
      let count = min(rows, Int(ceil(level * CGFloat(rows))))
      guard count > 0 else { continue }
      let x = CGFloat(index) * spacing - width / 2
      for row in 0..<count {
        let rect = CGRect(
          x: x, y: size.height - CGFloat(row) * step - segmentHeight,
          width: width, height: segmentHeight)
        bars.addRoundedRect(in: rect, cornerWidth: 0.55, cornerHeight: 0.55)
        if row == count - 1 {
          caps.addRoundedRect(in: rect, cornerWidth: 0.55, cornerHeight: 0.55)
        }
      }
    }
    barMask.path = bars
    tips.path = caps
  }

  private func drawFrame(at now: TimeInterval) {
    guard visible, let current, now - current.timestamp <= 1.1 else {
      clear()
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let opacity = Float(exp(-max(0, now - current.timestamp - 0.15) / 0.28))
    fill.opacity = opacity
    tips.opacity = opacity
    if geometryDirty {
      updateGeometry(current)
      geometryDirty = false
    }
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plotLayer.frame = CGRect(
      x: 34, y: 12, width: max(0, bounds.width - 46), height: max(0, bounds.height - 38))
    fill.frame = plotLayer.bounds
    barMask.frame = plotLayer.bounds
    tips.frame = plotLayer.bounds
    if plotLayer.bounds.size != lastPlotSize {
      lastPlotSize = plotLayer.bounds.size
      geometryDirty = true
    }
    let scale = window?.backingScaleFactor ?? 2
    for child in [fill, barMask, tips] { child.contentsScale = scale }
    CATransaction.commit()
    drawFrame(at: ProcessInfo.processInfo.systemUptime)
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }
}
