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
  static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

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
