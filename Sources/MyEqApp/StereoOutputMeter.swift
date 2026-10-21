import AppKit
import Combine
import MyEqCore
import QuartzCore
import SwiftUI

@MainActor
final class OutputMeterModel: ObservableObject {
  @Published private(set) var envelope = OutputMeterEnvelope()
  private var lastUpdate = ProcessInfo.processInfo.systemUptime

  func reset() {
    lastUpdate = ProcessInfo.processInfo.systemUptime
    if envelope != OutputMeterEnvelope() { envelope = OutputMeterEnvelope() }
  }

  func update(_ levels: OutputLevels) {
    let now = ProcessInfo.processInfo.systemUptime
    var next = envelope
    next.update(levels, elapsed: now - lastUpdate)
    lastUpdate = now
    if next != envelope { envelope = next }
  }
}

/// Receives meter samples directly in AppKit, without invalidating SwiftUI layout.
struct StereoOutputMeter: NSViewRepresentable {
  let model: OutputMeterModel

  func makeNSView(context: Context) -> StereoMeterView {
    let view = StereoMeterView()
    view.bind(model)
    return view
  }

  func updateNSView(_ view: StereoMeterView, context: Context) { view.bind(model) }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: StereoMeterView, context: Context)
    -> CGSize?
  {
    CGSize(width: 440, height: 26)
  }
}

@MainActor
final class StereoMeterView: NSView {
  private let left = ChannelLayers(label: "L", y: 14)
  private let right = ChannelLayers(label: "R", y: 0)
  private let guardText = meterText("Guard 0.0 dB", x: 345, y: 7, width: 95)
  private var subscription: AnyCancellable?
  private weak var model: OutputMeterModel?
  private var envelope = OutputMeterEnvelope()
  private var lastGuard = 0.0

  override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 26) }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 26))
    wantsLayer = true
    guard let layer else { return }
    layer.addSublayer(meterText("Output", x: 0, y: 7, width: 40, alignment: .left))
    for channel in [left, right] {
      for child in channel.layers { layer.addSublayer(child) }
    }
    layer.addSublayer(guardText)
    toolTip =
      "Left and right output levels after EQ and peak protection, from −60 to 0 dBFS. White peak markers and dBFS readings hold for one second, then fall slowly together."
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Stereo output peak levels")
    updateScale()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func bind(_ model: OutputMeterModel) {
    guard self.model !== model else { return }
    self.model = model
    subscription = model.$envelope.sink { [weak self] in self?.update($0) }
  }

  private func update(_ value: OutputMeterEnvelope) {
    envelope = value
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    left.update(level: value.leftDB, peak: value.leftPeakDB)
    right.update(level: value.rightDB, peak: value.rightPeakDB)
    let reduction = (value.reductionDB * 10).rounded() / 10
    if reduction != lastGuard {
      lastGuard = reduction
      guardText.string = String(format: "Guard %.1f dB", reduction)
      guardText.foregroundColor = reduction > 0.1 ? NSColor.systemOrange.cgColor : meterTextColor
    }
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateScale()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
  }

  private func updateScale() {
    let scale = window?.backingScaleFactor ?? 2
    for child in layer?.sublayers ?? [] { child.contentsScale = scale }
  }

  override func accessibilityValue() -> Any? {
    "Left \(peakText(envelope.leftPeakDB)), right \(peakText(envelope.rightPeakDB)), "
      + String(format: "guard %.1f dB", envelope.reductionDB)
  }
}

private let meterTextColor = NSColor(calibratedWhite: 0.65, alpha: 1).cgColor

private func peakText(_ decibels: Double) -> String {
  decibels > OutputMeterEnvelope.floorDB ? String(format: "%.1f dBFS", decibels) : "−∞ dBFS"
}

private func meterText(
  _ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
  alignment: CATextLayerAlignmentMode = .right
) -> CATextLayer {
  let layer = CATextLayer()
  layer.frame = CGRect(x: x, y: y, width: width, height: 12)
  layer.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
  layer.fontSize = 10
  layer.alignmentMode = alignment
  layer.foregroundColor = meterTextColor
  layer.string = text
  return layer
}

private final class ChannelLayers {
  let layers: [CALayer]
  private let mask = CALayer()
  private let marker = CALayer()
  private let reading: CATextLayer
  private let y: CGFloat
  private var lastReading = "−∞ dBFS"

  init(label: String, y: CGFloat) {
    self.y = y
    reading = meterText(lastReading, x: 259, y: y, width: 72)
    let track = CALayer()
    track.frame = CGRect(x: 71, y: y + 3, width: 180, height: 6)
    track.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
    track.cornerRadius = 3
    track.masksToBounds = true
    let gradient = CAGradientLayer()
    gradient.frame = track.bounds
    gradient.colors = [
      NSColor.systemMint.cgColor, NSColor.systemMint.cgColor, NSColor.systemYellow.cgColor,
      NSColor.systemOrange.cgColor, NSColor.systemRed.cgColor,
    ]
    gradient.locations = [0, 0.8, 0.9, 0.98, 1]
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    mask.backgroundColor = NSColor.white.cgColor
    mask.anchorPoint = .zero
    mask.position = .zero
    gradient.mask = mask
    track.addSublayer(gradient)
    marker.backgroundColor = NSColor.white.cgColor
    marker.cornerRadius = 1
    marker.isHidden = true
    layers = [meterText(label, x: 54, y: y, width: 9), track, marker, reading]
  }

  func update(level: Double, peak: Double) {
    let width = 180 * (level - OutputMeterEnvelope.floorDB) / -OutputMeterEnvelope.floorDB
    let maskBounds = CGRect(x: 0, y: 0, width: width, height: 6)
    if mask.bounds != maskBounds { mask.bounds = maskBounds }
    let markerX = 180 * (peak - OutputMeterEnvelope.floorDB) / -OutputMeterEnvelope.floorDB
    let markerFrame = CGRect(x: 71 + min(178, max(0, markerX - 1)), y: y + 3, width: 2, height: 6)
    if marker.frame != markerFrame { marker.frame = markerFrame }
    marker.isHidden = peak <= OutputMeterEnvelope.floorDB
    let text = peakText(peak)
    if text != lastReading {
      lastReading = text
      reading.string = text
    }
  }
}
