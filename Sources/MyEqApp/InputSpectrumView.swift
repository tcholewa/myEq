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
  private struct Trail {
    let frame: SpectrumFrame
    var path: CGPath?
  }
  private let plotLayer = CALayer()
  private let fill = CAGradientLayer()
  private let fillMask = CAShapeLayer()
  private let outline = CAShapeLayer()
  private let softEdge = CAShapeLayer()
  private let trails = (0..<16).map { _ in CAShapeLayer() }
  private var history: [Trail] = []
  private var current: SpectrumFrame?
  private var currentPath: CGPath?
  private var geometryDirty = false
  private var lastTrailTime: TimeInterval = -.infinity
  private var subscription: AnyCancellable?
  private weak var model: InputSpectrumModel?
  private var visible = false
  private var reducedMotion = false
  private var timer: Timer?
  private var lastPlotSize = CGSize.zero
  private let sage = NSColor(red: 0.60, green: 0.79, blue: 0.65, alpha: 1)

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.isGeometryFlipped = true
    plotLayer.masksToBounds = true
    layer?.addSublayer(plotLayer)
    fill.colors = [sage.withAlphaComponent(0.14).cgColor, sage.withAlphaComponent(0).cgColor]
    fill.startPoint = CGPoint(x: 0.5, y: 0)
    fill.endPoint = CGPoint(x: 0.5, y: 1)
    fill.mask = fillMask
    plotLayer.addSublayer(fill)
    for trail in trails {
      trail.fillColor = nil
      trail.strokeColor = sage.cgColor
      trail.lineWidth = 1
      trail.lineCap = .round
      trail.lineJoin = .round
      trail.opacity = 0
      plotLayer.addSublayer(trail)
    }
    for (shape, width, opacity) in [
      (softEdge, CGFloat(3), Float(0.035)), (outline, CGFloat(1.1), Float(0.26)),
    ] {
      shape.fillColor = nil
      shape.strokeColor = sage.cgColor
      shape.lineWidth = width
      shape.opacity = opacity
      shape.lineCap = .round
      shape.lineJoin = .round
      plotLayer.addSublayer(shape)
    }
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
    clear()
  }
  deinit { timer?.invalidate() }

  private func clear() {
    timer?.invalidate()
    timer = nil
    history.removeAll(keepingCapacity: true)
    current = nil
    currentPath = nil
    geometryDirty = false
    lastTrailTime = -.infinity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillMask.path = nil
    outline.path = nil
    softEdge.path = nil
    for trail in trails {
      trail.path = nil
      trail.opacity = 0
    }
    CATransaction.commit()
  }

  private func receive(_ frame: SpectrumFrame?) {
    guard visible else { return }
    guard let frame, frame.levels.count == SpectrumFrame.pointCount else {
      clear()
      return
    }
    if let old = current, old.sampleRate != frame.sampleRate || frame.timestamp < old.timestamp {
      clear()
    }
    let hasEnergy = frame.levels.contains { $0 > SpectrumFrame.floorDB + 0.05 }
    if !hasEnergy && current == nil && history.isEmpty { return }
    if !reducedMotion, let old = current,
      old.levels.contains(where: { $0 > SpectrumFrame.floorDB + 0.05 }),
      frame.timestamp - lastTrailTime >= 1.0 / 15
    {
      history.append(Trail(frame: old, path: currentPath))
      if history.count > trails.count { history.removeFirst(history.count - trails.count) }
      lastTrailTime = frame.timestamp
    }
    current = frame
    currentPath = makePath(frame)
    geometryDirty = true
    // Coalesce incoming frames and fading on one display cadence, rather than drawing twice.
    if timer == nil { drawFrame(at: ProcessInfo.processInfo.systemUptime) }
    if timer == nil && (current != nil || !history.isEmpty) && (!reducedMotion || hasEnergy) {
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

  private func makePath(_ frame: SpectrumFrame) -> CGPath {
    let path = CGMutablePath()
    for (index, db) in frame.levels.enumerated() {
      let level =
        db.isFinite
        ? CGFloat(max(0, min(1, (db - SpectrumFrame.floorDB) / -SpectrumFrame.floorDB))) : 0
      let point = CGPoint(
        x: CGFloat(index) / CGFloat(frame.levels.count - 1) * plotLayer.bounds.width,
        y: plotLayer.bounds.height * (1 - level * 0.75))
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }

  private func drawFrame(at now: TimeInterval) {
    guard visible else {
      clear()
      return
    }
    history.removeAll { now - $0.frame.timestamp >= 1.1 }
    if let current, now - current.timestamp > 1.1 {
      self.current = nil
      currentPath = nil
      geometryDirty = true
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, layer) in trails.enumerated() {
      guard index < history.count, !reducedMotion else {
        layer.opacity = 0
        continue
      }
      if history[index].path == nil { history[index].path = makePath(history[index].frame) }
      layer.path = history[index].path
      layer.opacity = Float(0.10 * exp(-max(0, now - history[index].frame.timestamp) / 0.28))
    }
    let currentAge = current.map { max(0, now - $0.timestamp - 0.15) } ?? 1.1
    let opacity = Float(exp(-currentAge / 0.28))
    outline.opacity = 0.26 * opacity
    softEdge.opacity = 0.035 * opacity
    fill.opacity = opacity
    if geometryDirty {
      outline.path = currentPath
      softEdge.path = currentPath
      if let path = currentPath?.mutableCopy() {
        path.addLine(to: CGPoint(x: plotLayer.bounds.width, y: plotLayer.bounds.height))
        path.addLine(to: CGPoint(x: 0, y: plotLayer.bounds.height))
        path.closeSubpath()
        fillMask.path = path
      } else {
        fillMask.path = nil
      }
      geometryDirty = false
    }
    CATransaction.commit()
    let silent = current?.levels.allSatisfy { $0 <= SpectrumFrame.floorDB + 0.05 } ?? true
    if silent && history.isEmpty { clear() }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plotLayer.frame = CGRect(
      x: 34, y: 12, width: max(0, bounds.width - 46), height: max(0, bounds.height - 38))
    fill.frame = plotLayer.bounds
    fillMask.frame = plotLayer.bounds
    for shape in [outline, softEdge] + trails { shape.frame = plotLayer.bounds }
    if plotLayer.bounds.size != lastPlotSize {
      lastPlotSize = plotLayer.bounds.size
      currentPath = current.map(makePath)
      geometryDirty = true
      for index in history.indices { history[index].path = nil }
    }
    let scale = window?.backingScaleFactor ?? 2
    for child in plotLayer.sublayers ?? [] { child.contentsScale = scale }
    CATransaction.commit()
    drawFrame(at: ProcessInfo.processInfo.systemUptime)
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }
}
