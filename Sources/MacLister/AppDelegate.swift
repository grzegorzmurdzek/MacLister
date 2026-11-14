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
    private let terminalMenu = NSMenu(title: "Terminal App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()          // before anything touches buttons.json or the defaults
        Settings.registerDefaults()
        ButtonStore.shared.ensureConfigFileExists()
        installMainMenu()
        if Settings.showStatusItem { installStatusItem() }

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
        if CommandLine.arguments.contains("--selftest-features") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTestFeatures.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelfTest.run() }
            return
        }

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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "MacLister")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self

        let newLister = menu.addItem(withTitle: "New Lister", action: #selector(newLister), keyEquivalent: "n")
        newLister.target = self
        menu.addItem(.separator())

        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        settingsItem = menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())

        centerItem = menu.addItem(withTitle: "Center Lister on Cursor", action: #selector(toggleCenter), keyEquivalent: "")
        centerItem.target = self
        labelsItem = menu.addItem(withTitle: "Show Button Labels", action: #selector(toggleButtonLabels), keyEquivalent: "")
        labelsItem.target = self
        let buttonBarItem = menu.addItem(withTitle: "Button Bar", action: nil, keyEquivalent: "")
        buttonBarItem.submenu = buttonBarMenu
        for position in ButtonBarPosition.allCases {
            let item = buttonBarMenu.addItem(withTitle: position.menuTitle, action: #selector(chooseButtonBarPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
        }
        let terminalItem = menu.addItem(withTitle: "Terminal App", action: nil, keyEquivalent: "")
        terminalItem.submenu = terminalMenu
        let duplicate = menu.addItem(withTitle: "Duplicate Frontmost Lister", action: #selector(duplicateFrontmost), keyEquivalent: "")
        duplicate.target = self
        let save = menu.addItem(withTitle: "Save Layout", action: #selector(saveLayout), keyEquivalent: "")
        save.target = self
        let restore = menu.addItem(withTitle: "Restore Layout", action: #selector(restoreLayout), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        let filetypes = menu.addItem(withTitle: "Edit Filetypes…", action: #selector(editFiletypes), keyEquivalent: "")
        filetypes.target = self
        let edit = menu.addItem(withTitle: "Edit Buttons…", action: #selector(editButtons), keyEquivalent: "")
        edit.target = self
        let reload = menu.addItem(withTitle: "Reload Buttons", action: #selector(reloadButtons), keyEquivalent: "")
        reload.target = self
        let reset = menu.addItem(withTitle: "Reset Buttons to Defaults", action: #selector(resetButtons), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacLister", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
            let none = NSMenuItem(title: "No open listers", action: nil, keyEquivalent: "")
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
            let all = NSMenuItem(title: "Bring All to Front", action: #selector(bringAllListers), keyEquivalent: "")
            all.target = self
            insert(all)
            let close = NSMenuItem(title: "Close All Listers", action: #selector(closeAllListers), keyEquivalent: "")
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

    @objc private func chooseButtonBarPosition(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let position = ButtonBarPosition(rawValue: raw) {
            Settings.buttonBarPosition = position
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        labelsItem?.state = Settings.showButtonLabels ? .on : .off
        for item in buttonBarMenu.items {
            item.state = (item.representedObject as? String) == Settings.buttonBarPosition.rawValue ? .on : .off
        }
        rebuildTerminalMenu()
        rebuildListerItems(in: menu)
        switch monitor.mode {
        case .eventTap:      statusLine.title = "Desktop double-click: active"
        case .globalMonitor: statusLine.title = "Desktop double-click: active (fallback monitor)"
        case .stopped:       statusLine.title = "Waiting for Accessibility permission…"
        }
        settingsItem.isHidden = monitor.mode != .stopped
        centerItem.state = Settings.centerOnCursor ? .on : .off
    }

    @objc private func newLister() {
        let point = NSEvent.mouseLocation
        ListerManager.shared.openLister(directory: Settings.startDirectory, anchor: .cursor(point, centered: true))
    }

    @objc private func openAccessibilitySettings() { Accessibility.openSystemSettings() }

    @objc private func toggleCenter() { Settings.centerOnCursor.toggle() }

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

    @objc private func editButtons() {
        ButtonStore.shared.ensureConfigFileExists()
        let file = ButtonStore.configURL
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    // MARK: - Main menu (an agent app shows no menu bar, but key equivalents still need one)

    private func installMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MacLister", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = edit

        let windowMenuItem = NSMenuItem()
        main.addItem(windowMenuItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}
