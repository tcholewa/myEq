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

  func makeNSView(context: Context) -> SelectionView { SelectionView() }
  func updateNSView(_ view: SelectionView, context: Context) {
    view.regions = regions
    view.select = select
  }
  static func dismantleNSView(_ view: SelectionView, coordinator: ()) { view.disconnect() }

  final class SelectionView: NSView {
    var regions: [SelectionRegion: CGRect] = [:]
    var select: ((Int?) -> Void)?
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disconnect()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        self.handleClick(at: self.convert(event.locationInWindow, from: nil), in: window)
        return event
      }
    }
    func handleClick(at point: CGPoint, in window: NSWindow) {
      let insideContent = regions[.content]?.contains(point) == true
      for (region, frame) in regions where insideContent && frame.contains(point) {
        if case .band(let index) = region {
          select?(index)
          return
        }
      }
      window.makeFirstResponder(nil)
      // The graph resolves which node is under the pointer; blank graph space clears selection.
      if !insideContent || regions[.graph]?.contains(point) != true { select?(nil) }
    }
    func disconnect() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
