import AppKit

/// A two-panel window, for those who like a classic two-panel file manager (Norton Commander, Total Commander):
/// two listers side by side in one window. Each pane is a full lister (a `ListerWindowController` without a window of
/// its own), so everything a lister does works in a pane. The pane you work in is the source and the other one the
/// destination, so F5 / F6 copy and move to the other side; Tab moves the keyboard to the other pane; closing the
/// window closes both panes.
final class DualListerWindowController: NSWindowController, NSWindowDelegate {
    /// Left, right.
    private(set) var panes: [ListerWindowController] = []
    /// The pane you work in: it has the keyboard and gives the window its title.
    private(set) weak var activePane: ListerWindowController?
    private let split = NSSplitViewController()
    /// While the window is being put together the panes take the keyboard one after the other; that is not the user.
    private var isSettingUp = true
    private var isClosed = false
    /// Set while the window closes because its panes go on as listers of their own (Split into Two Listers).
    private var isSplitting = false

    /// `left` / `right`: new listers, or the models of listers joined into the window.
    init(left: ListerModel, right: ListerModel) {
        let size = Settings.dualContentSize
        let window = ListerWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false      // lifetime is owned by ListerManager
        window.collectionBehavior = ListerManager.desktopBehavior
        window.minSize = NSSize(width: Settings.minListerSize.width * 2, height: Settings.minListerSize.height)
        window.tabbingMode = .disallowed         // the two panes are the window; it takes no tabs
        super.init(window: window)
        window.delegate = self

        panes = [ListerWindowController(model: left, paneOf: self), ListerWindowController(model: right, paneOf: self)]
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        for pane in panes {
            guard let content = pane.listerViewController else { continue }
            let item = NSSplitViewItem(viewController: content)
            item.minimumThickness = Settings.minListerSize.width
            split.addSplitViewItem(item)
        }
        window.contentViewController = split
        window.setContentSize(size)
        window.titleBarMenuProvider = { [weak self] in self?.activePane?.listerViewController?.makeTitleBarMenu() }
        window.onFirstResponderChange = { [weak self] in self?.followKeyboard() }
        activePane = panes[0]
        panes[0].updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var leftPane: ListerWindowController { panes[0] }
    var rightPane: ListerWindowController { panes[1] }

    func otherPane(of pane: ListerWindowController) -> ListerWindowController? {
        guard panes.contains(where: { $0 === pane }) else { return nil }
        return panes.first { $0 !== pane }
    }

    /// The pane that holds `responder`: its list, path field, folder tree…
    private func pane(holding responder: NSResponder?) -> ListerWindowController? {
        guard let view = responder as? NSView else { return nil }
        return panes.first { pane in pane.listerViewController.map { view.isDescendant(of: $0.view) } ?? false }
    }

    /// The keyboard went to the other pane (a click in it, Tab…): that pane is now the one you work in.
    private func followKeyboard() {
        guard !isSettingUp, !isClosed, let pane = pane(holding: window?.firstResponder), pane !== activePane else { return }
        activate(pane, takeDestination: false)
    }

    /// `pane` becomes the pane you work in: the source, the other one the destination (see ListerManager.claimRoles).
    func activate(_ pane: ListerWindowController, takeDestination: Bool) {
        guard let other = otherPane(of: pane) else { return }
        activePane = pane
        let manager = ListerManager.shared
        manager.paneDidBecomeActive(pane)
        manager.claimRoles(active: pane, other: other, takeDestination: takeDestination)
        pane.updateTitle()
    }

    /// Gives a pane the keyboard (its file list).
    func focus(_ pane: ListerWindowController) {
        guard let table = pane.listerViewController?.listView else { return }
        window?.makeFirstResponder(table)
        if activePane !== pane { activate(pane, takeDestination: false) }
    }

    /// Both panes as wide as each other.
    func splitEvenly() {
        let splitView = split.splitView
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) / 2, ofDividerAt: 0)
    }

    /// The window is on screen: `active` (else the left pane) gets the keyboard and the window takes the roles.
    func finishSetUp(active: ListerWindowController? = nil) {
        isSettingUp = false
        let pane = active ?? leftPane
        focus(pane)
        activate(pane, takeDestination: true)
    }

    /// Where each pane is on screen (left, right): the frames its lister gets when the window is split.
    var paneFramesOnScreen: [NSRect] {
        guard let window else { return [] }
        return panes.compactMap { pane in
            pane.listerViewController.map { window.convertToScreen($0.view.convert($0.view.bounds, to: nil)) }
        }
    }

    /// Closes the window for Split into Two Listers: the panes go on as listers, so nothing about them is closed.
    fileprivate func closeForSplit() {
        isSplitting = true
        close()
    }

    override func close() {
        guard !isClosed else { return }        // both panes ask when all listers close
        super.close()
    }

    /// Coming back to the window: the pane you worked in is the source again.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !isSettingUp, !isClosed, let pane = activePane ?? panes.first else { return }
        activate(pane, takeDestination: false)
    }

    /// New two-panel windows start with the size the user last chose.
    func windowDidEndLiveResize(_ notification: Notification) {
        if let size = window?.contentLayoutRect.size { Settings.dualContentSize = size }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        ListerManager.shared.removeDual(self, fillRoles: !isSplitting)
    }
}

extension ListerManager {
    /// Opens a two-panel window: `left` in the left pane, `right` (else `left` too) in the right one.
    /// `configure` runs before the window is positioned and shown.
    @discardableResult
    func openDual(left: URL, right: URL? = nil, anchor: Anchor,
                  configure: ((DualListerWindowController) -> Void)? = nil) -> DualListerWindowController {
        openDual(DualListerWindowController(left: ListerModel(url: left), right: ListerModel(url: right ?? left)),
                 anchor: anchor, configure: configure)
    }

    @discardableResult
    private func openDual(_ dual: DualListerWindowController, anchor: Anchor, active: ListerWindowController? = nil,
                          configure: ((DualListerWindowController) -> Void)? = nil) -> DualListerWindowController {
        dualWindows.append(dual)
        for pane in dual.panes { register(pane) }
        configure?(dual)
        if let window = dual.window {
            window.setFrameOrigin(origin(for: window.frame.size, anchor: anchor))
            // shown the same way as a lister (see openLister): above the app that is active, with the keyboard when allowed
            dual.showWindow(nil)
            raise(window)
            NSApp.bringToFront()
            window.makeKeyAndOrderFront(nil)
        }
        dual.splitEvenly()
        dual.finishSetUp(active: active)
        return dual
    }

    // MARK: Joining and splitting

    /// The lister that Join into Two-Panel Window puts beside `controller`: its partner in Copy / Move (the destination
    /// of the source, the source of the destination), else the destination, the source, or the lister opened last.
    /// Only listers of their own (not panes) that are shown (a tab: the one you see) take part.
    func joinPartner(for controller: ListerWindowController) -> ListerWindowController? {
        joinCandidates(for: controller).first
    }

    /// The listers `controller` can be joined with, for the Join With menu: the usual partner first (see joinPartner),
    /// then the rest in the order they were opened.
    func joinCandidates(for controller: ListerWindowController) -> [ListerWindowController] {
        guard !controller.isPane else { return [] }
        let others = allControllers.filter { $0 !== controller && !$0.isPane && isSelectedTab($0) }
        guard let partner = usualPartner(for: controller, among: others) else { return [] }
        return [partner] + others.filter { $0 !== partner }
    }

    private func usualPartner(for controller: ListerWindowController, among others: [ListerWindowController]) -> ListerWindowController? {
        func among(_ lister: ListerWindowController?) -> ListerWindowController? {
            lister.flatMap { lister in others.contains { $0 === lister } ? lister : nil }
        }
        switch controller.model.role {
        case .source:      if let partner = among(destinationController) { return partner }
        case .destination: if let partner = among(sourceController) { return partner }
        case .none:        break
        }
        return among(destinationController) ?? among(sourceController) ?? others.last
    }

    /// Join into Two-Panel Window: `controller` and its partner (see joinPartner) become the two panes of one window,
    /// each with its folder, history, filter, name and role; the one further left on screen is the left pane. The
    /// window covers both listers. `controller` is the pane you work in.
    /// `partner`: the lister chosen in the Join With menu; nil: the usual partner.
    @discardableResult
    func joinIntoTwoPanel(_ controller: ListerWindowController, with chosen: ListerWindowController? = nil) -> DualListerWindowController? {
        guard let partner = chosen.flatMap({ chosen in joinCandidates(for: controller).first { $0 === chosen } })
                ?? joinPartner(for: controller) else {
            controller.model.flash(controller.isPane ? tr("This lister is already a pane of a two-panel window")
                                                     : tr("Open another lister to join this one with"))
            return nil
        }
        let frames = [controller, partner].map { $0.window?.frame ?? .zero }
        let (left, right) = frames[0].minX <= frames[1].minX ? (controller, partner) : (partner, controller)
        let leftFrame = left.window?.frame ?? frames[0], rightFrame = right.window?.frame ?? frames[1]
        let screen = left.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minimum = NSSize(width: Settings.minListerSize.width * 2, height: Settings.minListerSize.height)
        let width = min(visible.width, max(minimum.width, leftFrame.width + rightFrame.width))
        let height = min(visible.height, max(minimum.height, leftFrame.height, rightFrame.height))
        let frame = NSRect(x: leftFrame.minX, y: leftFrame.maxY - height, width: width, height: height)
        // the listers leave their windows; their models go into the panes
        for lister in [left, right] { lister.retire() }
        let dual = DualListerWindowController(left: left.model, right: right.model)
        let active = controller === left ? dual.leftPane : dual.rightPane
        return openDual(dual, anchor: .origin(frame.origin), active: active) { dual in
            dual.window?.setFrame(frame, display: false)
        }
    }

    /// Expand into Two-Panel Window: this lister turns into the left pane of a two-panel window and gets a right pane
    /// that opens in the same folder. The window grows to the right (about 80 % wider; it moves left to stay on the
    /// screen), so the lister stays where it was. Returns nil for a pane, which is in a two-panel window already.
    @discardableResult
    func expandToTwoPanel(_ controller: ListerWindowController) -> DualListerWindowController? {
        guard !controller.isPane, let window = controller.window else {
            controller.model.flash(tr("This lister is already a pane of a two-panel window"))
            return nil
        }
        let old = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minimum = NSSize(width: Settings.minListerSize.width * 2, height: Settings.minListerSize.height)
        let width = min(visible.width, max(minimum.width, (old.width * 1.8).rounded()))
        let height = min(visible.height, max(minimum.height, old.height))
        let x = max(visible.minX, min(old.minX, visible.maxX - width))
        let frame = NSRect(x: x, y: old.maxY - height, width: width, height: height)
        let right = ListerModel(url: controller.model.url)
        controller.retire()
        let dual = DualListerWindowController(left: controller.model, right: right)
        return openDual(dual, anchor: .origin(frame.origin), active: dual.leftPane) { dual in
            dual.window?.setFrame(frame, display: false)
        }
    }

    /// Split into Two Listers: each pane becomes a lister window of its own where the pane was, with its folder,
    /// history, filter, name and role. Returns the two listers (left, right).
    @discardableResult
    func splitTwoPanel(_ dual: DualListerWindowController) -> [ListerWindowController] {
        let frames = dual.paneFramesOnScreen
        let active = dual.activePane
        let models = dual.panes.map(\.model)
        dual.closeForSplit()
        var listers: [ListerWindowController] = []
        for (index, model) in models.enumerated() {
            let lister = ListerWindowController(model: model)
            register(lister)
            if let window = lister.window {
                // the pane's area becomes the new window's content, so the lister stays where it was
                if frames.indices.contains(index) { window.setFrame(window.frameRect(forContentRect: frames[index]), display: false) }
                lister.showWindow(nil)
                raise(window)
            }
            listers.append(lister)
        }
        let key = listers[active === dual.rightPane ? 1 : 0]
        key.window?.makeKeyAndOrderFront(nil)
        if let table = key.listerViewController?.listView { key.window?.makeFirstResponder(table) }
        return listers
    }

    /// Collapse to Single Lister: closes the other pane and keeps the SRC pane (else active, else left) as a single
    /// lister window where that pane was.
    @discardableResult
    func collapseToSinglePanel(_ dual: DualListerWindowController) -> ListerWindowController {
        let frames = dual.paneFramesOnScreen
        let keptIndex = dual.panes.firstIndex { $0.model.role == .source }
            ?? dual.activePane.flatMap { active in dual.panes.firstIndex { $0 === active } }
            ?? 0
        let keptModel = dual.panes[keptIndex].model
        let droppedRole = dual.panes.enumerated().contains { $0.offset != keptIndex && $0.element.model.role != .none }
        dual.closeForSplit()
        let lister = ListerWindowController(model: keptModel)
        register(lister)
        if let window = lister.window {
            if frames.indices.contains(keptIndex) { window.setFrame(window.frameRect(forContentRect: frames[keptIndex]), display: false) }
            lister.showWindow(nil)
            raise(window)
            NSApp.bringToFront()
            window.makeKeyAndOrderFront(nil)
            if let table = lister.listerViewController?.listView { window.makeFirstResponder(table) }
        }
        if droppedRole { fillRolesAfterClose() }
        return lister
    }

    /// What a desktop click, the global Open a lister shortcut and the Dock icon open: a lister, or a two-panel
    /// window (Settings → Listers → Two-panel window). Returns the lister, or the left pane.
    @discardableResult
    func openNew(directory: URL, anchor: Anchor) -> ListerWindowController {
        switch Settings.newWindowStyle {
        case .lister:   return openLister(directory: directory, anchor: anchor)
        case .twoPanel: return openDual(left: directory, anchor: anchor).leftPane
        }
    }

    /// The size a new window of that style gets, for placing it before it exists.
    static var newWindowSize: NSSize {
        Settings.newWindowStyle == .twoPanel ? Settings.dualContentSize : Settings.listerContentSize
    }

    /// The roles of a two-panel window: the pane you work in is the source, the other one the destination, as in a
    /// classic two-panel file manager. A locked role is never taken, and a locked pane keeps the roles where they are.
    /// `takeDestination`: the other pane takes the destination from any lister (a new window). Otherwise only when no
    /// lister outside this window has it: a lister you made the destination keeps it, so you can copy from a pane to it.
    func claimRoles(active: ListerWindowController, other: ListerWindowController, takeDestination: Bool) {
        guard !active.model.roleLocked, !other.model.roleLocked else { return }
        let all = allControllers
        func holder(_ role: ListerRole) -> ListerWindowController? { all.first { $0.model.role == role } }
        if active.model.role != .source, holder(.source)?.model.roleLocked != true {
            for lister in all where lister.model.role == .source { lister.model.role = .none }
            active.model.role = .source
        }
        let destination = holder(.destination)
        let elsewhere = destination.map { $0 !== active && $0 !== other } ?? false
        if other.model.role != .destination, destination?.model.roleLocked != true, takeDestination || !elsewhere {
            for lister in all where lister.model.role == .destination { lister.model.role = .none }
            other.model.role = .destination
        }
    }

    /// A two-panel window closed: both panes go, and the roles they held are filled again (`fillRoles`; not when the
    /// panes go on as listers).
    func removeDual(_ dual: DualListerWindowController, fillRoles: Bool = true) {
        let heldRole = fillRoles && dual.panes.contains { $0.model.role != .none }
        for pane in dual.panes { remove(pane) }
        dualWindows.removeAll { $0 === dual }
        DispatchQueue.main.async { withExtendedLifetime(dual) {} }    // alive until AppKit is done closing its window
        if heldRole { fillRolesAfterClose() }
    }
}
