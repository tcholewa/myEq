import AppKit
import SwiftUI

/// Watches only the editor's window; opening the menu bar does not enable visuals.
struct EditorVisibilityObserver: NSViewRepresentable {
  let onChange: (Bool) -> Void

  func makeNSView(context: Context) -> VisibilityView {
    let view = VisibilityView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: VisibilityView, context: Context) { view.onChange = onChange }

  static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.disconnect() }

  final class VisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var lastVisible = false
    private var pendingChange: DispatchWorkItem?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self)
      guard let window else {
        report(false)
        return
      }
      for name in [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
      ] {
        center.addObserver(
          self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
      }
      center.addObserver(
        self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification,
        object: window)
      for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
        center.addObserver(
          self, selector: #selector(visibilityChanged(_:)), name: name, object: NSApp)
      }
      updateVisibility()
    }

    @objc private func visibilityChanged(_ notification: Notification) { updateVisibility() }

    private func updateVisibility() {
      guard let window else {
        report(false)
        return
      }
      report(
        window.isVisible && !window.isMiniaturized && !NSApp.isHidden
          && window.occlusionState.contains(.visible))
    }

    @objc private func windowClosing(_ notification: Notification) { report(false) }

    private func report(_ visible: Bool) {
      guard lastVisible != visible else { return }
      lastVisible = visible
      pendingChange?.cancel()
      let callback = onChange
      // Avoid publishing SwiftUI state during NSView attachment/detachment.
      let work = DispatchWorkItem { callback?(visible) }
      pendingChange = work
      DispatchQueue.main.async(execute: work)
    }

    func disconnect() {
      NotificationCenter.default.removeObserver(self)
      report(false)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
  }
}
