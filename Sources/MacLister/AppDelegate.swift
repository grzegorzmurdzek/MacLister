import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = DesktopDoubleClickMonitor()
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?

    private var statusLine: NSMenuItem!
    private var newListerItem: NSMenuItem!
    private var settingsItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        QuietMode.start()              // `--quiet`: self-tests that do not get in the way (before any window exists)
        DispatchQueue.global(qos: .utility).async { RemoteCache.purge() }     // old downloaded copies
        DispatchQueue.global(qos: .utility).async { ArchiveBrowser.cleanOldCaches() }     // archives unpacked for browsing
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { _ in GlobalShortcutActions.apply() }
        GlobalShortcutActions.apply()
        LegacyMigration.run()          // before anything touches buttons.json or the defaults
        Settings.registerDefaults()
        // New listers are windows of their own even with "prefer tabs" set in System Settings; a tab comes only from ⌘T,
        // the tab bar's + button and the other tab commands (Settings → Tabs).
        NSWindow.allowsAutomaticWindowTabbing = false
        ButtonStore.shared.ensureConfigFileExists()
        installMainMenu()
        if Settings.showStatusItem { installStatusItem() }

        ListerManager.shared.onProgressChange = { [weak self] in self?.updateProgressIndicator() }
        monitor.onDesktopDoubleClick = { point in
            ListerManager.shared.openNew(
                directory: Settings.startDirectory,
                anchor: .cursor(point, centered: Settings.centerOnCursor)
            )
        }
        startMonitoringWhenTrusted()

        // `MacLister --reset-buttons` rewrites buttons.json with the defaults and quits (scripting aid).
        if CommandLine.arguments.contains("--reset-buttons") {
            ButtonStore.shared.resetToDefaults()
            NSApp.terminate(nil)
            return
        }
        // The test, screenshot and demo modes (any `--option`) start from listers without roles and set the roles
        // themselves; the automatic roles have their own test.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { ListerManager.autoRolesOverride = false }
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-remote") {
            let rest = Array(CommandLine.arguments.dropFirst(flag + 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestRemote.run(arguments: rest) }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-update"), CommandLine.arguments.indices.contains(flag + 1),
           let feed = URL(string: CommandLine.arguments[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestOperations.updateInstall(feed: feed) }
            return
        }
        if CommandLine.arguments.contains("--selftest-ops") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestOperations.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest-tabs") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestTabs.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest-dual") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestDual.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest-features") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestFeatures.run() }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-details"), CommandLine.arguments.indices.contains(flag + 1) {
            let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let dark = CommandLine.arguments.contains("dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreviewRender.transferDetails(to: out, dark: dark)
                NSApp.terminate(nil)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-lister"), CommandLine.arguments.indices.contains(flag + 1) {
            let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let dark = CommandLine.arguments.contains("dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreviewRender.lister(to: out, label: "NAS", color: "orange", dark: dark)
                NSApp.terminate(nil)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--screenshots"), CommandLine.arguments.indices.contains(flag + 1) {
            let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let dark = CommandLine.arguments.contains("dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Screenshots.run(outDir: out, dark: dark) }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--demo-video"), CommandLine.arguments.indices.contains(flag + 1) {
            let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let dark = CommandLine.arguments.contains("dark")
            if #available(macOS 15.0, *) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { DemoVideo.run(out: out, dark: dark) }
            } else {
                print("--demo-video needs macOS 15 or later")
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--check-recents") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreviewRender.recentsCheck()
            }
            return
        }
        if CommandLine.arguments.contains("--selftest-language") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestLanguage.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTest.run() }
            return
        }

        // Only a normal launch brings the saved listers back; the scripting and test modes above start clean.
        if Settings.restoreLayoutAtLaunch { LayoutStore.restore(into: ListerManager.shared) }

        // The Dock icon follows the setting, now and whenever it changes (the self-test modes above stay agents).
        applyDockIconPreference()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyDockIconPreference()
            ListerManager.shared.applyDesktopBehavior()
        }

        // Ask once about automatic update checks; check daily when the user agreed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { UpdateManager.shared.launchCheck() }

        // `MacLister --open [folder]` opens one lister at launch (handy for scripts and testing).
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--open") {
            let folder = args.indices.contains(flag + 1) ? URL(fileURLWithPath: args[flag + 1]) : Settings.startDirectory
            let center = NSPoint(x: (NSScreen.main?.frame.midX ?? 600), y: (NSScreen.main?.frame.midY ?? 400))
            ListerManager.shared.openLister(directory: folder, anchor: .cursor(center, centered: true))
        }
    }

    /// Closing the last lister must not quit the agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Dock icon

    /// Shows or hides the Dock icon. A hidden one makes MacLister an agent again (menu-bar icon only).
    func applyDockIconPreference() {
        let wanted: NSApplication.ActivationPolicy = Settings.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            let done = NSApp.setActivationPolicy(wanted)
            if Settings.debugHitTest { DebugLog.write("dock icon \(wanted == .regular ? "shown" : "hidden"): \(done)") }
        }
    }

    /// Where a lister opened from the Dock or the File menu appears: beside the frontmost one, else centred on the screen.
    /// `size`: of the window that opens (a lister, or a two-panel window).
    func dockAnchor(size: NSSize = Settings.listerContentSize) -> ListerManager.Anchor {
        if let front = ListerManager.shared.frontmost, let window = front.window { return .cascade(from: window) }
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return .origin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    /// Clicking the Dock icon: bring the listers back, or open one when there is none.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ListerManager.shared.openCount == 0 {
            ListerManager.shared.openNew(directory: Settings.startDirectory, anchor: dockAnchor(size: ListerManager.newWindowSize))
        } else {
            ListerManager.shared.bringAllToFront()
        }
        return false
    }

    /// `maclister://open?path=…`, which the Dock apps made by "Add to Dock" send.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFolder(from: url) }
    }

    /// Raises the lister that already shows the folder, or opens one; says so when the folder is gone.
    @discardableResult
    func openFolder(from url: URL) -> Bool {
        guard let folder = DockShortcut.folder(from: url) else { return false }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            let alert = NSAlert()
            alert.messageText = tr("Folder not found")
            alert.informativeText = tr("“%@” does not exist any more, or is not a folder.", (folder.path as NSString).abbreviatingWithTildeInPath)
            NSApp.bringToFront()
            alert.runModal()
            return true
        }
        let manager = ListerManager.shared
        let key = ListerModel.comparisonKey(folder)
        if let existing = manager.allControllers.first(where: { ListerModel.comparisonKey($0.model.url) == key }) {
            manager.bringToFront(existing)
        } else {
            manager.openLister(directory: folder, anchor: dockAnchor())
            NSApp.bringToFront()
        }
        return true
    }

    /// The menu under a right-click on the Dock icon: the open listers, then the common commands.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeDockMenu() }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        let controllers = ListerManager.shared.allControllers
        if controllers.isEmpty {
            let none = menu.addItem(withTitle: tr("No open listers"), action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        for item in listerMenuItems() { menu.addItem(item) }
        menu.addItem(.separator())
        add(tr("New Lister"), #selector(newListerFromDock))
        add(tr("New Two-Panel Window"), #selector(newTwoPanelFromDock))
        add(tr("Duplicate Frontmost Lister"), #selector(duplicateFrontmost), enabled: !controllers.isEmpty)
        add(tr("Connect to Server…"), #selector(connectFromMenu))
        if controllers.count > 1 {
            menu.addItem(.separator())
            add(tr("Bring All to Front"), #selector(bringAllListers))
            add(tr("Close All Listers"), #selector(closeAllListers))
        }
        if !controllers.isEmpty { add(tr("Move All Listers to This Desktop"), #selector(gatherListers)) }
        menu.addItem(.separator())
        add(OperationLog.shared.undoMenuTitle, #selector(undoFromMenu), enabled: OperationLog.shared.lastUndoable != nil)
        add(tr("Operation Log…"), #selector(showOperationLog))
        add(tr("Settings…"), #selector(showSettings))
        add(tr("About MacLister"), #selector(showAbout))
        return menu
    }

    @objc private func newListerFromDock() {
        ListerManager.shared.openLister(directory: Settings.startDirectory, anchor: dockAnchor())
    }

    @objc private func newTwoPanelFromDock() {
        ListerManager.shared.openDual(left: Settings.startDirectory, anchor: dockAnchor(size: Settings.dualContentSize))
    }

    // MARK: - Accessibility gate

    private func startMonitoringWhenTrusted() {
        if Accessibility.isTrusted(prompt: true) {
            monitor.start()
            return
        }
        // Trust is granted in System Settings while we run; poll until it appears.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, Accessibility.isTrusted(prompt: false) else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.monitor.start()
        }
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()

        let menu = NSMenu()
        menu.delegate = self

        let about = menu.addItem(withTitle: tr("About MacLister"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let versionLine = menu.addItem(withTitle: tr("Version %@", AboutInfo.versionText), action: nil, keyEquivalent: "")
        versionLine.isEnabled = false
        menu.addItem(.separator())

        let newLister = menu.addItem(withTitle: tr("New Lister"), action: #selector(newLister), keyEquivalent: "")
        newLister.target = self
        newListerItem = newLister
        let newTwoPanel = menu.addItem(withTitle: tr("New Two-Panel Window"), action: #selector(newTwoPanel), keyEquivalent: "")
        newTwoPanel.target = self
        menu.addItem(.separator())

        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        settingsItem = menu.addItem(withTitle: tr("Open Accessibility Settings…"), action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())

        let connect = menu.addItem(withTitle: tr("Connect to Server…"), action: #selector(connectFromMenu), keyEquivalent: "k")
        connect.target = self
        let duplicate = menu.addItem(withTitle: tr("Duplicate Frontmost Lister"), action: #selector(duplicateFrontmost), keyEquivalent: "")
        duplicate.target = self
        let save = menu.addItem(withTitle: tr("Save Layout"), action: #selector(saveLayout), keyEquivalent: "")
        save.target = self
        let restore = menu.addItem(withTitle: tr("Restore Layout"), action: #selector(restoreLayout), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        undoItem = menu.addItem(withTitle: tr("Undo"), action: #selector(undoFromMenu), keyEquivalent: "")
        undoItem.target = self
        let log = menu.addItem(withTitle: tr("Operation Log…"), action: #selector(showOperationLog), keyEquivalent: "")
        log.target = self
        menu.addItem(.separator())
        let update = menu.addItem(withTitle: tr("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        let preferences = menu.addItem(withTitle: tr("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit MacLister"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    // MARK: - List of open listers (top of the menu-bar menu)

    private let listerItemTag = 100

    /// Titles of the dynamic lister entries; the self-test reads them.
    func listerMenuTitles() -> [String] { ListerManager.shared.menuOrder.map(\.controller.menuTitle) }

    /// Opens the status menu programmatically and returns its item titles (self-test).
    func statusMenuTitles() -> [String] {
        guard let menu = statusItem?.menu else { return [] }
        menuWillOpen(menu)
        return menu.items.map(\.title)
    }

    private func rebuildListerItems(in menu: NSMenu) {
        for item in menu.items where item.tag == listerItemTag { menu.removeItem(item) }
        guard let anchor = menu.items.firstIndex(where: { $0.action == #selector(newTwoPanel) }) else { return }
        var index = anchor + 1
        func insert(_ item: NSMenuItem) {
            item.tag = listerItemTag
            menu.insertItem(item, at: index)
            index += 1
        }

        insert(.separator())
        let controllers = ListerManager.shared.allControllers
        if controllers.isEmpty {
            let none = NSMenuItem(title: tr("No open listers"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            insert(none)
            return
        }
        for item in listerMenuItems() { insert(item) }
        if controllers.count > 1 {
            insert(.separator())
            let all = NSMenuItem(title: tr("Bring All to Front"), action: #selector(bringAllListers), keyEquivalent: "")
            all.target = self
            insert(all)
            let close = NSMenuItem(title: tr("Close All Listers"), action: #selector(closeAllListers), keyEquivalent: "")
            close.target = self
            insert(close)
        }
        let gather = NSMenuItem(title: tr("Move All Listers to This Desktop"), action: #selector(gatherListers), keyEquivalent: "")
        gather.target = self
        insert(gather)
    }

    /// One item per open lister (click: bring it to the front), shared by the menu-bar and the Dock menus.
    /// The tabs of one window are listed together; the later ones are indented under the first.
    private func listerMenuItems() -> [NSMenuItem] {
        ListerManager.shared.menuOrder.map { controller, isTab in
            let item = NSMenuItem(title: controller.menuTitle, action: #selector(focusLister(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.toolTip = controller.model.url.path
            item.indentationLevel = isTab ? 1 : 0
            let shown = controller.dualHost.map { $0.activePane === controller } ?? true    // the pane you work in
            item.state = controller.window?.isKeyWindow == true && shown ? .on : .off
            if let icon = NSWorkspace.shared.icon(forFile: controller.model.url.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            return item
        }
    }

    @objc private func focusLister(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? ListerWindowController else { return }
        ListerManager.shared.bringToFront(controller)
    }

    @objc private func bringAllListers() { ListerManager.shared.bringAllToFront() }

    @objc private func closeAllListers() { ListerManager.shared.closeAll() }

    @objc private func gatherListers() { ListerManager.shared.gatherOnThisDesktop() }

    // MARK: - Terminal app used by "Terminal Here"

    private static let knownTerminals: [(name: String, id: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("Hyper", "co.zeit.hyper"),
    ]

    /// Terminal apps that are installed (checked live, so a newly installed one shows up).
    static func terminalChoices() -> [(name: String, id: String)] {
        knownTerminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    func terminalChoices() -> [(name: String, id: String)] { Self.terminalChoices() }

    // MARK: - Text editor used by "New Text File"

    private static let knownEditors: [(name: String, id: String)] = [
        ("TextEdit", "com.apple.TextEdit"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("BBEdit", "com.barebones.bbedit"),
        ("CotEditor", "com.coteditor.CotEditor"),
        ("Nova", "com.panic.Nova"),
        ("Zed", "dev.zed.Zed"),
        ("TextMate", "com.macromates.TextMate"),
        ("MacVim", "org.vim.MacVim"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    /// Text editors that are installed (checked live).
    static func editorChoices() -> [(name: String, id: String)] {
        knownEditors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    func chooseTerminal(id: String) { Settings.terminalBundleID = id }

    /// The language is read when the app starts, so a change asks for a restart.
    static func switchLanguage(_ language: AppLanguage) {
        guard language != AppLanguage.current else { return }
        language.apply()
        let alert = NSAlert()
        alert.messageText = tr("Restart MacLister to change the language")
        alert.informativeText = tr("Open listers will be closed. Your layout can be restored with Restore Layout.")
        alert.addButton(withTitle: tr("Restart Now"))
        alert.addButton(withTitle: tr("Later"))
        NSApp.bringToFront()
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// Starts a fresh copy of the app a moment after this one has quit.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", path]
        try? helper.run()
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildListerItems(in: menu)
        switch monitor.mode {
        case .eventTap:      statusLine.title = tr("Desktop double-click: active")
        case .globalMonitor: statusLine.title = tr("Desktop double-click: active (fallback monitor)")
        case .stopped:       statusLine.title = tr("Waiting for Accessibility permission…")
        }
        settingsItem.isHidden = monitor.mode != .stopped
        showAssignedShortcut(on: newListerItem, for: GlobalShortcutActions.openLister)
        undoItem?.title = OperationLog.shared.undoMenuTitle
        undoItem?.isEnabled = OperationLog.shared.lastUndoable != nil
    }

    @objc private func newLister() {
        let point = NSEvent.mouseLocation
        ListerManager.shared.openLister(directory: Settings.startDirectory, anchor: .cursor(point, centered: true))
    }

    @objc private func newTwoPanel() {
        ListerManager.shared.openDual(left: Settings.startDirectory, anchor: .cursor(NSEvent.mouseLocation, centered: true))
    }

    @objc private func openAccessibilitySettings() { Accessibility.openSystemSettings() }

    /// Shows the shortcut the user assigned to an action next to its menu item (none assigned: none shown).
    /// Only keys that are a single character can be shown by a menu item.
    func showAssignedShortcut(on item: NSMenuItem?, for id: String) {
        guard let item else { return }
        if let combo = ShortcutStore.shared.combo(for: id), combo.label.count == 1 {
            item.keyEquivalent = combo.label.lowercased()
            item.keyEquivalentModifierMask = combo.flags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    @objc private func showSettings() { SettingsWindow.show() }

    private var undoItem: NSMenuItem!

    @objc private func undoFromMenu() {
        OperationLog.shared.undoLast { outcome in
            guard let outcome else { return }
            ListerManager.shared.reloadListers(showing: outcome.folders)
            if !outcome.failures.isEmpty { ListerManager.shared.frontmost?.model.errorMessage = outcome.failures.joined(separator: "; ") }
        }
    }
    @objc private func showOperationLog() { OperationLogWindow.show() }
    @objc func showAbout() { AboutWindow.show() }

    @objc private func checkForUpdates() { UpdateManager.shared.check(userInitiated: true) }

    /// While anything copies, moves, downloads or deletes, the menu-bar icon becomes a progress ring with a
    /// percentage; its tooltip says what is going on.
    private func updateProgressIndicator() {
        guard let button = statusItem?.button else { return }
        if let summary = ProgressSummary.make(from: ListerManager.shared.activeProgress) {
            button.image = MenuBarIcon.progress(fraction: summary.fraction)
            button.title = summary.fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            button.imagePosition = .imageLeading
            button.toolTip = summary.text
        } else {
            button.image = MenuBarIcon.make()
            button.title = ""
            button.toolTip = nil
        }
    }

    /// Test hook.
    var statusItemTitle: String { statusItem?.button?.title ?? "" }
    var statusItemToolTip: String? { statusItem?.button?.toolTip }

    @objc private func connectFromMenu() {
        let manager = ListerManager.shared
        if let controller = manager.frontmost {
            manager.bringToFront(controller)
            controller.listerViewController?.connectToServer()
        } else {
            let controller = manager.openLister(directory: Settings.startDirectory, anchor: .cursor(NSEvent.mouseLocation, centered: true))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.listerViewController?.connectToServer() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RemoteSessions.shared.closeAll()
    }

    @objc private func duplicateFrontmost() {
        if let controller = ListerManager.shared.frontmost { ListerManager.shared.duplicate(controller) }
    }

    @objc private func saveLayout() { LayoutStore.save(from: ListerManager.shared) }

    @objc private func restoreLayout() { LayoutStore.restore(into: ListerManager.shared) }

    // MARK: - Main menu (an agent app shows no menu bar, but key equivalents still need one)

    private func installMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: tr("About MacLister"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: tr("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Quit MacLister"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        main.addItem(fileMenuItem)
        let file = NSMenu(title: tr("File"))
        let newItem = file.addItem(withTitle: tr("New Lister"), action: #selector(newListerFromDock), keyEquivalent: "n")
        newItem.target = self
        let twoPanelItem = file.addItem(withTitle: tr("New Two-Panel Window"), action: #selector(newTwoPanelFromDock), keyEquivalent: "n")
        twoPanelItem.keyEquivalentModifierMask = [.command, .option]
        twoPanelItem.target = self
        fileMenuItem.submenu = file

        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = edit

        let windowMenuItem = NSMenuItem()
        main.addItem(windowMenuItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: tr("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: tr("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let front = window.addItem(withTitle: tr("Bring All to Front"), action: #selector(bringAllListers), keyEquivalent: "")
        front.target = self
        windowMenuItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
        // Lets the Services submenu of the file context menu offer services that take files.
        NSApp.registerServicesMenuSendTypes(FinderServices.sendTypes, returnTypes: [])
    }
}
