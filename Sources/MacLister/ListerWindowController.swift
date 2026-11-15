import AppKit
import Combine

/// The lister window. macOS gives titled windows no title-bar context menu, so a right-click (or
/// ctrl-click) on the title bar is intercepted here and answered with the lister menu.
final class ListerWindow: NSWindow {
    var titleBarMenuProvider: (() -> NSMenu?)?
    /// The other tabs of the window, taken as it starts to close: AppKit may take a closing tab out of its group
    /// before windowWillClose, and the window's role has to go to one of them.
    private(set) var tabsAtClose: [NSWindow] = []

    override func close() {
        tabsAtClose = (tabbedWindows ?? []).filter { $0 !== self }
        super.close()
    }

    /// `point` is in window coordinates; the title bar is everything above the content area.
    func isInTitleBar(_ point: NSPoint) -> Bool {
        point.y > contentLayoutRect.maxY && point.y <= frame.height
    }

    override func sendEvent(_ event: NSEvent) {
        let isMenuClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isMenuClick, isInTitleBar(event.locationInWindow) {
            // A right-click on a tab that is not shown shows it first: the menu is about that tab.
            var target: ListerWindow = self
            if let tab = tab(at: event.locationInWindow) as? ListerWindow, tab !== self,
               let controller = tab.windowController as? ListerWindowController {
                ListerManager.shared.select(controller)
                target = tab
            }
            if let content = target.contentView, let menu = target.titleBarMenuProvider?() {
                NSMenu.popUpContextMenu(menu, with: event, for: content)
                return
            }
        }
        super.sendEvent(event)
    }

    /// The window of the tab under `point` (window coordinates) while the tab bar shows; nil elsewhere.
    /// AppKit's tab bar has one tab button per tab, left to right in tab order.
    func tab(at point: NSPoint) -> NSWindow? {
        guard let tabbed = tabbedWindows, tabbed.count > 1, let frameView = contentView?.superview,
              var button = frameView.hitTest(point) else { return nil }
        func isTabButton(_ view: NSView) -> Bool { String(describing: type(of: view)).contains("TabButton") }
        while !isTabButton(button) {
            guard let up = button.superview else { return nil }
            button = up
        }
        var bar = button.superview
        while let view = bar, !String(describing: type(of: view)).hasSuffix("TabBar") { bar = view.superview }
        guard let bar else { return nil }
        var buttons: [NSView] = []
        func collect(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if isTabButton(sub) { buttons.append(sub) } else { collect(sub) }
            }
        }
        collect(bar)
        buttons.sort { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        if buttons.count == tabbed.count + 1 { buttons.removeLast() }      // the + button, right of the tabs
        guard buttons.count == tabbed.count, let index = buttons.firstIndex(where: { $0 === button }) else { return nil }
        return tabbed[index]
    }
}

/// The label colour of a lister, as a dot in its tab.
final class TabColorDot: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 10), heightAnchor.constraint(equalToConstant: 10)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
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
        // Tabs (Settings → Listers) are native window tabs, as in Finder: every tab is a lister of its own.
        window.tabbingIdentifier = ListerManager.tabbingIdentifier
        window.tabbingMode = Settings.listerTabs ? .automatic : .disallowed
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
        // proxy icon; ⌘-click the title for the path menu (inside an archive: the archive itself)
        window.representedURL = model.url.isFileURL && !model.isVirtual ? ArchiveBrowser.shared.realFile(for: model.url) : nil
        updateTab()
    }

    /// The tab shows the lister's name (Name This Tab…), else the folder's name; a coloured dot for the label colour.
    func updateTab() {
        guard let tab = window?.tab else { return }
        tab.title = model.displayName
        tab.toolTip = (ListerModel.displayPath(model.url) as NSString).abbreviatingWithTildeInPath
        // the tab bar draws titles in its own colours, so the label colour is a view beside the title
        let color = LabelPalette.color(model.labelColor).map { NSColor($0) }
        if let color {
            if let dot = tab.accessoryView as? TabColorDot { dot.color = color } else { tab.accessoryView = TabColorDot(color: color) }
        } else if tab.accessoryView != nil {
            tab.accessoryView = nil
        }
    }

    /// The + button of the tab bar: a new tab on the folder this one shows.
    override func newWindowForTab(_ sender: Any?) {
        ListerManager.shared.newTab(from: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var listerViewController: ListerViewController? { window?.contentViewController as? ListerViewController }

    /// Entry in the menu-bar list of listers: "Documents — ~/Documents   [SRC]".
    var menuTitle: String {
        let inArchive = model.isInArchive
        let name = inArchive ? model.displayName : FileManager.default.displayName(atPath: model.url.path)
        let path = ((inArchive ? ListerModel.displayPath(model.url) : model.url.path) as NSString).abbreviatingWithTildeInPath
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

    /// Clicking a tab makes its lister key: the window's source / destination role goes along to it.
    func windowDidBecomeKey(_ notification: Notification) {
        ListerManager.shared.moveRoleToSelectedTab(in: self)
    }

    func windowWillClose(_ notification: Notification) {
        let manager = ListerManager.shared
        let remembered = ((window as? ListerWindow)?.tabsAtClose ?? []).compactMap { $0.windowController as? ListerWindowController }
        let siblings = remembered.isEmpty ? manager.tabs(of: self).filter { $0 !== self } : remembered
        manager.remove(self)
        // Closing the tab that holds the window's role leaves the role with the tab that is shown next.
        let role = model.role, locked = model.roleLocked
        guard role != .none, !siblings.isEmpty else { return }
        DispatchQueue.main.async {
            let open = siblings.filter { sibling in manager.allControllers.contains { $0 === sibling } }
            guard let next = open.first(where: manager.isSelectedTab) ?? open.first, next.model.role == .none,
                  !manager.allControllers.contains(where: { $0.model.role == role }) else { return }
            next.model.role = role
            next.model.roleLocked = locked
        }
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

    /// Listers that may share a window as tabs.
    static let tabbingIdentifier = "com.example.MacLister.lister"

    var openCount: Int { controllers.count }
    var allControllers: [ListerWindowController] { controllers }

    /// The lister Tab (or Shift-Tab) goes to: the next one in the order they were opened, wrapping around.
    func neighbour(of current: ListerWindowController?, forward: Bool) -> ListerWindowController? {
        let visible = controllers.filter { $0.window?.isMiniaturized == false && isSelectedTab($0) }
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
        if let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        NSApp.bringToFront()
        raise(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Raises every lister above all other windows, keeping their relative order; the first one
    /// ends up key.
    func bringAllToFront() {
        NSApp.bringToFront()
        let shown = controllers.filter(isSelectedTab)          // a tab behind another one is raised with its window
        for controller in shown.reversed() {
            guard let window = controller.window else { continue }
            if window.isMiniaturized { window.deminiaturize(nil) }
            raise(window)
        }
        shown.first?.window?.makeKeyAndOrderFront(nil)
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
        register(controller)
        if let window = controller.window, let snapshot = SnapshotStore.shared.snapshot(for: directory) {
            window.setContentSize(NSSize(width: snapshot.width, height: snapshot.height))
            if case .cascade = anchor, let x = snapshot.x, let y = snapshot.y { snapshotOrigin = visibleOrigin(NSPoint(x: x, y: y), size: window.frame.size) }
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

    /// Every new lister, window or tab, is known to the manager from the start.
    private func register(_ controller: ListerWindowController) {
        controllers.append(controller)
        // $progress publishes before the value changes, so look at it on the next turn of the run loop
        progressSubscriptions[ObjectIdentifier(controller)] = controller.model.$progress.sink { [weak self] _ in
            DispatchQueue.main.async { self?.onProgressChange?() }
        }
    }

    // MARK: Tabs

    /// The listers that share a window with `controller`, in tab order; just the lister itself when it has no tabs.
    func tabs(of controller: ListerWindowController) -> [ListerWindowController] {
        guard let tabbed = controller.window?.tabbedWindows, tabbed.count > 1 else { return [controller] }
        // a tab being closed stays in the group for a moment; it no longer counts
        let listers = tabbed.compactMap { $0.windowController as? ListerWindowController }
            .filter { lister in lister === controller || controllers.contains { $0 === lister } }
        return listers.contains { $0 === controller } ? listers : [controller]
    }

    /// The tab you see (a lister without tabs always is).
    func isSelectedTab(_ controller: ListerWindowController) -> Bool {
        guard let window = controller.window else { return false }
        guard tabs(of: controller).count > 1, let selected = window.tabGroup?.selectedWindow else { return true }
        return selected === window
    }

    /// Opens a lister on `directory` as a new tab next to `host` and shows it. Nil (with a message) while tabs are off.
    @discardableResult
    func openTab(directory: URL, in host: ListerWindowController,
                 configure: ((ListerWindowController) -> Void)? = nil) -> ListerWindowController? {
        guard Settings.listerTabs, let hostWindow = host.window else {
            host.model.flash(tr("Tabs are off: turn them on in Settings → Listers"))
            return nil
        }
        hostWindow.tabbingMode = .automatic
        let controller = ListerWindowController(directory: directory)
        register(controller)
        configure?(controller)
        guard let window = controller.window else { return controller }
        hostWindow.addTabbedWindow(window, ordered: .above)    // the tab takes the window's frame
        window.makeKeyAndOrderFront(nil)
        if let table = controller.listerViewController?.tableView { window.makeFirstResponder(table) }
        moveRoleToSelectedTab(in: controller)
        return controller
    }

    /// ⌘T: a new tab on the folder `host` shows, with its sort order and hidden-files setting (not its filter).
    @discardableResult
    func newTab(from host: ListerWindowController) -> ListerWindowController? {
        openFolder(host.model.url, inNewTabFrom: host)
    }

    @discardableResult
    func openFolder(_ folder: URL, inNewTabFrom host: ListerWindowController) -> ListerWindowController? {
        let model = host.model
        return openTab(directory: folder, in: host) { tab in
            tab.model.apply(sort: model.sortKey, ascending: model.ascending, showHidden: model.showHidden, filter: "")
            tab.model.reload()
        }
    }

    /// ⌃Tab / ⌃⇧Tab: the next (previous) tab of the window, wrapping around.
    func selectNeighbourTab(of controller: ListerWindowController, forward: Bool) {
        let tabs = tabs(of: controller)
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === controller }) else { NSSound.beep(); return }
        select(tabs[(index + (forward ? 1 : tabs.count - 1)) % tabs.count])
    }

    /// Shows a tab and gives its list the keyboard.
    func select(_ tab: ListerWindowController) {
        guard let window = tab.window else { return }
        if let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        window.makeKeyAndOrderFront(nil)
        if let table = tab.listerViewController?.tableView { window.makeFirstResponder(table) }
        moveRoleToSelectedTab(in: tab)
    }

    /// The tab leaves its window and becomes a lister of its own, beside it.
    func moveTabToNewLister(_ controller: ListerWindowController) {
        let tabs = tabs(of: controller)
        guard tabs.count > 1, let window = controller.window else { controller.model.flash(tr("This lister has no other tabs")); return }
        let others = tabs.filter { $0 !== controller }
        window.moveTabToNewWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if let first = others.first { moveRoleToSelectedTab(in: first) }
        moveRoleToSelectedTab(in: controller)
    }

    /// Every lister window becomes a tab of the window of `controller`.
    func mergeAllListers(into controller: ListerWindowController) {
        guard Settings.listerTabs, let window = controller.window else {
            controller.model.flash(tr("Tabs are off: turn them on in Settings → Listers"))
            return
        }
        let roles = Set(controllers.map(\.model.role)).subtracting([.none])
        for other in controllers { other.window?.tabbingMode = .automatic }
        for other in controllers where other !== controller && !tabs(of: controller).contains(where: { $0 === other }) {
            if let otherWindow = other.window {
                if otherWindow.isMiniaturized { otherWindow.deminiaturize(nil) }
                window.addTabbedWindow(otherWindow, ordered: .above)
            }
        }
        select(controller)
        if roles.count > 1 {
            controller.model.flash(tr("One window has one role: only the tab you see keeps it"))
        }
    }

    /// Closes every other tab of the window.
    func closeOtherTabs(than controller: ListerWindowController) {
        for tab in tabs(of: controller) where tab !== controller { tab.close() }
    }

    /// The source / destination role belongs to the lister window, so only the tab you see holds it: when another tab
    /// is shown, the role (and its lock) goes along. You never copy into a folder you cannot see.
    func moveRoleToSelectedTab(in controller: ListerWindowController) {
        let tabs = tabs(of: controller)
        guard tabs.count > 1, let selected = tabs.first(where: isSelectedTab) else { return }
        for tab in tabs where tab !== selected && tab.model.role != .none {
            if selected.model.role == .none {
                selected.model.role = tab.model.role
                selected.model.roleLocked = tab.model.roleLocked
            }
            tab.model.role = .none
            tab.model.roleLocked = false
        }
    }

    /// Settings → Listers → Tabs: on, windows may take tabs; off, every tab becomes a lister window of its own again.
    func applyTabSetting() {
        if !Settings.listerTabs {
            for controller in controllers {
                let tabs = tabs(of: controller)
                guard tabs.count > 1, tabs.first !== controller else { continue }
                controller.window?.moveTabToNewWindow(nil)
            }
        }
        for controller in controllers { controller.window?.tabbingMode = Settings.listerTabs ? .automatic : .disallowed }
    }

    /// The listers in menu order: as they were opened, the tabs of one window together and in tab order.
    /// `isTab`: a later tab of a window whose first tab is listed just above.
    var menuOrder: [(controller: ListerWindowController, isTab: Bool)] {
        var done = Set<ObjectIdentifier>()
        var result: [(ListerWindowController, Bool)] = []
        for controller in controllers where !done.contains(ObjectIdentifier(controller)) {
            for (index, tab) in tabs(of: controller).enumerated() where !done.contains(ObjectIdentifier(tab)) {
                done.insert(ObjectIdentifier(tab))
                result.append((tab, index > 0))
            }
        }
        return result
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

    /// A new lister on `folder`, beside `original`, with its size, sort and hidden-files settings (not its filter).
    @discardableResult
    func openFolder(_ folder: URL, inNewListerFrom original: ListerWindowController) -> ListerWindowController {
        openLister(directory: folder, anchor: .cascade(from: original.window)) { copy in
            let model = original.model
            copy.model.apply(sort: model.sortKey, ascending: model.ascending, showHidden: model.showHidden, filter: "")
            if let size = original.window?.contentLayoutRect.size { copy.window?.setContentSize(size) }
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

/// `--quiet` (or MACLISTER_QUIET=1 in the environment): for running the self-tests while you work at the Mac. The app
/// never activates itself, so it never takes the keyboard, and every window it shows is fully transparent and lets
/// clicks through. The windows are still real windows: lists load, menus build, roles and tabs behave as usual.
enum QuietMode {
    static let isOn = CommandLine.arguments.contains("--quiet") || ProcessInfo.processInfo.environment["MACLISTER_QUIET"] == "1"
    private static var started = false

    static func start() {
        guard isOn, !started else { return }
        started = true
        // Every way of showing a window (makeKeyAndOrderFront, orderFront, sheets, panels) ends in order(_:relativeTo:) (-orderWindow:relativeTo:):
        // the window turns transparent just before it reaches the screen, so nothing flashes.
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:))),
           let quiet = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.quietOrderWindow(_:relativeTo:))) {
            method_exchangeImplementations(original, quiet)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            NSApp.windows.forEach(hide)                      // anything shown some other way
        }
        DebugLog.write("quiet mode: windows are transparent and the app does not activate")
    }

    static func hide(_ window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
    }
}

extension NSWindow {
    /// Swapped with order(_:relativeTo:) in quiet mode, so calling it runs the original.
    @objc fileprivate func quietOrderWindow(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        QuietMode.hide(self)
        quietOrderWindow(place, relativeTo: other)
    }
}

extension NSApplication {
    func bringToFront() {
        guard !QuietMode.isOn else { return }          // quiet mode: the person at the Mac keeps the keyboard
        // The flag is deprecated since macOS 14 but still honoured in practice; the cooperative
        // activate() alone is refused when another app (Finder after a desktop click) is active.
        activate(ignoringOtherApps: true)
    }
}
