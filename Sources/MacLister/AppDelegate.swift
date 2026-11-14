import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = DesktopDoubleClickMonitor()
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?

    private var statusLine: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var centerItem: NSMenuItem!
    private var labelsItem: NSMenuItem!
    private let buttonBarMenu = NSMenu(title: "Button Bar")
    private let triggerMenu = NSMenu(title: "Open Lister With")
    private let terminalMenu = NSMenu(title: "Terminal App")
    private let languageMenu = NSMenu(title: "Language")

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { RemoteCache.purge() }     // old downloaded copies
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { _ in GlobalShortcutActions.apply() }
        GlobalShortcutActions.apply()
        LegacyMigration.run()          // before anything touches buttons.json or the defaults
        Settings.registerDefaults()
        ButtonStore.shared.ensureConfigFileExists()
        installMainMenu()
        if Settings.showStatusItem { installStatusItem() }

        ListerManager.shared.onProgressChange = { [weak self] in self?.updateProgressIndicator() }
        monitor.onDesktopDoubleClick = { point in
            ListerManager.shared.openLister(
                directory: Settings.startDirectory,
                anchor: .cursor(point, centered: Settings.centerOnCursor)
            )
        }
        startMonitoringWhenTrusted()
        if Settings.restoreLayoutAtLaunch { LayoutStore.restore(into: ListerManager.shared) }

        // `MacLister --reset-buttons` rewrites buttons.json with the defaults and quits (scripting aid).
        if CommandLine.arguments.contains("--reset-buttons") {
            ButtonStore.shared.resetToDefaults()
            NSApp.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-remote") {
            let rest = Array(CommandLine.arguments.dropFirst(flag + 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestRemote.run(arguments: rest) }
            return
        }
        if CommandLine.arguments.contains("--selftest-ops") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestOperations.run() }
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

        let newLister = menu.addItem(withTitle: tr("New Lister"), action: #selector(newLister), keyEquivalent: "n")
        newLister.target = self
        menu.addItem(.separator())

        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        settingsItem = menu.addItem(withTitle: tr("Open Accessibility Settings…"), action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())

        centerItem = menu.addItem(withTitle: tr("Center Lister on Cursor"), action: #selector(toggleCenter), keyEquivalent: "")
        centerItem.target = self
        labelsItem = menu.addItem(withTitle: tr("Show Button Labels"), action: #selector(toggleButtonLabels), keyEquivalent: "")
        labelsItem.target = self
        let triggerItem = menu.addItem(withTitle: tr("Open Lister With"), action: nil, keyEquivalent: "")
        triggerItem.submenu = triggerMenu
        for trigger in DesktopTrigger.allCases {
            let item = triggerMenu.addItem(withTitle: trigger.menuTitle, action: #selector(chooseTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = trigger.rawValue
        }
        let buttonBarItem = menu.addItem(withTitle: tr("Button Bar"), action: nil, keyEquivalent: "")
        buttonBarItem.submenu = buttonBarMenu
        for position in ButtonBarPosition.allCases {
            let item = buttonBarMenu.addItem(withTitle: position.menuTitle, action: #selector(chooseButtonBarPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
        }
        let terminalItem = menu.addItem(withTitle: tr("Terminal App"), action: nil, keyEquivalent: "")
        terminalItem.submenu = terminalMenu
        let languageItem = menu.addItem(withTitle: tr("Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        for language in AppLanguage.allCases {
            let item = languageMenu.addItem(withTitle: language.menuTitle, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
        }
        let shortcuts = menu.addItem(withTitle: tr("Keyboard Shortcuts…"), action: #selector(showShortcuts), keyEquivalent: "")
        shortcuts.target = self
        let connect = menu.addItem(withTitle: tr("Connect to Server…"), action: #selector(connectFromMenu), keyEquivalent: "k")
        connect.target = self
        let duplicate = menu.addItem(withTitle: tr("Duplicate Frontmost Lister"), action: #selector(duplicateFrontmost), keyEquivalent: "")
        duplicate.target = self
        let save = menu.addItem(withTitle: tr("Save Layout"), action: #selector(saveLayout), keyEquivalent: "")
        save.target = self
        let restore = menu.addItem(withTitle: tr("Restore Layout"), action: #selector(restoreLayout), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        let filetypes = menu.addItem(withTitle: tr("Edit Filetypes…"), action: #selector(editFiletypes), keyEquivalent: "")
        filetypes.target = self
        let edit = menu.addItem(withTitle: tr("Edit Buttons…"), action: #selector(editButtons), keyEquivalent: "")
        edit.target = self
        let titleItem = menu.addItem(withTitle: tr("Lister Title…"), action: #selector(editTitleFormat), keyEquivalent: "")
        titleItem.target = self
        let reload = menu.addItem(withTitle: tr("Reload Buttons"), action: #selector(reloadButtons), keyEquivalent: "")
        reload.target = self
        let reset = menu.addItem(withTitle: tr("Reset Buttons to Defaults"), action: #selector(resetButtons), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        undoItem = menu.addItem(withTitle: tr("Undo"), action: #selector(undoFromMenu), keyEquivalent: "")
        undoItem.target = self
        let log = menu.addItem(withTitle: tr("Operation Log…"), action: #selector(showOperationLog), keyEquivalent: "")
        log.target = self
        dragSelectItem = menu.addItem(withTitle: tr("Drag-Select from File Names"), action: #selector(toggleDragSelect), keyEquivalent: "")
        dragSelectItem.target = self
        menu.addItem(.separator())
        let update = menu.addItem(withTitle: tr("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        autoUpdateItem = menu.addItem(withTitle: tr("Check for Updates Automatically"), action: #selector(toggleAutoUpdate), keyEquivalent: "")
        autoUpdateItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit MacLister"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    // MARK: - List of open listers (top of the menu-bar menu)

    private let listerItemTag = 100

    /// Titles of the dynamic lister entries; the self-test reads them.
    func listerMenuTitles() -> [String] { ListerManager.shared.allControllers.map(\.menuTitle) }

    /// Opens the status menu programmatically and returns its item titles (self-test).
    func statusMenuTitles() -> [String] {
        guard let menu = statusItem?.menu else { return [] }
        menuWillOpen(menu)
        return menu.items.map(\.title)
    }

    private func rebuildListerItems(in menu: NSMenu) {
        for item in menu.items where item.tag == listerItemTag { menu.removeItem(item) }
        guard let anchor = menu.items.firstIndex(where: { $0.action == #selector(newLister) }) else { return }
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
        for controller in controllers {
            let item = NSMenuItem(title: controller.menuTitle, action: #selector(focusLister(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.toolTip = controller.model.url.path
            item.state = controller.window?.isKeyWindow == true ? .on : .off
            if let icon = NSWorkspace.shared.icon(forFile: controller.model.url.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            insert(item)
        }
        if controllers.count > 1 {
            insert(.separator())
            let all = NSMenuItem(title: tr("Bring All to Front"), action: #selector(bringAllListers), keyEquivalent: "")
            all.target = self
            insert(all)
            let close = NSMenuItem(title: tr("Close All Listers"), action: #selector(closeAllListers), keyEquivalent: "")
            close.target = self
            insert(close)
        }
    }

    @objc private func focusLister(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? ListerWindowController else { return }
        ListerManager.shared.bringToFront(controller)
    }

    @objc private func bringAllListers() { ListerManager.shared.bringAllToFront() }

    @objc private func closeAllListers() { ListerManager.shared.closeAll() }

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
    func terminalChoices() -> [(name: String, id: String)] {
        Self.knownTerminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    func chooseTerminal(id: String) { Settings.terminalBundleID = id }

    @objc private func terminalChosen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { chooseTerminal(id: id) }
    }

    private func rebuildTerminalMenu() {
        terminalMenu.removeAllItems()
        let current = Settings.terminalBundleID
        var choices = terminalChoices()
        // A custom bundle id set with `defaults write` stays visible and checked.
        if !choices.contains(where: { $0.id == current }) { choices.append((current, current)) }
        for choice in choices {
            let item = NSMenuItem(title: choice.name, action: #selector(terminalChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.id == current ? .on : .off
            terminalMenu.addItem(item)
        }
    }

    @objc private func toggleButtonLabels() { Settings.showButtonLabels.toggle() }

    @objc private func chooseTrigger(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let trigger = DesktopTrigger(rawValue: raw) {
            Settings.desktopTrigger = trigger
        }
    }

    /// The language is read when the app starts, so a change asks for a restart.
    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw),
              language != AppLanguage.current else { return }
        language.apply()
        let alert = NSAlert()
        alert.messageText = tr("Restart MacLister to change the language")
        alert.informativeText = tr("Open listers will be closed. Your layout can be restored with Restore Layout.")
        alert.addButton(withTitle: tr("Restart Now"))
        alert.addButton(withTitle: tr("Later"))
        NSApp.bringToFront()
        if alert.runModal() == .alertFirstButtonReturn { Self.relaunch() }
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

    @objc private func chooseButtonBarPosition(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let position = ButtonBarPosition(rawValue: raw) {
            Settings.buttonBarPosition = position
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        labelsItem?.state = Settings.showButtonLabels ? .on : .off
        for item in triggerMenu.items {
            item.state = (item.representedObject as? String) == Settings.desktopTrigger.rawValue ? .on : .off
        }
        for item in buttonBarMenu.items {
            item.state = (item.representedObject as? String) == Settings.buttonBarPosition.rawValue ? .on : .off
        }
        for item in languageMenu.items {
            item.state = (item.representedObject as? String) == AppLanguage.current.rawValue ? .on : .off
        }
        rebuildTerminalMenu()
        rebuildListerItems(in: menu)
        switch monitor.mode {
        case .eventTap:      statusLine.title = tr("Desktop double-click: active")
        case .globalMonitor: statusLine.title = tr("Desktop double-click: active (fallback monitor)")
        case .stopped:       statusLine.title = tr("Waiting for Accessibility permission…")
        }
        settingsItem.isHidden = monitor.mode != .stopped
        centerItem.state = Settings.centerOnCursor ? .on : .off
        undoItem?.title = OperationLog.shared.undoMenuTitle
        undoItem?.isEnabled = OperationLog.shared.lastUndoable != nil
        dragSelectItem?.state = Settings.dragSelectFromNames ? .on : .off
        autoUpdateItem?.state = Settings.autoUpdateCheck ? .on : .off
    }

    @objc private func newLister() {
        let point = NSEvent.mouseLocation
        ListerManager.shared.openLister(directory: Settings.startDirectory, anchor: .cursor(point, centered: true))
    }

    @objc private func openAccessibilitySettings() { Accessibility.openSystemSettings() }

    @objc private func toggleCenter() { Settings.centerOnCursor.toggle() }

    private var undoItem: NSMenuItem!
    private var dragSelectItem: NSMenuItem!
    private var autoUpdateItem: NSMenuItem!

    @objc private func undoFromMenu() {
        OperationLog.shared.undoLast { outcome in
            guard let outcome else { return }
            ListerManager.shared.reloadListers(showing: outcome.folders)
            if !outcome.failures.isEmpty { ListerManager.shared.frontmost?.model.errorMessage = outcome.failures.joined(separator: "; ") }
        }
    }
    @objc private func showOperationLog() { OperationLogWindow.show() }
    @objc private func toggleDragSelect() { Settings.dragSelectFromNames.toggle() }
    @objc private func checkForUpdates() { UpdateManager.shared.check(userInitiated: true) }
    @objc private func toggleAutoUpdate() { Settings.autoUpdateCheck.toggle(); Settings.updateQuestionAsked = true }

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

    @objc private func showShortcuts() { ShortcutsWindowController.shared.show() }

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

    @objc private func editFiletypes() {
        FiletypeStore.shared.ensureConfigFileExists()
        let file = FiletypeStore.shared.configURL
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    @objc private func reloadButtons() { ButtonStore.shared.reload() }

    @objc private func resetButtons() { ButtonStore.shared.resetToDefaults() }

    @objc private func editButtons() { ButtonEditorWindow.show() }

    @objc private func editTitleFormat() { TitleFormatWindow.show() }

    // MARK: - Main menu (an agent app shows no menu bar, but key equivalents still need one)

    private func installMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Quit MacLister"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

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
        windowMenuItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
        // Lets the Services submenu of the file context menu offer services that take files.
        NSApp.registerServicesMenuSendTypes(FinderServices.sendTypes, returnTypes: [])
    }
}
