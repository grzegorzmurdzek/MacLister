import AppKit
import SwiftUI

/// Sits on top of a button that has a menu (`ListerButton.menu`) and answers the left mouse button:
///  - a click does the button's own action, as it always did;
///  - holding the button down for a moment opens the menu;
///  - with the arrow shown (Settings → Buttons), a click on the arrow opens the menu at once.
/// The right and middle buttons are left to `MouseButtonCatcher`.
struct ButtonMenuTrigger: NSViewRepresentable {
    var button: ListerButton
    var showsArrow: Bool
    /// false for an action that needs a selection when nothing is selected.
    var canRun: (ListerButton) -> Bool
    var run: (ListerButton) -> Void
    /// The button is held down (true) or let go (false), so the bar can draw it pressed.
    var onPress: (Bool) -> Void

    func makeNSView(context: Context) -> MenuHoldView {
        let view = MenuHoldView()
        update(view)
        return view
    }

    func updateNSView(_ view: MenuHoldView, context: Context) { update(view) }

    private func update(_ view: MenuHoldView) {
        view.button = button
        view.arrowWidth = showsArrow ? Self.arrowWidth : 0
        view.canRun = canRun
        view.run = run
        view.onPress = onPress
    }

    /// The part at the right edge of the button that the arrow occupies.
    static let arrowWidth: CGFloat = 16

    final class MenuHoldView: NSView {
        var button = ListerButton(title: "", symbol: nil, action: .separator)
        var arrowWidth: CGFloat = 0
        var canRun: (ListerButton) -> Bool = { _ in true }
        var run: (ListerButton) -> Void = { _ in }
        var onPress: (Bool) -> Void = { _ in }

        /// How long the button must be held before the menu opens.
        static let holdDelay: TimeInterval = 0.35

        /// Only the press of the left button is ours; hovering and the other buttons fall through.
        static func accepts(_ type: NSEvent.EventType?) -> Bool { type == .leftMouseDown }

        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.accepts(NSApp.currentEvent?.type) ? super.hitTest(point) : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Is this point on the arrow (the right edge of the button)?
        func isOnArrow(_ point: NSPoint) -> Bool { arrowWidth > 0 && point.x >= bounds.maxX - arrowWidth }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if isOnArrow(convert(event.locationInWindow, from: nil)) { showMenu(); return }
            onPress(true)
            var inside = true
            let deadline = Date(timeIntervalSinceNow: Self.holdDelay)
            // Follow the mouse until it is let go, or the hold time is over.
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: true) {
                inside = bounds.contains(convert(next.locationInWindow, from: nil))
                if next.type == .leftMouseUp {
                    onPress(false)
                    if inside { DispatchQueue.main.async { [weak self] in self?.click() } }
                    return
                }
            }
            onPress(false)
            if inside { showMenu() }
        }

        /// A plain click: the button's own action.
        func click() {
            if canRun(button) { run(button) } else { NSSound.beep() }
        }

        /// The menu of the button; entries that need a selection are dimmed while nothing is selected.
        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in button.menu ?? [] {
                if entry.action == .separator { menu.addItem(.separator()); continue }
                let item = EntryItem(title: entry.menuTitle, action: #selector(EntryItem.fire), keyEquivalent: "")
                item.target = item
                item.isEnabled = canRun(entry)
                let symbol = (entry.symbol?.isEmpty == false) ? entry.symbol! : entry.action.suggestedSymbol
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.handler = { [weak self] in self?.run(entry) }
                menu.addItem(item)
            }
            return menu
        }

        /// The point the menu is shown at: its top-left corner goes there. Below the button that is the button's bottom
        /// edge; above it, the top edge raised by the height of the menu (the view is not flipped: y grows upwards).
        static func menuAnchor(above: Bool, buttonHeight: CGFloat, menuHeight: CGFloat) -> NSPoint {
            NSPoint(x: 0, y: above ? buttonHeight + menuHeight : 0)
        }

        func showMenu() {
            onPress(false)
            let menu = makeMenu()
            let above = Settings.buttonMenuDirection.opensAbove(barPosition: Settings.buttonBarPosition)
            let anchor = Self.menuAnchor(above: above, buttonHeight: bounds.height, menuHeight: menu.size.height)
            menu.popUp(positioning: nil, at: anchor, in: self)
        }
    }

    /// A menu entry that runs a closure.
    final class EntryItem: NSMenuItem {
        var handler: (() -> Void)?
        @objc func fire() {
            let run = handler
            DispatchQueue.main.async { run?() }
        }
    }
}
