import AppKit
import SwiftUI

enum SelectionRegion: Hashable {
  case band(Int)
  case graph
  case content
}

struct SelectionRegionsKey: PreferenceKey {
  static let defaultValue: [SelectionRegion: CGRect] = [:]
  static func reduce(
    value: inout [SelectionRegion: CGRect], nextValue: () -> [SelectionRegion: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  func selectionRegion(_ region: SelectionRegion) -> some View {
    background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: SelectionRegionsKey.self,
          value: [region: geometry.frame(in: .named("equalizer"))])
      })
  }
}

/// Watches only clicks in this editor. It leaves the original event untouched, so native
/// fields, popup buttons, and fader drags keep their normal mouse handling.
struct BandSelectionObserver: NSViewRepresentable {
  let regions: [SelectionRegion: CGRect]
  let select: (Int?) -> Void

  func makeNSView(context: Context) -> SelectionView {
    let view = SelectionView()
    view.regions = regions
    view.select = select
    return view
  }
  func updateNSView(_ view: SelectionView, context: Context) {
    view.regions = regions
    view.select = select
  }
  static func dismantleNSView(_ view: SelectionView, coordinator: ()) { view.disconnect() }

  final class SelectionView: NSView {
    var regions: [SelectionRegion: CGRect] = [:]
    var select: ((Int?) -> Void)?
    private var monitor: Any?
    private var needsInitialFocus = true
    private var pendingFocus: DispatchWorkItem?
    override var isFlipped: Bool { true }
    // A neutral initial responder prevents AppKit from selecting the first numeric field.
    // It draws nothing and leaves the editor's normal key-view loop available to Tab.
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disconnect()
      guard window != nil else { return }
      window?.initialFirstResponder = self
      needsInitialFocus = true
      let center = NotificationCenter.default
      center.addObserver(
        self, selector: #selector(windowOpened), name: NSWindow.didBecomeKeyNotification,
        object: window)
      center.addObserver(
        self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification,
        object: window)
      prepareInitialFocus()
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        self.handleClick(at: self.convert(event.locationInWindow, from: nil), in: window)
        return event
      }
    }
    @objc private func windowOpened() { prepareInitialFocus(presented: true) }
    @objc private func windowClosed() {
      pendingFocus?.cancel()
      needsInitialFocus = true
    }
    private func prepareInitialFocus(presented: Bool = false) {
      guard needsInitialFocus, let window else { return }
      pendingFocus?.cancel()
      // SwiftUI can install its text-field responder during the same attachment pass.
      // Run once afterward, never on routine view updates or while editing a field.
      let work = DispatchWorkItem { [weak self, weak window] in
        guard let self, let window, self.window === window, self.needsInitialFocus else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
        self.select?(nil)
        if presented || window.isKeyWindow { self.needsInitialFocus = false }
      }
      pendingFocus = work
      DispatchQueue.main.async(execute: work)
    }
    func handleClick(at point: CGPoint, in window: NSWindow) {
      // A real click owns focus even if it arrives before the deferred initial reset.
      pendingFocus?.cancel()
      needsInitialFocus = false
      let insideContent = regions[.content]?.contains(point) == true
      for (region, frame) in regions where insideContent && frame.contains(point) {
        if case .band(let index) = region {
          select?(index)
          return
        }
      }
      window.makeFirstResponder(self)
      // The graph resolves which node is under the pointer; blank graph space clears selection.
      if !insideContent || regions[.graph]?.contains(point) != true { select?(nil) }
    }
    func disconnect() {
      pendingFocus?.cancel()
      pendingFocus = nil
      NotificationCenter.default.removeObserver(self)
      if window?.initialFirstResponder === self { window?.initialFirstResponder = nil }
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    deinit {
      pendingFocus?.cancel()
      NotificationCenter.default.removeObserver(self)
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
