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
  private let fill = CALayer()
  private let barMask = CAShapeLayer()
  private let tips = CAShapeLayer()
  private let ghost = CAShapeLayer()
  private var current: SpectrumFrame?
  private var geometryDirty = false
  private var subscription: AnyCancellable?
  private weak var model: InputSpectrumModel?
  private var visible = false
  private var reducedMotion = false
  private var timer: Timer?
  private var lastPlotSize = CGSize.zero
  private var lastScale: CGFloat = 0
  private var displayedRows: [Int] = []
  private var displayedGhostRows: [Int] = []
  private var displayedPeaks: [CGFloat] = []
  private let step: CGFloat = 4
  private let segmentHeight: CGFloat = 1.75

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.isGeometryFlipped = true
    plotLayer.masksToBounds = true
    layer?.addSublayer(plotLayer)
    fill.contentsGravity = .resize
    fill.mask = barMask
    ghost.fillColor = NSColor.white.withAlphaComponent(0.018).cgColor
    ghost.strokeColor = NSColor(red: 0.65, green: 0.69, blue: 0.72, alpha: 0.15).cgColor
    ghost.lineWidth = 0.65
    plotLayer.addSublayer(ghost)
    plotLayer.addSublayer(fill)
    tips.fillColor = NSColor(red: 0.85, green: 0.90, blue: 0.84, alpha: 0.30).cgColor
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
    displayedRows.removeAll(keepingCapacity: true)
    displayedGhostRows.removeAll(keepingCapacity: true)
    displayedPeaks.removeAll(keepingCapacity: true)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    barMask.path = nil
    tips.path = nil
    ghost.path = nil
    CATransaction.commit()
  }

  private func receive(_ frame: SpectrumFrame?) {
    guard visible else { return }
    guard let frame, frame.levels.count == SpectrumFrame.pointCount,
      frame.peaks.count == SpectrumFrame.pointCount,
      frame.sourceLevels.isEmpty || frame.sourceLevels.count == SpectrumFrame.pointCount,
      frame.timestamp.isFinite,
      [frame.levels, frame.sourceLevels, frame.peaks].contains(where: { values in
        values.contains { $0.isFinite && $0 > SpectrumFrame.floorDB + 0.05 }
      })
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

  /// Rasterize the fixed LED grid only on resize/backing-scale changes. Per-frame masks
  /// contain one rectangle per band, rather than a rounded path for every lit cell.
  private func rebuildTexture(scale: CGFloat) {
    let size = plotLayer.bounds.size
    guard size.width > 0, size.height > 0,
      let context = CGContext(
        data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      fill.contents = nil
      return
    }
    context.translateBy(x: 0, y: CGFloat(context.height))
    context.scaleBy(x: scale, y: -scale)
    let spacing = size.width / CGFloat(SpectrumFrame.pointCount - 1)
    let width = max(0.5, spacing * 0.50)
    let grid = CGMutablePath()
    for index in 0..<SpectrumFrame.pointCount {
      for row in 0..<max(1, Int(size.height * 0.75 / step)) {
        grid.addRoundedRect(
          in: CGRect(
            x: CGFloat(index) * spacing - width / 2,
            y: size.height - CGFloat(row) * step - segmentHeight,
            width: width, height: segmentHeight),
          cornerWidth: 0.55, cornerHeight: 0.55)
      }
    }
    context.addPath(grid)
    context.clip()
    // Keep the approved subdued palette independent of bar height.
    let colors = [
      NSColor(red: 0.76, green: 0.85, blue: 0.76, alpha: 0.44).cgColor,
      NSColor(red: 0.55, green: 0.71, blue: 0.59, alpha: 0.34).cgColor,
      NSColor(red: 0.31, green: 0.49, blue: 0.40, alpha: 0.22).cgColor,
      NSColor(red: 0.13, green: 0.24, blue: 0.20, alpha: 0.12).cgColor,
    ]
    if let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors as CFArray, locations: [0, 0.35, 0.7, 1])
    {
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size.height * 0.25), end: CGPoint(x: 0, y: size.height),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    fill.contents = context.makeImage()
  }

  private func updateGeometry(_ frame: SpectrumFrame) {
    let size = plotLayer.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let rows = max(1, Int(size.height * 0.75 / step))
    func normalized(_ db: Float) -> CGFloat {
      db.isFinite
        ? CGFloat(max(0, min(1, (db - SpectrumFrame.floorDB) / -SpectrumFrame.floorDB))) : 0
    }
    func rowCounts(_ values: [Float]) -> [Int] {
      values.map { min(rows, Int(ceil(normalized($0) * CGFloat(rows)))) }
    }
    let nextRows = rowCounts(frame.levels)
    let spacing = size.width / CGFloat(SpectrumFrame.pointCount - 1)
    let width = max(0.5, spacing * 0.50)
    if nextRows != displayedRows {
      displayedRows = nextRows
      let bars = CGMutablePath()
      for (index, count) in nextRows.enumerated() where count > 0 {
        let height = CGFloat(count - 1) * step + segmentHeight
        bars.addRect(
          CGRect(
            x: CGFloat(index) * spacing - width / 2,
            y: size.height - height, width: width, height: height))
      }
      barMask.path = bars
    }
    let nextGhost = rowCounts(frame.sourceLevels)
    if nextGhost != displayedGhostRows {
      displayedGhostRows = nextGhost
      let outlines = CGMutablePath()
      let ghostWidth = spacing * 0.60 + 3
      for (index, count) in nextGhost.enumerated() where count > 0 {
        let height = CGFloat(count - 1) * step + 2.25
        outlines.addRoundedRect(
          in: CGRect(
            x: CGFloat(index) * spacing - ghostWidth / 2,
            y: size.height - height, width: ghostWidth, height: height), cornerWidth: 1,
          cornerHeight: 1)
      }
      ghost.path = outlines
    }
    // Snap peak positions to backing pixels, independently of the LED row mask.
    let scale = max(1, lastScale)
    let nextPeaks = frame.peaks.map { db -> CGFloat in
      db.isFinite && db > SpectrumFrame.floorDB
        ? ((size.height - normalized(db) * size.height * 0.75) * scale).rounded() / scale : -1
    }
    if nextPeaks != displayedPeaks {
      displayedPeaks = nextPeaks
      let caps = CGMutablePath()
      for (index, y) in nextPeaks.enumerated() where y >= 0 {
        caps.addRoundedRect(
          in: CGRect(
            x: CGFloat(index) * spacing - width / 2,
            y: y, width: width, height: 1), cornerWidth: 0.5, cornerHeight: 0.5)
      }
      tips.path = caps
    }
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
    ghost.opacity = opacity
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
    ghost.frame = plotLayer.bounds
    let scale = window?.backingScaleFactor ?? 2
    if plotLayer.bounds.size != lastPlotSize || scale != lastScale {
      lastPlotSize = plotLayer.bounds.size
      lastScale = scale
      rebuildTexture(scale: scale)
      displayedRows.removeAll(keepingCapacity: true)
      displayedGhostRows.removeAll(keepingCapacity: true)
      displayedPeaks.removeAll(keepingCapacity: true)
      geometryDirty = true
    }
    for child in [fill, barMask, tips, ghost] { child.contentsScale = scale }
    CATransaction.commit()
    drawFrame(at: ProcessInfo.processInfo.systemUptime)
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }
}
