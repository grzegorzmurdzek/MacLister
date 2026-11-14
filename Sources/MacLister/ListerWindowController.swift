import AppKit
import Combine

/// The lister window. macOS gives titled windows no title-bar context menu, so a right-click (or
/// ctrl-click) on the title bar is intercepted here and answered with the lister menu.
final class ListerWindow: NSWindow {
    var titleBarMenuProvider: (() -> NSMenu?)?

    /// `point` is in window coordinates; the title bar is everything above the content area.
    func isInTitleBar(_ point: NSPoint) -> Bool {
        point.y > contentLayoutRect.maxY && point.y <= frame.height
    }

    override func sendEvent(_ event: NSEvent) {
        let isMenuClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isMenuClick, isInTitleBar(event.locationInWindow), let content = contentView,
           let menu = titleBarMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: content)
            return
        }
        super.sendEvent(event)
    }
}

/// One window controller per open lister; several can exist at once.
final class ListerWindowController: NSWindowController, NSWindowDelegate {
    let model: ListerModel
    private var cancellables = Set<AnyCancellable>()

    init(directory: URL) {
        model = ListerModel(url: directory)

        let window = ListerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false      // lifetime is owned by ListerManager
        window.minSize = Settings.minListerSize
        super.init(window: window)

        window.delegate = self
        window.titleBarMenuProvider = { [weak self] in self?.listerViewController?.makeTitleBarMenu() }
        window.contentViewController = ListerViewController(model: model)
        window.setContentSize(Settings.listerContentSize)

        model.$url
            .sink { [weak window] url in
                window?.title = FileManager.default.displayName(atPath: url.path)
                window?.representedURL = url          // proxy icon; ⌘-click the title for the path menu
            }
            .store(in: &cancellables)
        Publishers.CombineLatest(model.$items, model.$role)
            .sink { [weak window] items, role in
                var text = "\(items.count) items"
                switch role {
                case .source:      text += " · SOURCE"
                case .destination: text += " · DESTINATION"
                case .none:        break
                }
                window?.subtitle = text
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var listerViewController: ListerViewController? { window?.contentViewController as? ListerViewController }

    /// Entry in the menu-bar list of listers: "Documents — ~/Documents   [SRC]".
    var menuTitle: String {
        let name = FileManager.default.displayName(atPath: model.url.path)
        let path = (model.url.path as NSString).abbreviatingWithTildeInPath
        let role: String
        switch model.role {
        case .source:      role = "   [SRC]"
        case .destination: role = "   [DST]"
        case .none:        role = ""
        }
        var title = path == name || path == "/" ? name : "\(name) — \(path)"
        if title.count > 64 { title = String(title.prefix(30)) + "…" + String(title.suffix(32)) }
        return title + role
    }

    /// New listers start with the size the user last chose.
    func windowDidEndLiveResize(_ notification: Notification) {
        if let size = window?.contentLayoutRect.size { Settings.listerContentSize = size }
    }

    func windowWillClose(_ notification: Notification) {
        ListerManager.shared.remove(self)
    }
}

/// Owns all open listers and decides where a new one appears.
final class ListerManager {
    static let shared = ListerManager()

    enum Anchor {
        /// Cocoa screen point (bottom-left origin). `centered`: window centered on it, otherwise
        /// the window's top-left corner sits exactly on it.
        case cursor(NSPoint, centered: Bool)
        /// Slightly offset from an existing lister (or the mouse, if there is none).
        case cascade(from: NSWindow?)
        /// Exact bottom-left corner (clamped to the screen), used when restoring a saved layout.
        case origin(NSPoint)
    }

    private var controllers: [ListerWindowController] = []
    /// The lister that was key most recently (the "frontmost" one even while another app is active).
    private weak var lastActive: ListerWindowController?

    private init() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            if let controller = (note.object as? NSWindow)?.windowController as? ListerWindowController {
                self?.lastActive = controller
            }
        }
    }

    var frontmost: ListerWindowController? { lastActive ?? controllers.last }

    var openCount: Int { controllers.count }
    var allControllers: [ListerWindowController] { controllers }

    /// Puts one lister above every other app's windows and gives it keyboard focus.
    func bringToFront(_ controller: ListerWindowController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.bringToFront()
        raise(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Raises every lister above all other windows, keeping their relative order; the first one
    /// ends up key.
    func bringAllToFront() {
        NSApp.bringToFront()
        for controller in controllers.reversed() {
            guard let window = controller.window else { continue }
            if window.isMiniaturized { window.deminiaturize(nil) }
            raise(window)
        }
        controllers.first?.window?.makeKeyAndOrderFront(nil)
    }

    /// Floating level for a moment puts the window above every other app's normal windows even when
    /// activation is refused; it drops back to .normal so the lister behaves like any window.
    fileprivate func raise(_ window: NSWindow) {
        window.level = .floating
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
            guard let window else { return }
            window.level = .normal
            window.orderFrontRegardless()   // re-assert the position at the front of the normal level
        }
    }

    func closeAll() {
        for controller in controllers { controller.close() }   // windowWillClose removes each one
    }

    /// `configure` runs before the window is positioned and shown (set size, copy settings…).
    @discardableResult
    func openLister(directory: URL, anchor: Anchor,
                    configure: ((ListerWindowController) -> Void)? = nil) -> ListerWindowController {
        let controller = ListerWindowController(directory: directory)
        controllers.append(controller)
        configure?(controller)

        if let window = controller.window {
            window.setFrameOrigin(origin(for: window.frame.size, anchor: anchor))
            // The desktop click made Finder the active app, and macOS 14+ refuses a plain activation
            // from the background. orderFrontRegardless puts the window above other apps' windows
            // without needing activation; activate + makeKey then give it keyboard focus when allowed.
            controller.showWindow(nil)
            raise(window)
            NSApp.bringToFront()
            window.makeKeyAndOrderFront(nil)
            if Settings.debugHitTest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
                    if let window { DebugLog.write("lister shown: appActive=\(NSApp.isActive) key=\(window.isKeyWindow)") }
                }
            }
        }
        return controller
    }

    // MARK: Source / destination

    var sourceController: ListerWindowController? { controllers.first { $0.model.role == .source } }
    var destinationController: ListerWindowController? { controllers.first { $0.model.role == .destination } }

    /// One source and one destination at most; pressing the active role again clears it.
    func toggleRole(_ role: ListerRole, for controller: ListerWindowController) {
        if controller.model.role == role {
            controller.model.role = .none
            return
        }
        for other in controllers where other.model.role == role { other.model.role = .none }
        controller.model.role = role
    }

    func swapRoles() {
        let source = sourceController, destination = destinationController
        source?.model.role = .destination
        destination?.model.role = .source
    }

    /// Re-reads every lister that shows one of the given folders.
    func reloadListers(showing urls: [URL], selecting: [ObjectIdentifier: URL] = [:]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        for controller in controllers where paths.contains(controller.model.url.standardizedFileURL.path) {
            controller.model.reload(selecting: selecting[ObjectIdentifier(controller)])
        }
    }

    /// A second lister on the same folder with the same size, sort, hidden-files and filter settings.
    @discardableResult
    func duplicate(_ original: ListerWindowController) -> ListerWindowController {
        let selected = original.model.selectedURLs.first
        return openLister(directory: original.model.url, anchor: .cascade(from: original.window)) { copy in
            copy.model.inherit(from: original.model)
            if let size = original.window?.contentLayoutRect.size { copy.window?.setContentSize(size) }
            copy.model.reload(selecting: selected)
        }
    }

    fileprivate func remove(_ controller: ListerWindowController) {
        controllers.removeAll { $0 === controller }
    }

    private func origin(for size: NSSize, anchor: Anchor) -> NSPoint {
        var origin: NSPoint
        let reference: NSPoint
        switch anchor {
        case let .cursor(point, centered):
            reference = point
            origin = centered
                ? NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
                : NSPoint(x: point.x, y: point.y - size.height)
        case let .origin(point):
            reference = point
            origin = point
        case let .cascade(window):
            if let frame = window?.frame {
                reference = NSPoint(x: frame.minX, y: frame.maxY)
                origin = NSPoint(x: frame.minX + 28, y: frame.minY - 28)
            } else {
                reference = NSEvent.mouseLocation
                origin = NSPoint(x: reference.x, y: reference.y - size.height)
            }
        }

        // Keep the whole window on the screen that contains the reference point.
        let screen = NSScreen.screens.first { $0.frame.contains(reference) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        return origin
    }
}

extension NSApplication {
    func bringToFront() {
        // The flag is deprecated since macOS 14 but still honoured in practice; the cooperative
        // activate() alone is refused when another app (Finder after a desktop click) is active.
        activate(ignoringOtherApps: true)
    }
}
