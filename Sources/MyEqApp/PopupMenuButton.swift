import AppKit
import SwiftUI

/// A normal, keyboard-accessible SwiftUI button with an anchored native menu.
/// Unlike Menu's macOS label adapter, this preserves multi-line custom labels.
struct PopupMenuButton<Label: View>: View {
  let makeMenu: () -> ActionMenu
  @ViewBuilder let label: () -> Label
  @StateObject private var anchor = MenuAnchorReference()

  var body: some View {
    Button {
      guard let view = anchor.view, view.window != nil else { return }
      let menu = makeMenu()
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 5), in: view)
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .background(MenuAnchor(reference: anchor))
  }
}

@MainActor
final class ActionMenu: NSMenu {
  init() {
    super.init(title: "")
    autoenablesItems = false
  }
  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func choice(
    _ title: String, selected: Bool = false, enabled: Bool = true,
    action: @escaping () -> Void
  ) {
    let item = ActionMenuItem(title: title, action: action)
    item.state = selected ? .on : .off
    item.isEnabled = enabled
    addItem(item)
  }
  func separator() { addItem(.separator()) }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
  private let handler: () -> Void
  init(title: String, action: @escaping () -> Void) {
    handler = action
    super.init(title: title, action: #selector(invoke), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  @objc private func invoke() { handler() }
}

@MainActor
private final class MenuAnchorReference: ObservableObject {
  weak var view: NSView?
}

private struct MenuAnchor: NSViewRepresentable {
  let reference: MenuAnchorReference
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    reference.view = view
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { reference.view = view }
}
