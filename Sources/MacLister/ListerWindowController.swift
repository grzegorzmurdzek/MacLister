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
        window.collectionBehavior = ListerManager.desktopBehavior
        window.minSize = Settings.minListerSize
        super.init(window: window)

        window.delegate = self
        window.titleBarMenuProvider = { [weak self] in self?.listerViewController?.makeTitleBarMenu() }
        window.contentViewController = ListerViewController(model: model)
        window.setContentSize(Settings.listerContentSize)

        // Title and the line under it come from the title format (Lister Title…).
        let model = model
        Publishers.MergeMany([
            model.$url.map { _ in () }.eraseToAnyPublisher(), model.$label.map { _ in () }.eraseToAnyPublisher(),
            model.$items.map { _ in () }.eraseToAnyPublisher(), model.$role.map { _ in () }.eraseToAnyPublisher(),
            model.$roleLocked.map { _ in () }.eraseToAnyPublisher(), model.$filter.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedURLs.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .titleFormatChanged).map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)         // the @Published values have changed by then
        .sink { [weak self] in self?.updateTitle() }
        .store(in: &cancellables)
        updateTitle()
    }

    /// Applies the title format to the window.
    func updateTitle() {
        guard let window else { return }
        let context = TitleFormat.context(for: model)
        window.title = TitleFormat.render(TitleFormat.title, context)
        window.subtitle = TitleFormat.render(TitleFormat.subtitle, context)
        window.representedURL = model.url.isFileURL && !model.isVirtual ? model.url : nil      // proxy icon; ⌘-click the title for the path menu
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
        if !model.label.isEmpty { title = "\(model.label)  ·  \(title)" }
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
    private var progressSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    /// Called (main queue) whenever any lister starts, advances or ends a job; drives the menu-bar icon.
    var onProgressChange: (() -> Void)?

    var activeProgress: [TransferStatus] { controllers.compactMap { $0.model.progress } }

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

    /// The lister Tab (or Shift-Tab) goes to: the next one in the order they were opened, wrapping around.
    func neighbour(of current: ListerWindowController?, forward: Bool) -> ListerWindowController? {
        let visible = controllers.filter { $0.window?.isMiniaturized == false }
        guard visible.count > 1 else { return nil }
        let index = current.flatMap { c in visible.firstIndex { $0 === c } } ?? 0
        return visible[(index + (forward ? 1 : visible.count - 1)) % visible.count]
    }

    /// How lister windows behave across macOS desktops (Spaces): follow the setting.
    static var desktopBehavior: NSWindow.CollectionBehavior {
        Settings.listersOnAllDesktops ? [.canJoinAllSpaces] : []
    }

    /// Applies the "all desktops" setting to the windows that are open.
    func applyDesktopBehavior() {
        for controller in controllers { controller.window?.collectionBehavior = Self.desktopBehavior }
    }

    /// Brings every lister to the desktop (Space) that is showing now, raises them and gives the first the keyboard.
    /// macOS has no way to send windows to a particular desktop, so the usual routine is: switch to the desktop you want
    /// (a new, empty one for a "lister desktop"), then run this.
    func gatherOnThisDesktop() {
        guard !controllers.isEmpty else { return }
        for controller in controllers {
            guard let window = controller.window else { continue }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !Settings.listersOnAllDesktops { window.collectionBehavior = [.moveToActiveSpace] }   // ordered front, it joins the desktop in view
        }
        bringAllToFront()
        // the flag is only for the move: afterwards a lister stays on its desktop like any window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.applyDesktopBehavior() }
    }

    /// Tab / Shift-Tab: the keyboard moves to the next (or previous) lister.
    func focusNeighbour(of current: ListerWindowController?, forward: Bool) {
        guard let next = neighbour(of: current, forward: forward) else { NSSound.beep(); return }
        next.window?.makeKeyAndOrderFront(nil)
        if let table = next.listerViewController?.tableView { next.window?.makeFirstResponder(table) }
    }

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
        if let window = controller.window, let snapshot = SnapshotStore.shared.snapshot(for: directory) {
            window.setContentSize(NSSize(width: snapshot.width, height: snapshot.height))
            if case .cascade = anchor, let x = snapshot.x, let y = snapshot.y { snapshotOrigin = visibleOrigin(NSPoint(x: x, y: y), size: window.frame.size) }
        }
        // $progress publishes before the value changes, so look at it on the next turn of the run loop
        progressSubscriptions[ObjectIdentifier(controller)] = controller.model.$progress.sink { [weak self] _ in
            DispatchQueue.main.async { self?.onProgressChange?() }
        }
        configure?(controller)

        if let window = controller.window {
            window.setFrameOrigin(snapshotOrigin ?? origin(for: window.frame.size, anchor: anchor))
            snapshotOrigin = nil
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
        guard !controller.model.roleLocked else {
            controller.model.flash(tr("This lister's role is locked: unlock it first"))
            return
        }
        if controller.model.role == role {
            controller.model.role = .none
            return
        }
        if let holder = controllers.first(where: { $0.model.role == role }), holder.model.roleLocked {
            controller.model.flash(role == .source ? tr("The source lister is locked") : tr("The destination lister is locked"))
            return
        }
        for other in controllers where other.model.role == role { other.model.role = .none }
        controller.model.role = role
    }

    /// Locks or unlocks the role of a lister (only meaningful while it has one).
    func toggleRoleLock(for controller: ListerWindowController) {
        guard controller.model.role != .none else {
            controller.model.flash(tr("Set this lister as source or destination first"))
            return
        }
        controller.model.roleLocked.toggle()
    }

    func swapRoles() {
        let source = sourceController, destination = destinationController
        if source?.model.roleLocked == true || destination?.model.roleLocked == true {
            (source ?? destination)?.model.flash(tr("A locked lister cannot swap roles"))
            return
        }
        source?.model.role = .destination
        destination?.model.role = .source
    }

    /// Re-reads every lister that shows one of the given folders.
    func reloadListers(showing urls: [URL], selecting: [ObjectIdentifier: URL] = [:]) {
        let paths = Set(urls.map(ListerModel.comparisonKey))
        for controller in controllers where paths.contains(ListerModel.comparisonKey(controller.model.url)) {
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
        progressSubscriptions[ObjectIdentifier(controller)] = nil
        DispatchQueue.main.async { [weak self] in self?.onProgressChange?() }
    }

    /// Where a snapshot wants the next window (set and used inside openLister).
    private var snapshotOrigin: NSPoint?

    /// `origin`, moved so the window stays on a screen (the screen of the snapshot may be gone).
    private func visibleOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        return NSPoint(x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
                       y: max(visible.minY, min(origin.y, visible.maxY - size.height)))
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
