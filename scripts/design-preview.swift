// Source-rendered fixtures only. No screen capture, app automation, audio routing, or saved settings.
import AppKit
import MyEqCore
import SwiftUI

@main
struct DesignPreview {
  @MainActor
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = AppModel(preview: true)
    if CommandLine.arguments.contains("--preview-only") {
      model.saved.enabled = true
      model.engineStatus.state = .running
      model.engineStatus.outputName = "ADAM Audio D3V"
      model.engineStatus.sampleRate = 48000
      model.setEditorVisible(true)
      drain()
      model.outputMeter.update(OutputLevels(left: 0.28, right: 0.20, reduction: 0, active: true))
      try render(
        EqualizerView(model: model), width: 1180, height: 900,
        to: directory.appendingPathComponent("editor-spectrum.png"),
        prepare: { spectrumFixture(model.inputSpectrum) })
      try render(
        EqualizerView(model: model), width: 1040, height: 740,
        to: directory.appendingPathComponent("editor-spectrum-small.png"),
        prepare: { spectrumFixture(model.inputSpectrum) })
      return
    }
    verifySelection(model)
    verifyInitialFocus(model)
    model.saved.enabled = true
    model.engineStatus.state = .running
    model.engineStatus.outputName = "ADAM Audio D3V"
    model.engineStatus.sampleRate = 48000
    model.setEditorVisible(true)
    drain()
    model.outputMeter.update(OutputLevels(left: 0.28, right: 0.20, reduction: 0, active: true))
    try render(
      EqualizerView(model: model), width: 1180, height: 900,
      to: directory.appendingPathComponent("editor.png"))
    try render(
      EqualizerView(model: model), width: 1040, height: 740,
      to: directory.appendingPathComponent("editor-small.png"))
    try render(
      EqualizerView(model: model), width: 1180, height: 900,
      to: directory.appendingPathComponent("editor-spectrum.png"),
      prepare: { spectrumFixture(model.inputSpectrum) })
    try render(
      EqualizerView(model: model), width: 1040, height: 740,
      to: directory.appendingPathComponent("editor-spectrum-small.png"),
      prepare: { spectrumFixture(model.inputSpectrum) })
    model.inputSpectrum.update(nil)
    verifySpectrumLayers()
    model.setEditorVisible(false)
    let hiddenCurves = model.curves
    model.edit { $0.bands[0].gain = 6 }
    drain()
    precondition(model.curves == hiddenCurves && model.menuCurve.isEmpty)
    model.setMenuVisible(true)
    drain()
    precondition(
      model.menuCurve.count == 128 && model.curves == hiddenCurves && !model.isEditorVisible)
    let menuCurve = model.menuCurve
    model.setMenuVisible(false)
    model.edit { $0.bands[0].gain = 4.8 }
    drain()
    precondition(model.menuCurve == menuCurve && model.curves == hiddenCurves)
    model.setMenuVisible(true)
    drain()
    precondition(model.menuCurve != menuCurve)
    try render(
      MenuBarPanel(model: model), width: 354, to: directory.appendingPathComponent("menu.png"))
    model.saved.enabled = false
    model.engineStatus.state = .bypassed
    try render(
      MenuBarPanel(model: model), width: 354,
      to: directory.appendingPathComponent("menu-bypassed.png"))
    model.engineStatus.state = .error("Connect an audio output. EQ will resume automatically.")
    try render(
      MenuBarPanel(model: model), width: 354,
      to: directory.appendingPathComponent("menu-attention.png"))
    model.engineStatus.state = .running
    model.saved.enabled = true
    model.saved.current.name = "An exceptionally long personal preset name for evening listening"
    model.engineStatus.outputName = "Living Room Studio Monitors — USB Audio Interface"
    try render(
      MenuBarPanel(model: model), width: 354,
      to: directory.appendingPathComponent("menu-long-names.png"))
    model.setMenuVisible(false)
    model.setEditorVisible(true)
    model.edit { $0.bands[0].gain = 5 }
    drain()
    precondition(model.curves.count == 8 && model.curves[0] != hiddenCurves[0])
    print(
      "PASS: hidden editor/menu graphs stay parked; opening the menu computes only its static preview."
    )
  }

  @MainActor
  static func verifyInitialFocus(_ model: AppModel) {
    let unchanged = model.saved.current
    model.selectedBand = nil
    let frequency = model.bandBinding(0, \.frequency)
    frequency.wrappedValue = frequency.wrappedValue
    precondition(model.selectedBand == nil && model.saved.current == unchanged)

    let content = NSHostingView(rootView: EqualizerView(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    drain()
    guard let observer = selectionObserver(in: content) else {
      fatalError("Missing selection observer")
    }
    precondition(window.initialFirstResponder === observer && window.firstResponder === observer)

    // Exercise native field editing and the same window lifecycle notifications used by the app,
    // in an offscreen fixture that is never ordered on screen or made key.
    func fields(in view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
    guard let field = fields(in: content).first(where: { $0.isEditable }) else {
      fatalError("Missing native numeric field")
    }
    precondition(window.makeFirstResponder(field))
    precondition(window.firstResponder is NSTextView)
    model.selectedBand = 0
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    drain()
    precondition(model.selectedBand == nil && window.firstResponder === observer)

    window.recalculateKeyViewLoop()
    window.selectNextKeyView(nil)
    precondition(window.firstResponder !== observer && window.firstResponder !== window)
    precondition(window.makeFirstResponder(field))
    let editingResponder = window.firstResponder
    model.selectedBand = 2
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    drain()
    precondition(window.firstResponder === editingResponder && model.selectedBand == 2)

    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    drain()
    precondition(model.selectedBand == nil && window.firstResponder === observer)
    precondition(window.makeFirstResponder(field))
    observer.handleClick(at: CGPoint(x: 20, y: 20), in: window)
    precondition(window.firstResponder === observer && model.selectedBand == nil)
    window.contentView = nil
    window.close()
    print(
      "PASS: initial/reopened editor focus is neutral; Tab and deliberate field editing still work."
    )
  }
  @MainActor
  static func verifySelection(_ model: AppModel) {
    precondition(model.selectedBand == nil)
    let view = BandSelectionObserver.SelectionView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    view.regions = [
      .content: CGRect(x: 0, y: 40, width: 300, height: 220),
      .graph: CGRect(x: 10, y: 50, width: 280, height: 60),
      .band(0): CGRect(x: 10, y: 130, width: 80, height: 120),
      .band(1): CGRect(x: 110, y: 130, width: 80, height: 120),
    ]
    view.select = { model.selectedBand = $0 }
    view.handleClick(at: CGPoint(x: 50, y: 180), in: window)
    precondition(model.selectedBand == 0)
    view.handleClick(at: CGPoint(x: 150, y: 180), in: window)
    precondition(model.selectedBand == 1)
    view.handleClick(at: CGPoint(x: 100, y: 180), in: window)
    precondition(model.selectedBand == nil)  // Gap between strips.
    model.selectedBand = 1
    view.handleClick(at: CGPoint(x: 150, y: 20), in: window)
    precondition(model.selectedBand == nil)  // Header control.
    model.selectedBand = 1
    view.handleClick(at: CGPoint(x: 50, y: 80), in: window)
    precondition(model.selectedBand == 1)  // Graph owns its node hit test.
    view.regions[.band(1)] = CGRect(x: 110, y: 0, width: 80, height: 200)
    view.handleClick(at: CGPoint(x: 150, y: 20), in: window)
    precondition(model.selectedBand == nil)  // Scrolled band under the fixed header.
    window.close()
    print(
      "PASS: selection starts empty, follows band clicks, and clears outside visible band controls."
    )
  }

  @MainActor
  static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

  @MainActor
  static func spectrumFixture(_ model: InputSpectrumModel) {
    let values = (0..<SpectrumFrame.pointCount).map { point -> Float in
      let x = Double(point) / Double(SpectrumFrame.pointCount - 1)
      let bass = 32 * exp(-pow((x - 0.20) / 0.11, 2))
      let voice = 15 * exp(-pow((x - 0.53) / 0.20, 2))
      let texture = sin(x * 87) * 2 + cos(x * 43) * 3
      return Float(max(-90, -69 + bass + voice + texture))
    }
    model.update(
      SpectrumFrame(
        levels: values, sampleRate: 48000, timestamp: ProcessInfo.processInfo.systemUptime))
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    CATransaction.flush()
  }

  @MainActor
  static func verifySpectrumLayers() {
    let model = InputSpectrumModel()
    let view = SpectrumLayerView()
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 198)
    view.bind(model, visible: true, reducedMotion: false)
    view.layoutSubtreeIfNeeded()
    let plot = view.layer!.sublayers!.first!
    let fill = plot.sublayers!.first!
    let mask = fill.mask as! CAShapeLayer
    let tips = plot.sublayers!.last as! CAShapeLayer
    func send(_ levels: [Float], age: Double = 0, rate: Double = 48000) {
      model.update(
        SpectrumFrame(
          levels: levels, sampleRate: rate,
          timestamp: ProcessInfo.processInfo.systemUptime - age))
      RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    }
    func columns() -> [CGRect] {
      var rectangles: [CGRect] = []
      // Each rounded cap is an independent closed subpath: exactly one per lit sample.
      var path = CGMutablePath()
      tips.path?.applyWithBlock { element in
        let item = element.pointee
        switch item.type {
        case .moveToPoint:
          path = CGMutablePath()
          path.move(to: item.points[0])
        case .addLineToPoint: path.addLine(to: item.points[0])
        case .addQuadCurveToPoint:
          path.addQuadCurve(to: item.points[1], control: item.points[0])
        case .addCurveToPoint:
          path.addCurve(to: item.points[2], control1: item.points[0], control2: item.points[1])
        case .closeSubpath: rectangles.append(path.boundingBoxOfPath)
        @unknown default: break
        }
      }
      return rectangles
    }
    spectrumFixture(model)
    precondition(plot.frame == CGRect(x: 34, y: 12, width: 954, height: 160))
    precondition(columns().count == SpectrumFrame.pointCount && mask.path != nil)
    let oldOpacity = fill.opacity
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    precondition(fill.opacity < oldOpacity)
    RunLoop.main.run(until: Date().addingTimeInterval(1.1))
    precondition(mask.path == nil && tips.path == nil)

    var levels = [Float](repeating: SpectrumFrame.floorDB, count: SpectrumFrame.pointCount)
    levels[0] = -45
    levels[96] = 0
    levels[191] = -22.5
    send(levels)
    let caps = columns()
    precondition(caps.count == 3)
    precondition(abs(caps[0].midX) < 0.01 && abs(caps[2].midX - 954) < 0.01)
    precondition(abs(caps[1].midX - 954 * 96 / 191) < 0.01)
    precondition(caps[1].minY < caps[2].minY && caps[2].minY < caps[0].minY)
    precondition(caps[1].minY >= 160 * 0.25)
    view.frame.size = CGSize(width: 700, height: 104)
    view.layoutSubtreeIfNeeded()
    precondition(abs(columns()[2].midX - 654) < 0.01)

    view.bind(model, visible: true, reducedMotion: true)
    spectrumFixture(model)
    precondition(columns().count == SpectrumFrame.pointCount)
    view.bind(model, visible: false, reducedMotion: false)
    spectrumFixture(model)
    precondition(mask.path == nil && tips.path == nil)
    view.bind(model, visible: true, reducedMotion: false)
    send(levels, age: 2, rate: 32000)
    precondition(mask.path == nil && tips.path == nil)
    send([Float](repeating: .nan, count: SpectrumFrame.pointCount))
    precondition(mask.path == nil && tips.path == nil)
    send(levels)
    send([Float](repeating: SpectrumFrame.floorDB, count: SpectrumFrame.pointCount))
    precondition(mask.path == nil && tips.path == nil)
    send(levels)
    send([0])
    precondition(mask.path == nil && tips.path == nil)
    view.disconnect()
    print(
      "PASS: 192 LED columns, sample positions/heights, resize, fade/expiry, Reduce Motion, hide, silence and invalid/stale frames."
    )
  }

  @MainActor
  static func selectionObserver(in view: NSView) -> BandSelectionObserver.SelectionView? {
    if let observer = view as? BandSelectionObserver.SelectionView { return observer }
    for child in view.subviews {
      if let observer = selectionObserver(in: child) { return observer }
    }
    return nil
  }

  @MainActor
  static func render<Content: View>(
    _ content: Content, width: CGFloat, height: CGFloat? = nil, to url: URL,
    prepare: (() -> Void)? = nil
  ) throws {
    let view = NSHostingView(
      rootView: content.frame(width: width, height: height).preferredColorScheme(.dark))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    let finalHeight = height ?? ceil(view.fittingSize.height)
    window.setContentSize(NSSize(width: width, height: finalHeight))
    view.setFrameSize(NSSize(width: width, height: finalHeight))
    drain()
    view.layoutSubtreeIfNeeded()
    prepare?()
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * 2), pixelsHigh: Int(finalHeight * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("Cannot allocate preview") }
    bitmap.size = NSSize(width: width, height: finalHeight)
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      fatalError("Cannot encode preview")
    }
    try data.write(to: url)
    print("\(url.lastPathComponent): \(Int(width)) × \(Int(finalHeight))")
    window.contentView = nil
    window.close()
  }
}
