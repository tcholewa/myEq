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
  static func selectionObserver(in view: NSView) -> BandSelectionObserver.SelectionView? {
    if let observer = view as? BandSelectionObserver.SelectionView { return observer }
    for child in view.subviews {
      if let observer = selectionObserver(in: child) { return observer }
    }
    return nil
  }

  @MainActor
  static func render<Content: View>(
    _ content: Content, width: CGFloat, height: CGFloat? = nil, to url: URL
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
