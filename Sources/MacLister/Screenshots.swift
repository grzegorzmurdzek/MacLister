import AppKit
import SwiftUI

/// `MacLister --screenshots <folder> [dark]`: draws the app's own windows with made-up files and saves
/// them as PNGs for the README and the forum. A window of its own (a soft gradient) covers the screen behind
/// the app's windows, so nothing else from the desktop can appear in a picture. Needs Screen Recording
/// access for the process that starts it.
enum Screenshots {
    private static var outDir = URL(fileURLWithPath: "/tmp")
    private static var dark = false
    private static var demo = DemoFiles()
    private static var steps: [(String, () -> Void)] = []
    private static var backdrop: NSWindow?

    // MARK: Entry

    static func run(outDir: URL, dark: Bool) {
        self.outDir = outDir
        self.dark = dark
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-shots-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AppSupport.override = support                         // bookmarks, layouts, servers: nothing of the user's
        SharedPlaces.browsingEnabled = false
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        demo = DemoFiles()
        demo.create()
        VolumeInfo.hidden = true                                     // no real disk figures in the title bars
        makeBackdrop()

        let suffix = dark ? "-dark" : ""
        queue("lister-pair\(suffix)") { pair(named: "lister-pair\(suffix)") }
        queue("context-menu\(suffix)") { contextMenu(named: "context-menu\(suffix)") }
        queue("transfer-details\(suffix)") { transferDetails(named: "transfer-details\(suffix)") }
        queue("two-panel\(suffix)") { twoPanel(named: "two-panel\(suffix)") }
        if !dark {
            queue("title-bar-menu") { titleBarMenu(named: "title-bar-menu") }
            queue("folder-tree") { folderTree(named: "folder-tree") }
            queue("tabs") { tabsShot(named: "tabs") }
            queue("find") { findWindow(named: "find") }
            queue("find-duplicates") { duplicatesWindow(named: "find-duplicates") }
            queue("checksums") { checksumsWindow(named: "checksums") }
            queue("synchronize") { synchronizeWindow(named: "synchronize") }
            queue("batch-rename") { batchRename(named: "batch-rename") }
            queue("name-lister") { nameLister(named: "name-lister") }
            queue("connect-to-server") { connectSheet(named: "connect-to-server") }
            queue("keyboard-shortcuts") { shortcuts(named: "keyboard-shortcuts") }
            queue("drag-select") { dragSelect(named: "drag-select") }
            queue("back-history") { backHistory(named: "back-history") }
            queue("operation-log") { operationLog(named: "operation-log") }
            queue("button-editor") { buttonEditor(named: "button-editor") }
            queue("lister-title") { listerTitle(named: "lister-title") }
            for (index, name) in ["general", "listers", "tabs", "workspaces", "buttons", "filetypes", "operations", "updates"].enumerated() {
                queue("settings-\(name)") { settings(tab: index, named: "settings-\(name)") }
            }
        }
        // `-onlyShots tabs,find`: just those pictures (the others are left as they are)
        if let only = UserDefaults.standard.string(forKey: "onlyShots")?.split(separator: ",").map(String.init) {
            steps = steps.filter { step in only.contains { step.0 == $0 || step.0 == $0 + "-dark" } }
        }
        next()
    }

    private static func queue(_ name: String, _ body: @escaping () -> Void) { steps.append((name, body)) }

    /// Runs the next scene; each scene calls `finishScene` when its picture is saved.
    private static func next() {
        guard !steps.isEmpty else { finish(); return }
        let (name, body) = steps.removeFirst()
        print("scene \(name)")
        body()
    }

    private static func finishScene() {
        ListerManager.shared.closeAll()
        for window in NSApp.windows where window.isVisible && window.level == .normal && window !== backdrop { window.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
    }

    private static func finish() {
        backdrop?.close()
        demo.remove()
        if let support = AppSupport.override { try? FileManager.default.removeItem(at: support) }
        AppSupport.override = nil
        print("done: \(outDir.path)")
        NSApp.terminate(nil)
    }

    // MARK: Scenes

    /// The sharpest display (a Retina one when there is one): pictures made there have twice the pixels.
    private static var chosenScreen: NSScreen? {
        NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main
    }

    private static func screen() -> NSRect { chosenScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// Two listers: Projects (source, selection) and a NAS (destination) with a copy in progress.
    private static func pair(named name: String) {
        let area = screen()
        let size = NSSize(width: 700, height: 430)
        let leftOrigin = NSPoint(x: area.minX + 60, y: area.maxY - size.height - 90)
        let rightOrigin = NSPoint(x: leftOrigin.x + size.width + 36, y: leftOrigin.y - 34)
        let manager = ListerManager.shared
        let left = manager.openLister(directory: demo.projects, anchor: .origin(leftOrigin))
        let right = manager.openLister(directory: demo.backup, anchor: .origin(rightOrigin))
        for controller in [left, right] { controller.window?.setContentSize(size) }
        left.window?.setFrameOrigin(leftOrigin)
        right.window?.setFrameOrigin(rightOrigin)
        left.model.setLabel(tr("Work"), color: "blue")
        right.model.setLabel("NAS", color: "orange")
        manager.toggleRole(.source, for: left)
        manager.toggleRole(.destination, for: right)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            left.listerViewController?.setSelectionForSheetTest(["report", "budget", "video"].map { demo.project($0) })
            let monitor = syntheticMonitor(progressFraction: 0.62)
            let status = TransferStatus(text: ListerViewController.progressText(verb: tr("Copying"), progress: monitor.progress, speed: monitor.speed, paused: false, queued: 0),
                                        fraction: monitor.progress.fraction, cancel: { }, details: monitor)
            left.model.progress = status
            right.model.progress = status
            NSApp.activate(ignoringOtherApps: true)
            left.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                capture(to: name)
                left.model.progress = nil
                right.model.progress = nil
                finishScene()
            }
        }
    }

    /// A two-panel window: Projects (the pane you work in, the source, with a selection) beside a NAS (the destination).
    private static func twoPanel(named name: String) {
        let area = screen()
        let size = NSSize(width: min(1420, area.width - 120), height: 470)        // each pane as wide as a lister of lister-pair
        let origin = NSPoint(x: area.minX + 60, y: area.maxY - size.height - 120)
        let dual = ListerManager.shared.openDual(left: demo.projects, right: demo.backup, anchor: .origin(origin)) { dual in
            dual.window?.setContentSize(size)
        }
        dual.window?.setFrameOrigin(origin)
        dual.splitEvenly()
        dual.leftPane.model.setLabel(tr("Work"), color: "blue")
        dual.rightPane.model.setLabel("NAS", color: "orange")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            dual.leftPane.listerViewController?.setSelectionForSheetTest(["report", "budget", "video"].map { demo.project($0) })
            NSApp.activate(ignoringOtherApps: true)
            dual.window?.makeKeyAndOrderFront(nil)
            dual.focus(dual.leftPane)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                // once more: after the scene before, the app is not always the active one yet (a dimmed window)
                NSApp.activate(ignoringOtherApps: true)
                dual.window?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { capture(to: name); finishScene() }
            }
        }
    }

    /// The right-click menu on a spreadsheet.
    private static func contextMenu(named name: String) {
        let area = screen()
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(NSPoint(x: area.minX + 100, y: area.maxY - 500)))
        controller.window?.setContentSize(NSSize(width: 700, height: 440))
        controller.window?.setFrameOrigin(NSPoint(x: area.minX + 100, y: area.maxY - 500))
        controller.model.setLabel(tr("Work"), color: "blue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController,
                  let item = controller.model.items.first(where: { $0.name == demo.name("report") }),
                  let row = vc.rows.firstIndex(of: item) else { finishScene(); return }
            vc.setSelectionForSheetTest([item.url])
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            let menu = NSMenu()
            vc.populate(menu, selection: [item])
            let rect = vc.tableView.rect(ofRow: row)
            popUp(menu, at: NSPoint(x: 250, y: rect.midY), in: vc.tableView, capturing: name)
        }
    }

    /// The lister menu of the title bar.
    private static func titleBarMenu(named name: String) {
        let area = screen()
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(NSPoint(x: area.minX + 100, y: area.maxY - 500)))
        controller.window?.setContentSize(NSSize(width: 700, height: 440))
        controller.window?.setFrameOrigin(NSPoint(x: area.minX + 100, y: area.maxY - 500))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController else { finishScene(); return }
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            popUp(vc.makeTitleBarMenu(), at: NSPoint(x: 40, y: 6), in: vc.tableView.enclosingScrollView ?? vc.view, capturing: name)
        }
    }

    private static func transferDetails(named name: String) {
        let monitor = syntheticMonitor(progressFraction: nil)
        let percent = Int((monitor.progress.fraction * 100).rounded())
        let window = show(TransferDetailsView(monitor: monitor, close: { }), title: "\(percent)% — \(tr("Copying"))")
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 640))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            capture(to: name)
            finishScene()
        }
    }

    private static func batchRename(named name: String) {
        var options = BatchRenameOptions()
        options.find = "Q4"
        options.replace = "2026-Q4"
        options.caseMode = .unchanged
        let files = ["budget", "notes", "logo", "contract"].map { demo.project($0) }
        let window = show(BatchRenameView(items: files, initial: options, onApply: { _ in }, close: { }), title: tr("Rename"))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    /// A lister with the folder tree beside the list; the tree starts at the demo folder, not at the real home folder.
    private static func folderTree(named name: String) {
        let area = screen()
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(NSPoint(x: area.minX + 100, y: area.maxY - 500)))
        controller.window?.setContentSize(NSSize(width: 760, height: 440))
        controller.window?.setFrameOrigin(NSPoint(x: area.minX + 100, y: area.maxY - 500))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController else { finishScene(); return }
            vc.treeController.setRoots([demo.base])
            vc.setTree(visible: true, remember: false)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
        }
    }

    /// One lister with three tabs: the folder, a folder of photos and a tab named "NAS" with a colour.
    private static func tabsShot(named name: String) {
        let area = screen()
        let origin = NSPoint(x: area.minX + 100, y: area.maxY - 500)
        let host = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(origin))
        host.window?.setContentSize(NSSize(width: 760, height: 440))
        host.window?.setFrameOrigin(origin)
        host.model.setLabel(tr("Work"), color: "blue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let photos = ListerManager.shared.newTab(from: host)
            photos?.model.navigate(to: demo.project("f_photos"))
            let nas = photos.flatMap { ListerManager.shared.openFolder(demo.backup, inNewTabFrom: $0) }
            nas?.model.setLabel("NAS", color: "orange")
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                ListerManager.shared.select(host)       // the tab with files in it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
            }
        }
    }

    private static func findWindow(named name: String) {
        var query = FindQuery(scope: demo.projects)
        query.name = "*.pdf *.key"
        query.withinDays = 30
        let window = show(FindView(initial: query, onFind: { _ in }, close: { }), title: tr("Find"), size: NSSize(width: 500, height: 440))
        window.setFrameOrigin(NSPoint(x: screen().minX + 300, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    private static func duplicatesWindow(named name: String) {
        let window = show(DuplicatesView(initial: DuplicateFinder.Options(scope: demo.base), autoSearch: true, onTrash: { _, _ in }, close: { }),
                          title: tr("Find Duplicates"), size: NSSize(width: 720, height: 600))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 760))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { capture(to: name); finishScene() }
    }

    private static func checksumsWindow(named name: String) {
        let window = show(ChecksumsView(urls: [demo.project("report"), demo.project("notes")], close: { }),
                          title: tr("Checksums"), size: NSSize(width: 640, height: 460))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { capture(to: name); finishScene() }
    }

    private static func synchronizeWindow(named name: String) {
        let window = show(SynchronizeView(source: demo.projects, destination: demo.backup, onRun: { _ in }, close: { }),
                          title: tr("Synchronize"), size: NSSize(width: 640, height: 560))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { capture(to: name); finishScene() }
    }

    private static func nameLister(named name: String) {
        let window = show(ListerLabelView(initialName: "NAS", initialColor: "orange", onApply: { _, _ in }, close: { }), title: tr("Name This Lister"))
        window.setFrameOrigin(NSPoint(x: screen().minX + 300, y: screen().maxY - 460))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { capture(to: name); finishScene() }
    }

    private static func connectSheet(named name: String) {
        var profile = ServerProfile()
        profile.scheme = .sftp
        profile.host = "files.example.org"
        profile.user = "demo"
        profile.name = "Web host"
        let window = show(ConnectToServerView(initial: profile, initialSecret: "", onConnect: { _, _, _, _, _ in }, close: { }), title: tr("Connect to Server"))
        window.setFrameOrigin(NSPoint(x: screen().minX + 300, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    private static func shortcuts(named name: String) {
        let window = show(ShortcutsView(), title: tr("Keyboard Shortcuts"), size: NSSize(width: 620, height: 640))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    /// Four rows selected by dragging over them.
    private static func dragSelect(named name: String) {
        let area = screen()
        let origin = NSPoint(x: area.minX + 100, y: area.maxY - 500)
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(origin))
        controller.window?.setContentSize(NSSize(width: 700, height: 400))
        controller.window?.setFrameOrigin(origin)
        controller.model.setLabel(tr("Work"), color: "blue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController else { finishScene(); return }
            let table = vc.tableView
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            table.layoutSubtreeIfNeeded()
            let from = NSPoint(x: table.bounds.maxX - 90, y: table.rect(ofRow: 2).midY + 3)
            let to = NSPoint(x: table.bounds.midX - 60, y: table.rect(ofRow: 5).midY - 3)
            table.applyLasso(from: from, to: to, extending: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.window?.makeFirstResponder(table)          // the selection is blue only in the active window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { capture(to: name); finishScene() }
            }
        }
    }

    /// The folders Back can return to, listed under a right-click on the Back button.
    private static func backHistory(named name: String) {
        let area = screen()
        let origin = NSPoint(x: area.minX + 100, y: area.maxY - 500)
        let controller = ListerManager.shared.openLister(directory: demo.base, anchor: .origin(origin))
        controller.window?.setContentSize(NSSize(width: 700, height: 400))
        controller.window?.setFrameOrigin(origin)
        for url in [demo.backup, demo.projects, demo.project("f_photos"), demo.project("f_brand"), demo.project("f_web")] { controller.model.navigate(to: url) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController else { finishScene(); return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for url in controller.model.backHistory.prefix(20) {
                let item = NSMenuItem(title: PathBarView.historyTitle(url), action: nil, keyEquivalent: "")
                item.isEnabled = true
                item.image = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
                item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            popUp(menu, at: NSPoint(x: 26, y: vc.view.bounds.height - 94), in: vc.view, capturing: name)
        }
    }

    /// The operation log with a few invented operations.
    private static func operationLog(named name: String) {
        let log = OperationLog.shared
        log.clear()
        let base = Date()
        func add(_ kind: OperationRecord.Kind, _ keys: [String], minutesAgo: Double, from: String, to: String, problems: [String] = [], cancelled: Bool = false, undoable: Bool = false) {
            log.now = { base.addingTimeInterval(-minutesAgo * 60) }
            let urls = keys.map { demo.project($0) }
            var result = TransferResult()
            result.done = problems.isEmpty && !cancelled ? urls : Array(urls.dropLast())
            result.failures = problems
            result.cancelled = cancelled
            if undoable { result.pairs = urls.map { TransferPair(source: $0, target: demo.backup.appendingPathComponent($0.lastPathComponent)) } }
            log.record(kind: kind, items: urls, result: result, from: from, to: to)
        }
        let projects = demo.name("projects"), backup = "NAS · " + demo.name("backup")
        add(.copy, ["wireframes"], minutesAgo: 1500, from: projects, to: backup)
        add(.upload, ["archive", "deck"], minutesAgo: 380, from: projects, to: "files.example.org/web")
        add(.move, ["notes", "logo"], minutesAgo: 95, from: projects, to: backup)
        add(.trash, ["contract"], minutesAgo: 41, from: projects, to: tr("Trash"))
        add(.copy, ["report", "budget", "video"], minutesAgo: 12, from: projects, to: backup, problems: [demo.name("video") + ": " + tr("cannot copy a folder into itself")])
        add(.move, ["deck", "archive"], minutesAgo: 3, from: projects, to: backup, cancelled: true)
        add(.copy, ["report", "budget"], minutesAgo: 1, from: projects, to: backup, undoable: true)
        log.now = Date.init
        let window = show(OperationLogView(), title: tr("Operation Log"), size: NSSize(width: 660, height: 440))
        window.setFrameOrigin(NSPoint(x: screen().minX + 160, y: screen().maxY - 620))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            capture(to: name)
            log.clear()
            finishScene()
        }
    }

    /// The button editor with Copy selected: Copy on the left button, Move on the right, Info on the middle one.
    private static func buttonEditor(named name: String) {
        var buttons = ListerButton.defaults
        if let copy = buttons.firstIndex(where: { $0.action == .copy }) {
            buttons[copy].rightAction = .move
            buttons[copy].middleAction = .compare
        }
        if let terminal = buttons.firstIndex(where: { $0.action == .terminalHere }) {
            buttons[terminal].middleAction = .shell
            buttons[terminal].middleCommand = "open -a Finder \"$LISTER_DIR\""
        }
        let selected = buttons.firstIndex { $0.action == .copy }
        let window = show(ButtonEditorView(initial: buttons, selection: selected, close: { }), title: tr("Edit Buttons"), size: NSSize(width: 720, height: 500))
        window.setFrameOrigin(NSPoint(x: screen().minX + 160, y: screen().maxY - 640))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { capture(to: name); finishScene() }
    }

    /// The title format editor with a lister behind it that supplies the preview.
    private static func listerTitle(named name: String) {
        let area = screen()
        let origin = NSPoint(x: area.minX + 60, y: area.maxY - 440)
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(origin))
        controller.window?.setContentSize(NSSize(width: 640, height: 300))
        controller.window?.setFrameOrigin(origin)
        controller.model.setLabel(tr("Work"), color: "blue")
        ListerManager.shared.toggleRole(.source, for: controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            controller.listerViewController?.setSelectionForSheetTest(["report", "budget"].map { demo.project($0) })
            let window = show(TitleFormatEditor(title: "{%l — }%n", subtitle: "%c · %s selected{ · %S}{ · %R}", close: { }), title: tr("Lister Title"))
            window.setFrameOrigin(NSPoint(x: area.minX + 260, y: area.maxY - 900))
            controller.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { capture(to: name); finishScene() }
            }
        }
    }

    /// One tab of the Settings window.
    private static func settings(tab: Int, named name: String) {
        SettingsWindow.show(tab: tab)
        guard let window = NSApp.windows.first(where: { $0.contentViewController is NSTabViewController }) else { finishScene(); return }
        window.setFrameOrigin(NSPoint(x: screen().minX + 260, y: screen().maxY - window.frame.height - 160))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { capture(to: name); finishScene() }
    }

    // MARK: Helpers

    private static func show<V: View>(_ view: V, title: String, size: NSSize? = nil) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if let size { window.setContentSize(size) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Opens a menu, takes the picture while it is open, then closes it. Menu tracking sometimes ends at once
    /// (the app was not yet active); the menu is then opened again, up to four times.
    private static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView, capturing name: String, attempt: Int = 1) {
        var captured = false
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            if NSApp.windows.contains(where: { $0.isVisible && String(describing: type(of: $0)).contains("PopupMenu") }) {
                capture(to: name)
                captured = true
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)         // .common includes the menu-tracking mode
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        menu.popUp(positioning: nil, at: point, in: view)  // returns when the menu has closed
        timer.invalidate()
        if captured {
            finishScene()
        } else if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { popUp(menu, at: point, in: view, capturing: name, attempt: attempt + 1) }
        } else {
            print("the menu for \(name) did not stay open")
            finishScene()
        }
    }

    /// A copy that is 62 % done after 72 s: a ramp-up, a plateau, a dip and a recovery.
    private static func syntheticMonitor(progressFraction: Double?) -> TransferMonitor {
        let start = Date().addingTimeInterval(-72)
        let monitor = TransferMonitor(title: tr("Copying"), from: demo.name("projects"), to: "NAS · " + demo.name("backup"), now: start)
        var progress = TransferProgress(itemsDone: 0, itemsTotal: 3, bytesDone: 0, bytesTotal: 3_900_000_000, current: demo.name("video"))
        var written: Int64 = 0
        for step in 1...144 {
            let t = Double(step) * 0.5
            var rate = 38_000_000.0
            if t < 4 { rate = 38_000_000 * t / 4 }
            if t > 38 && t < 46 { rate = 22_000_000 + 3_000_000 * sin(t) }
            if t > 46 { rate = 33_000_000 + 4_000_000 * sin(t / 3) }
            rate += 2_500_000 * sin(t * 1.7)
            written += Int64(rate * 0.5)
            progress.bytesDone = written
            progress.itemsDone = Int(Double(written) / 1_300_000_000)
            monitor.update(progress, now: start.addingTimeInterval(t))
        }
        return monitor
    }

    // MARK: Capture

    /// A borderless window with a soft gradient, in front of every other application and behind this app's windows.
    private static func makeBackdrop() {
        let frame = screen()
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        let colors: [Color] = dark ? [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.20, green: 0.14, blue: 0.27)]
                                   : [Color(red: 0.80, green: 0.88, blue: 0.97), Color(red: 0.93, green: 0.84, blue: 0.95)]
        window.contentView = NSHostingView(rootView: LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    /// Takes the picture of the area around this app's windows (menus included) from the screen. Only the backdrop and
    /// this app's windows can be in it, so nothing of the user's desktop is.
    private static func capture(to name: String) {
        guard let backdrop, let main = NSScreen.screens.first else { return }
        let region = backdrop.frame
        let mine = NSApp.windows.filter { $0.isVisible && $0 !== backdrop && !($0 is NSPanel && $0.title.isEmpty && $0.frame.height < 40) && !String(describing: type(of: $0)).contains("StatusBar") }
        guard !mine.isEmpty else { print("nothing to capture for \(name)"); return }
        var union = mine[0].frame
        for window in mine.dropFirst() { union = union.union(window.frame) }
        let pad: CGFloat = 70
        let wanted = union.insetBy(dx: -pad, dy: -pad).intersection(region)

        // the whole backdrop, then cut out the part around the windows
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let top = main.frame.maxY - region.maxY                      // Cocoa counts from the bottom, screencapture from the top
        process.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(top)),\(Int(region.width)),\(Int(region.height))", file.path]
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let source = NSImage(contentsOf: file),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("capture failed for \(name)"); return }
        let factor = CGFloat(cg.width) / region.width
        let crop = CGRect(x: (wanted.minX - region.minX) * factor, y: (region.maxY - wanted.maxY) * factor,
                          width: wanted.width * factor, height: wanted.height * factor).integral
        guard let cut = cg.cropping(to: crop) else { return }
        let rep = NSBitmapImageRep(cgImage: cut)
        let url = outDir.appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent) (\(cut.width)×\(cut.height))")
    }
}

// MARK: - Made-up files

/// A folder of invented documents under /Users/Shared, so no real file name ever appears in a picture.
/// Names are in the language the app runs in.
struct DemoFiles {
    let base = URL(fileURLWithPath: "/Users/Shared/MacLister Demo")
    private let polish = AppLanguage.effectiveCode == "pl"

    private var names: [String: String] {
        polish ? [
            "projects": "Projekty", "backup": "Kopia",
            "report": "Raport roczny 2026.pdf", "budget": "Budżet Q4.xlsx", "notes": "Notatki ze spotkania.md", "logo": "Logo finalne.png",
            "video": "Prezentacja produktu.mov", "deck": "Prezentacja.key", "contract": "Umowa (wersja robocza).docx",
            "wireframes": "Makiety.fig", "archive": "Archiwum 2025.zip",
            "f_brand": "Materiały marki", "f_invoices": "Faktury klientów", "f_photos": "Zdjęcia 2026", "f_web": "Nowa strona www",
            "b_index": "indeks-kopii.json", "b_invoices": "Faktury klientów.zip", "b_brand": "Materiały marki.zip", "b_photos": "Zdjęcia",
        ] : [
            "projects": "Projects", "backup": "Backup",
            "report": "Annual Report 2026.pdf", "budget": "Budget Q4.xlsx", "notes": "Meeting Notes.md", "logo": "Logo Final.png",
            "video": "Product Demo.mov", "deck": "Presentation.key", "contract": "Contract Draft.docx",
            "wireframes": "Wireframes.fig", "archive": "Archive 2025.zip",
            "f_brand": "Brand Assets", "f_invoices": "Client Invoices", "f_photos": "Photos 2026", "f_web": "Website Redesign",
            "b_index": "backup-index.json", "b_invoices": "Client Invoices.zip", "b_brand": "Brand Assets.zip", "b_photos": "Photos",
        ]
    }

    func name(_ key: String) -> String { names[key] ?? key }
    var projects: URL { base.appendingPathComponent(name("projects")) }
    var backup: URL { base.appendingPathComponent(name("backup")) }
    func project(_ key: String) -> URL { projects.appendingPathComponent(name(key)) }

    func create() {
        remove()
        let fm = FileManager.default
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        func when(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? now
            let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return min(date, now.addingTimeInterval(-120))
        }
        func file(_ key: String, in folder: URL, bytes: Int64, date: Date) {
            let url = folder.appendingPathComponent(name(key))
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) { try? handle.truncate(atOffset: UInt64(bytes)); try? handle.close() }
            try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
        func folder(_ title: String, in parent: URL, date: Date) {
            let url = parent.appendingPathComponent(title)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try? fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for (key, days) in [("f_brand", 6), ("f_invoices", 2), ("f_photos", 1), ("f_web", 0)] {
            folder(name(key), in: projects, date: when(daysAgo: days, hour: 16, minute: 20))
        }
        file("report", in: projects, bytes: 4_400_000, date: when(daysAgo: 0, hour: 9, minute: 41))
        file("budget", in: projects, bytes: 86_000, date: when(daysAgo: 0, hour: 8, minute: 15))
        file("notes", in: projects, bytes: 4_200, date: when(daysAgo: 1, hour: 17, minute: 5))
        file("logo", in: projects, bytes: 312_000, date: when(daysAgo: 1, hour: 11, minute: 32))
        file("video", in: projects, bytes: 184_000_000, date: when(daysAgo: 2, hour: 14, minute: 48))
        file("deck", in: projects, bytes: 22_000_000, date: when(daysAgo: 3, hour: 10, minute: 12))
        file("contract", in: projects, bytes: 118_000, date: when(daysAgo: 9, hour: 15, minute: 30))
        file("wireframes", in: projects, bytes: 9_600_000, date: when(daysAgo: 14, hour: 13, minute: 0))
        file("archive", in: projects, bytes: 640_000_000, date: when(daysAgo: 40, hour: 9, minute: 0))
        for (title, days) in [("2024", 120), ("2025", 60), ("2026", 0), (name("b_photos"), 8)] {
            folder(title, in: backup, date: when(daysAgo: days, hour: 12, minute: 0))
        }
        file("b_index", in: backup, bytes: 18_000, date: when(daysAgo: 0, hour: 7, minute: 0))
        file("logo", in: backup, bytes: 312_000, date: when(daysAgo: 8, hour: 12, minute: 5))        // copies of files above:
        file("budget", in: backup, bytes: 86_000, date: when(daysAgo: 8, hour: 12, minute: 6))       // what Find Duplicates finds
        file("b_invoices", in: backup, bytes: 54_000_000, date: when(daysAgo: 7, hour: 18, minute: 25))
        file("b_brand", in: backup, bytes: 310_000_000, date: when(daysAgo: 12, hour: 10, minute: 40))
        FinderTags.toggle(label: 6, on: [project("report")])
        FinderTags.toggle(label: 4, on: [project("budget")])
    }

    func remove() {
        guard base.lastPathComponent == "MacLister Demo", base.deletingLastPathComponent().path == "/Users/Shared" else { return }
        try? FileManager.default.removeItem(at: base)
    }
}
