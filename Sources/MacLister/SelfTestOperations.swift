import AppKit
import SwiftUI

/// `MacLister --selftest-ops`: undo, the operation log, the Back history, drag-select, Tab between listers
/// and the update check. Results go to ~/Library/Logs/MacLister.log.
enum SelfTestOperations {
    private static var failures = 0
    private static var doubleUndoCopy: URL?

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("ops \(condition ? "ok  " : "FAIL") \(message)")
    }

    private static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-ops-\(UUID().uuidString)")
        AppSupport.override = root.appendingPathComponent("support")
        let dirA = root.appendingPathComponent("A"), dirB = root.appendingPathComponent("B")
        for dir in [AppSupport.override!, dirA, dirB] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func write(_ name: String, _ body: String, in dir: URL) { try? body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
        func transfer(_ kind: TransferKind, _ names: [String], action: ConflictAction = .keepBoth) -> TransferResult {
            let job = TransferJob(kind: kind, items: names.map { dirA.appendingPathComponent($0) }, destination: dirB)
            job.resolver = { _ in ConflictDecision(action: action, applyToAll: true) }
            let result = job.runSync()
            log.record(kind: kind == .copy ? .copy : .move, items: job.items, result: result, from: "A", to: "B")
            return result
        }
        let log = OperationLog.shared
        UserDefaults.standard.set(30, forKey: "logRetentionDays")
        log.reloadFromDisk()
        log.clear()

        // --- copy, undo
        write("opstest_1.txt", "one", in: dirA)
        var result = transfer(.copy, ["opstest_1.txt"])
        check(result.pairs.count == 1 && exists(dirB.appendingPathComponent("opstest_1.txt")), "copy arrives and is recorded as a pair")
        check(log.lastUndoable?.kind == .copy && log.undoMenuTitle.contains("opstest_1.txt"), "the undo menu names the operation: \(log.undoMenuTitle)")
        var outcome = log.undoLastSync()
        check(outcome?.restored == 1 && outcome?.failures.isEmpty == true, "undo of a copy succeeds")
        check(!exists(dirB.appendingPathComponent("opstest_1.txt")) && exists(dirA.appendingPathComponent("opstest_1.txt")), "undo of a copy removes only the copy")
        check(log.records.first?.undone == true && log.lastUndoable == nil, "the record says undone, nothing left to undo")

        // --- copy over an existing file (Replace), undo brings the old one back
        write("opstest_2.txt", "new!!", in: dirA); write("opstest_2.txt", "old", in: dirB)
        result = transfer(.copy, ["opstest_2.txt"], action: .replace)
        check(text(dirB.appendingPathComponent("opstest_2.txt")) == "new!!" && result.pairs.first?.replaced != nil, "Replace remembers where the old file went")
        outcome = log.undoLastSync()
        check(text(dirB.appendingPathComponent("opstest_2.txt")) == "old", "undo of a replacing copy restores the old file: \(text(dirB.appendingPathComponent("opstest_2.txt")) ?? "nil")")

        // --- move, undo
        write("opstest_3.txt", "three", in: dirA)
        result = transfer(.move, ["opstest_3.txt"])
        check(!exists(dirA.appendingPathComponent("opstest_3.txt")) && exists(dirB.appendingPathComponent("opstest_3.txt")), "move happened")
        outcome = log.undoLastSync()
        check(exists(dirA.appendingPathComponent("opstest_3.txt")) && !exists(dirB.appendingPathComponent("opstest_3.txt")), "undo of a move puts the file back")

        // --- move whose old place is taken
        result = transfer(.move, ["opstest_3.txt"])
        write("opstest_3.txt", "someone else", in: dirA)
        outcome = log.undoLastSync()
        check(outcome?.failures.count == 1 && exists(dirB.appendingPathComponent("opstest_3.txt")) && text(dirA.appendingPathComponent("opstest_3.txt")) == "someone else",
              "undo refuses to overwrite what is at the old place: \(outcome?.failures ?? [])")
        check(log.records.first?.undone == false && !(log.records.first?.problems.isEmpty ?? true), "a failed undo is noted in the log")
        try? fm.removeItem(at: dirA.appendingPathComponent("opstest_3.txt")); try? fm.removeItem(at: dirB.appendingPathComponent("opstest_3.txt"))

        // --- folder move and a merge (merge cannot be undone safely)
        try? fm.createDirectory(at: dirA.appendingPathComponent("opstest_dir"), withIntermediateDirectories: true)
        write("in.txt", "x", in: dirA.appendingPathComponent("opstest_dir"))
        result = transfer(.move, ["opstest_dir"])
        check(exists(dirB.appendingPathComponent("opstest_dir/in.txt")), "folder moved")
        outcome = log.undoLastSync()
        check(exists(dirA.appendingPathComponent("opstest_dir/in.txt")) && !exists(dirB.appendingPathComponent("opstest_dir")), "undo of a folder move")
        try? fm.createDirectory(at: dirB.appendingPathComponent("opstest_dir"), withIntermediateDirectories: true)
        write("other.txt", "y", in: dirB.appendingPathComponent("opstest_dir"))
        result = transfer(.copy, ["opstest_dir"], action: .merge)
        check(result.pairs.first?.undoable == false && log.lastUndoable == nil, "a merge is logged but not offered for undo")
        try? fm.removeItem(at: dirA.appendingPathComponent("opstest_dir")); try? fm.removeItem(at: dirB.appendingPathComponent("opstest_dir"))

        // --- Move to Trash, duplicate
        write("opstest_4.txt", "four", in: dirA)
        var landed: NSURL?
        try? fm.trashItem(at: dirA.appendingPathComponent("opstest_4.txt"), resultingItemURL: &landed)
        var trashResult = TransferResult()
        if let landed { trashResult.pairs = [TransferPair(source: dirA.appendingPathComponent("opstest_4.txt"), target: landed as URL)]; trashResult.done = [dirA.appendingPathComponent("opstest_4.txt")] }
        log.record(kind: .trash, items: [dirA.appendingPathComponent("opstest_4.txt")], result: trashResult, from: "A", to: "Trash")
        check(!exists(dirA.appendingPathComponent("opstest_4.txt")), "file is in the Trash")
        outcome = log.undoLastSync()
        check(text(dirA.appendingPathComponent("opstest_4.txt")) == "four", "undo of Move to Trash puts the file back")
        let duplicate = FileTransfer.duplicate([dirA.appendingPathComponent("opstest_4.txt")])
        log.record(kind: .duplicate, items: [dirA.appendingPathComponent("opstest_4.txt")], result: duplicate, from: "A", to: "A")
        check(exists(dirA.appendingPathComponent("opstest_4 copy.txt")), "duplicate made")
        outcome = log.undoLastSync()
        check(!exists(dirA.appendingPathComponent("opstest_4 copy.txt")) && exists(dirA.appendingPathComponent("opstest_4.txt")), "undo of a duplicate removes the duplicate")
        try? fm.removeItem(at: dirA.appendingPathComponent("opstest_4.txt"))

        // --- order of undo, uploads are logged only
        write("opstest_5.txt", "5", in: dirA); write("opstest_6.txt", "6", in: dirA)
        _ = transfer(.copy, ["opstest_5.txt"]); _ = transfer(.copy, ["opstest_6.txt"])
        check(log.lastUndoable?.label.contains("opstest_6") == true, "the newest operation is undone first")
        _ = log.undoLastSync()
        check(exists(dirB.appendingPathComponent("opstest_5.txt")) && !exists(dirB.appendingPathComponent("opstest_6.txt")), "only the last operation was undone")
        _ = log.undoLastSync()
        var remote = TransferResult(); remote.done = [dirB]; remote.pairs = [TransferPair(source: dirA, target: dirB)]
        log.record(kind: .upload, items: [dirA], result: remote, from: "A", to: "ftp")
        check(log.lastUndoable == nil && log.records.first?.kind == .upload, "an upload is logged, never offered for undo")

        // --- retention and size limit
        log.clear()
        let day: TimeInterval = 86_400
        for age in [40.0, 20.0, 5.0, 0.0] {
            log.now = { Date().addingTimeInterval(-age * day) }
            log.record(kind: .copy, items: [dirA], result: TransferResult(), from: "A", to: "B")
        }
        log.now = Date.init
        check(log.records.count == 3, "records older than 30 days were dropped when adding: \(log.records.count)")
        OperationLog.retentionDays = 7
        let dropped = log.prune()
        check(dropped == 1 && log.records.count == 2, "a shorter retention prunes at once: dropped \(dropped)")
        OperationLog.retentionDays = 30
        log.reloadFromDisk()
        check(log.records.count == 2, "the log survives a restart: \(log.records.count)")
        check(log.lastUndoable == nil, "but undo does not")
        for _ in 0..<(OperationLog.maxRecords + 10) { log.record(kind: .copy, items: [dirA], result: TransferResult(), from: "A", to: "B") }
        check(log.records.count == OperationLog.maxRecords, "the log never grows beyond \(OperationLog.maxRecords): \(log.records.count)")
        log.clear()
        check(log.records.isEmpty, "Clear Log empties it")

        // --- Back history
        let model = ListerModel(url: dirA)
        for name in ["d1", "d2", "d3"] {
            try? fm.createDirectory(at: model.url.appendingPathComponent(name), withIntermediateDirectories: true)
            model.navigate(to: model.url.appendingPathComponent(name))
        }
        check(model.backHistory.map(\.lastPathComponent) == ["d2", "d1", "A"], "Back history, nearest first: \(model.backHistory.map(\.lastPathComponent))")
        model.goBack(steps: 2)
        check(model.url.lastPathComponent == "d1" && model.backHistory.map(\.lastPathComponent) == ["A"], "jumping two steps back lands on d1: \(model.url.lastPathComponent)")
        model.goBack(steps: 9)
        check(model.url.lastPathComponent == "d1", "a step count beyond the history is ignored")
        check(PathBarView.historyTitle(dirB).hasPrefix("B — "), "menu titles name the folder and its path: \(PathBarView.historyTitle(dirB))")

        // --- settings window
        let tabs = SettingsWindow.tabViews()
        check(tabs.map(\.title) == ["General", "Listers", "Folder Tree", "Tabs", "Workspaces", "Buttons", "Filetypes", "Operations", "Updates"] && tabs.count == 9, "the settings window has nine tabs: \(tabs.map(\.title))")
        // --- button bar pages: what does not fit goes to the next page (flip button)
        let row: [CGRect] = (0..<10).map { CGRect(x: CGFloat($0) * 36, y: 0, width: 34, height: 30) }       // ten buttons, 36 apart
        check(ButtonPaging.pages(frames: row, separators: [], barWidth: 600) == [0...9], "button bar: ten buttons that fit are one page")
        check(ButtonPaging.pages(frames: row, separators: [], barWidth: 0).isEmpty, "button bar: no width known, no pages")
        let narrow = ButtonPaging.pages(frames: row, separators: [], barWidth: 220)
        check(narrow.count > 1 && narrow.first?.lowerBound == 0 && narrow.last?.upperBound == 9
              && zip(narrow, narrow.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound }, "button bar: a narrow bar splits the buttons into consecutive pages: \(narrow)")
        check(narrow.allSatisfy { page in row[page.upperBound].maxX - row[page.lowerBound].minX <= 220 - ButtonPaging.flipWidth - 2 * ButtonPaging.padding },
              "button bar: every page leaves room for the flip button")
        let divided = ButtonPaging.pages(frames: row, separators: [3, 4], barWidth: 160)
        check(divided.allSatisfy { ![3, 4].contains($0.lowerBound) && ![3, 4].contains($0.upperBound) || $0.count == 1 }, "button bar: a page neither starts nor ends with a divider: \(divided)")
        check(ButtonPaging.pages(frames: row, separators: [], barWidth: 60).count == 10, "button bar: a bar that holds one button at a time still shows every button")
        let screenHeight = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800
        for tab in tabs {
            let host = NSHostingView(rootView: tab.view)
            check(host.fittingSize.width >= 400 && host.fittingSize.height > 100, "the \(tab.title) tab lays out: \(host.fittingSize)")
            check(host.fittingSize.height <= 700, "the \(tab.title) tab is short enough for a small screen: \(host.fittingSize.height) (\(screenHeight) visible)")
        }
        SettingsWindow.show(tab: 1)
        check(NSApp.windows.contains { $0.isVisible && ($0.contentViewController is SettingsSplitController) }, "Settings… opens a window with sidebar sections")
        if let window = NSApp.windows.first(where: { $0.contentViewController is SettingsSplitController }),
           let controller = window.contentViewController as? SettingsSplitController {
            check(controller.splitViewItems.count == 2 && controller.selectedIndex == 1, "sidebar split layout, second section selected")
            check(window.title == tabs[1].title, "the title names the tab: \(window.title)")
            window.close()
        }
        check(Settings.dragSelectFromNames == UserDefaults.standard.bool(forKey: "dragSelectFromNames"), "settings read the same defaults the views write")
        let before = Settings.buttonBarPosition
        UserDefaults.standard.set(ButtonBarPosition.bottom.rawValue, forKey: "buttonBarPosition")
        check(Settings.buttonBarPosition == .bottom, "the position picker's key is the one the app reads")
        UserDefaults.standard.set(before.rawValue, forKey: "buttonBarPosition")

        // --- the menu shows the shortcut the user assigned, not a fixed one
        if let delegate = NSApp.delegate as? AppDelegate {
            let item = NSMenuItem(title: "New Lister", action: nil, keyEquivalent: "n")
            ShortcutStore.shared.set(nil, for: GlobalShortcutActions.openLister)
            delegate.showAssignedShortcut(on: item, for: GlobalShortcutActions.openLister)
            check(item.keyEquivalent.isEmpty, "with no shortcut assigned the menu item shows none")
            let combo = KeyCombo(keyCode: 37, modifiers: [.control, .option, .shift, .command], label: "L")
            ShortcutStore.shared.set(combo, for: GlobalShortcutActions.openLister)
            delegate.showAssignedShortcut(on: item, for: GlobalShortcutActions.openLister)
            check(item.keyEquivalent == "l" && item.keyEquivalentModifierMask == [.control, .option, .shift, .command], "the menu item shows the assigned shortcut: \(item.keyEquivalent)")
            ShortcutStore.shared.set(KeyCombo(keyCode: 96, modifiers: [.control, .option, .shift, .command], label: "F5"), for: GlobalShortcutActions.openLister)
            delegate.showAssignedShortcut(on: item, for: GlobalShortcutActions.openLister)
            check(item.keyEquivalent.isEmpty, "a key a menu cannot show (F5) is left out")
            ShortcutStore.shared.set(nil, for: GlobalShortcutActions.openLister)
        } else {
            check(false, "app delegate reachable")
        }

        // --- sorting folders and files together
        let sortDir = root.appendingPathComponent("S")
        for folder in ["b_dir", "d_dir"] { try? fm.createDirectory(at: sortDir.appendingPathComponent(folder), withIntermediateDirectories: true) }
        write("a.txt", "x", in: sortDir); write("c.txt", "xxxxxx", in: sortDir); write("e.txt", "xx", in: sortDir)
        let sortModel = ListerModel(url: sortDir)
        func order(_ first: Bool, _ key: ListerModel.SortKey = .name, ascending: Bool = true) -> [String] {
            ListerModel.sorted(sortModel.items, by: key, ascending: ascending, foldersFirst: first).map(\.name)
        }
        check(order(true) == ["b_dir", "d_dir", "a.txt", "c.txt", "e.txt"], "folders first (the default): \(order(true))")
        check(order(false) == ["a.txt", "b_dir", "c.txt", "d_dir", "e.txt"], "folders and files sorted together by name: \(order(false))")
        check(order(false, .name, ascending: false) == ["e.txt", "d_dir", "c.txt", "b_dir", "a.txt"], "and in reverse: \(order(false, .name, ascending: false))")
        check(order(true, .size, ascending: false).prefix(2).allSatisfy { $0.hasSuffix("_dir") }, "folders stay on top when sorting by size")
        check(order(false, .size, ascending: false).first == "c.txt", "mixed by size, the biggest file leads: \(order(false, .size, ascending: false))")
        UserDefaults.standard.set(false, forKey: "foldersFirst")
        sortModel.reload()
        check(sortModel.items.map(\.name) == ["a.txt", "b_dir", "c.txt", "d_dir", "e.txt"], "the setting changes the lister's own order: \(sortModel.items.map(\.name))")
        UserDefaults.standard.set(true, forKey: "foldersFirst")
        sortModel.reload()
        check(sortModel.items.map(\.name).prefix(2) == ["b_dir", "d_dir"], "and back")

        // --- regressions from the code review
        // the size filter must not trap on absurd input
        check(SelectByAttributesView.bytes(1e30, unit: 2) == Int64.max, "size filter: a huge number is clamped")
        check(SelectByAttributesView.bytes(.infinity, unit: 0) == Int64.max, "size filter: infinity is clamped")
        check(SelectByAttributesView.bytes(.nan, unit: 1) == 0 && SelectByAttributesView.bytes(-5, unit: 1) == 0, "size filter: NaN and negatives give 0")
        check(SelectByAttributesView.bytes(1.5, unit: 0) == 1_500, "size filter: normal values are exact")

        // a folder that cannot be read is neither moved nor removed (merge: no atomic rename)
        let locked = dirA.appendingPathComponent("opstest_locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        write("inside.txt", "keep me", in: locked)
        try? fm.createDirectory(at: dirB.appendingPathComponent("opstest_locked"), withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let lockedResult = transfer(.move, ["opstest_locked"], action: .merge)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        check(!lockedResult.failures.isEmpty, "move: an unreadable folder is reported as a failure")
        check(exists(locked.appendingPathComponent("inside.txt")), "move: an unreadable folder stays where it was")
        try? fm.removeItem(at: locked)
        try? fm.removeItem(at: dirB.appendingPathComponent("opstest_locked"))

        // a quick second ⌘Z must not take the same operation back again
        write("opstest_double.txt", "x", in: dirA)
        _ = transfer(.copy, ["opstest_double.txt"])
        var secondUndo: UndoOutcome? = UndoOutcome()
        log.undoLast { _ in }
        log.undoLast { secondUndo = $0 }
        check(secondUndo == nil && log.isUndoing, "undo: a second call while one runs is refused")
        doubleUndoCopy = dirB.appendingPathComponent("opstest_double.txt")     // checked in finish(): the main queue is busy with this very function

        // the same new name in two different folders is no duplicate
        let folderOne = dirA.appendingPathComponent("r1"), folderTwo = dirA.appendingPathComponent("r2")
        for folder in [folderOne, folderTwo] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        write("a.txt", "1", in: folderOne); write("a.txt", "2", in: folderTwo)
        var renameOptions = BatchRenameOptions(); renameOptions.find = "a"; renameOptions.replace = "same"
        let crossFolder = BatchRename.plan(for: [folderOne.appendingPathComponent("a.txt"), folderTwo.appendingPathComponent("a.txt")], options: renameOptions)
        check(crossFolder.allSatisfy { $0.problem == nil }, "rename: equal new names in different folders are fine")
        try? fm.removeItem(at: folderOne); try? fm.removeItem(at: folderTwo)

        // --- title format
        var ctx = TitleFormat.Context()
        ctx.name = "Reports"; ctx.items = "11 items"; ctx.diskSummary = "340 GB free"; ctx.folders = "3"; ctx.files = "8"; ctx.selected = "2"
        check(TitleFormat.render(TitleFormat.defaultTitle, ctx) == "Reports", "default title without a label: \(TitleFormat.render(TitleFormat.defaultTitle, ctx))")
        ctx.label = "Work"
        check(TitleFormat.render(TitleFormat.defaultTitle, ctx) == "Work — Reports", "default title with a label: \(TitleFormat.render(TitleFormat.defaultTitle, ctx))")
        check(TitleFormat.render(TitleFormat.defaultSubtitle, ctx) == "11 items · 340 GB free", "default subtitle drops the empty role: \(TitleFormat.render(TitleFormat.defaultSubtitle, ctx))")
        ctx.roleLong = "SOURCE"; ctx.server = "nas"
        check(TitleFormat.render("%c{ · %F}{ · %R}", ctx) == "11 items · 340 GB free · SOURCE", "optional parts appear when they have a value")
        check(TitleFormat.render("%d folders, %f files, %s selected", ctx) == "3 folders, 8 files, 2 selected", "number variables")
        check(TitleFormat.render("100%% of %n", ctx) == "100% of Reports" && TitleFormat.render("%{%n%}", ctx) == "{Reports}", "%% and %{ %} are literals")
        check(TitleFormat.render("%q %n", ctx) == "%q Reports", "an unknown variable stays visible")
        check(TitleFormat.render("{open %n", ctx) == "{open Reports", "an unclosed { is plain text")
        check(TitleFormat.render("{%S}%n", ctx) == "Reports", "a group with an empty variable disappears")
        check(TitleFormat.variables.allSatisfy { !$0.help.isEmpty } && TitleFormat.presets.count >= 3, "variables and presets are documented")
        let titleModel = ListerModel(url: dirA)
        let titleContext = TitleFormat.context(for: titleModel)
        check(titleContext.name == "A" && titleContext.path == titleModel.url.path && titleContext.items.contains("item") || titleContext.items.contains("element"), "context from a lister: \(titleContext.name) / \(titleContext.items)")
        let remoteContext = TitleFormat.context(for: { let m = ListerModel(url: dirA); return m }())
        check(!remoteContext.files.isEmpty && !remoteContext.folders.isEmpty, "file and folder counts")
        let alignmentBefore = TitleFormat.alignment
        TitleFormat.alignment = .left
        check(TitleFormat.alignment == .left, "title alignment persists .left")
        TitleFormat.alignment = .right
        check(TitleFormat.alignment == .right, "title alignment persists .right")
        TitleFormat.alignment = .center
        check(TitleFormat.alignment == .center, "title alignment persists .center")
        TitleFormat.alignment = alignmentBefore
        let subtitleBefore = TitleFormat.subtitle
        TitleFormat.subtitle = ""
        check(TitleFormat.subtitle == "", "title subtitle can be cleared to empty")
        TitleFormat.subtitle = TitleFormat.defaultSubtitle
        check(TitleFormat.subtitle == TitleFormat.defaultSubtitle, "resetting subtitle restores default")
        TitleFormat.subtitle = subtitleBefore

        // --- button clicks
        var sample = ListerButton(title: "Copy", symbol: "doc", action: .copy)
        check(!sample.hasExtraClicks && sample.variant(for: .right) == nil && sample.variant(for: .left)?.action == .copy, "a plain button has only a left click")
        sample.rightAction = .move; sample.middleAction = .shell; sample.middleCommand = "open \"$LISTER_DIR\""
        check(sample.variant(for: .right)?.action == .move && sample.variant(for: .middle)?.command == "open \"$LISTER_DIR\"", "right and middle clicks have their own actions")
        check(sample.hasExtraClicks && sample.clickHelp.contains("·"), "the tooltip lists them: \(sample.clickHelp)")
        sample.rightAction = .separator
        check(sample.variant(for: .right) == nil, "a separator is not an action")
        let encoded = try? JSONEncoder().encode([sample])
        let decoded = encoded.flatMap { try? JSONDecoder().decode([ListerButton].self, from: $0) }
        check(decoded == [sample], "click actions survive buttons.json")
        let oldJSON = Data(#"[{"title":"Info","action":"info","symbol":"info.circle"}]"#.utf8)
        check((try? JSONDecoder().decode([ListerButton].self, from: oldJSON))?.first?.hasExtraClicks == false, "an old buttons.json still loads")

        // --- listers: Tab, drag-select
        let manager = ListerManager.shared
        let listDir = root.appendingPathComponent("L")
        try? fm.createDirectory(at: listDir, withIntermediateDirectories: true)
        for i in 1...8 { write("f\(i).txt", String(repeating: "x", count: i), in: listDir) }
        let one = manager.openLister(directory: listDir, anchor: .cursor(NSPoint(x: 200, y: 600), centered: false))
        let two = manager.openLister(directory: dirB, anchor: .cursor(NSPoint(x: 900, y: 600), centered: false))
        let three = manager.openLister(directory: dirA, anchor: .cursor(NSPoint(x: 500, y: 400), centered: false))
        check(manager.neighbour(of: one, forward: true) === two && manager.neighbour(of: three, forward: true) === one, "Tab goes to the next lister and wraps around")
        check(manager.neighbour(of: one, forward: false) === three && manager.neighbour(of: two, forward: false) === one, "Shift-Tab goes the other way")

        guard let vc = one.listerViewController else { check(false, "view controller"); finish(root, log); return }
        let table = vc.tableView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            one.window?.contentView?.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: one.window?.windowNumber ?? 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            }
            check(table.keyHandler?(key(48)!) == true, "the Tab key is handled by the lister")
            check(table.keyHandler?(key(48, .shift)!) == true, "Shift-Tab too")

            // where a press goes
            let rowRect = table.rect(ofRow: 1)
            let sizeColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
            let nameColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            let sizePoint = NSPoint(x: table.rect(ofColumn: sizeColumn).midX, y: rowRect.midY)
            let namePoint = NSPoint(x: table.rect(ofColumn: nameColumn).minX + 40, y: rowRect.midY)
            let farRightOfName = NSPoint(x: table.rect(ofColumn: nameColumn).maxX - 10, y: rowRect.midY)
            let below = NSPoint(x: 100, y: table.bounds.maxY - 3)
            table.lassoFromNames = { true }
            table.deselectAll(nil)
            check(table.startsLasso(at: sizePoint), "a press on the size column starts a drag-selection")
            check(table.startsLasso(at: farRightOfName), "a press on the blank part of the name column does too")
            check(table.startsLasso(at: below) && table.row(at: below) == -1, "and so does a press below the rows")
            check(table.startsLasso(at: namePoint), "a press on an unselected name starts one when drag-select from names is on")
            table.selectRowIndexes([1], byExtendingSelection: false)
            check(!table.startsLasso(at: namePoint), "but a selected file is dragged as a file")
            check(!table.startsLasso(at: sizePoint) && !table.startsLasso(at: farRightOfName), "and so is a press anywhere else on a selected row")
            table.lassoFromNames = { false }
            table.deselectAll(nil)
            check(!table.startsLasso(at: namePoint) && table.startsLasso(at: sizePoint), "with the option off a name press drags the file")
            table.lassoFromNames = { true }

            // the rectangle itself
            table.applyLasso(from: NSPoint(x: 100, y: table.rect(ofRow: 2).midY), to: NSPoint(x: 140, y: table.rect(ofRow: 5).midY), extending: nil)
            check(table.selectedRowIndexes == IndexSet(2...5), "dragging selects the rows it passes over: \(Array(table.selectedRowIndexes))")
            table.applyLasso(from: NSPoint(x: 100, y: table.rect(ofRow: 7).midY), to: NSPoint(x: 100, y: table.rect(ofRow: 6).midY), extending: IndexSet([0]))
            check(table.selectedRowIndexes == IndexSet([0, 6, 7]), "⌘/⇧ adds to the selection: \(Array(table.selectedRowIndexes))")
            table.applyLasso(from: NSPoint(x: 100, y: table.bounds.maxY - 2), to: NSPoint(x: 100, y: table.bounds.maxY - 40), extending: nil)
            check(table.selectedRowIndexes.isEmpty || table.selectedRowIndexes.allSatisfy { $0 >= 6 }, "dragging in the empty area selects nothing new: \(Array(table.selectedRowIndexes))")

            // a real press-drag-release
            table.deselectAll(nil)
            func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: one.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let startPoint = NSPoint(x: sizePoint.x, y: table.rect(ofRow: 1).midY)
            let down = mouse(.leftMouseDown, at: startPoint)
            NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: startPoint.x, y: table.rect(ofRow: 3).midY)), atStart: false)
            NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: startPoint.x, y: table.rect(ofRow: 4).midY)), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, at: NSPoint(x: startPoint.x, y: table.rect(ofRow: 4).midY)), atStart: false)
            table.mouseDown(with: down)
            check(table.selectedRowIndexes == IndexSet(1...4), "press, drag and release selects the rows in between: \(Array(table.selectedRowIndexes))")
            table.deselectAll(nil)
            let click = mouse(.leftMouseDown, at: startPoint)
            NSApp.postEvent(mouse(.leftMouseUp, at: startPoint), atStart: false)
            table.mouseDown(with: click)
            check(table.selectedRowIndexes == IndexSet([1]), "a plain click on the blank part of a row selects that row: \(Array(table.selectedRowIndexes))")

            // ⌘Z reaches undo
            check(table.keyHandler?(key(6, .command, "z")!) == true, "⌘Z is handled by the lister")

            // --- Dock icon and its menu
            if let delegate = NSApp.delegate as? AppDelegate {
                let dock = delegate.makeDockMenu()
                let dockTitles = dock.items.map(\.title)
                check(manager.allControllers.allSatisfy { dockTitles.contains($0.menuTitle) }, "the Dock menu lists every open lister: \(dockTitles.prefix(4))")
                check(["New Lister", "Duplicate Frontmost Lister", "Connect to Server…", "Bring All to Front", "Close All Listers", "Operation Log…", "Settings…"].allSatisfy(dockTitles.contains), "the Dock menu has the common commands")
                check(dock.items.first { $0.title.hasPrefix("Undo") }?.isEnabled == false, "Undo is disabled in the Dock menu when there is nothing to undo")
                if case .cascade = delegate.dockAnchor() { check(true, "a lister opened from the Dock goes beside the frontmost one") } else { check(false, "dock anchor with a lister open") }
                check(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) == false && manager.openCount == 3, "clicking the Dock icon with listers open opens nothing new")
                let before = Settings.showDockIcon
                UserDefaults.standard.set(false, forKey: "showDockIcon")
                delegate.applyDockIconPreference()
                check(NSApp.activationPolicy() == .accessory, "with the Dock icon off MacLister stays an agent")
                UserDefaults.standard.set(true, forKey: "showDockIcon")
                delegate.applyDockIconPreference()
                check(NSApp.activationPolicy() == .regular, "with the Dock icon on MacLister gets one")
                UserDefaults.standard.set(before, forKey: "showDockIcon")
                NSApp.setActivationPolicy(.accessory)                      // the test run itself stays an agent
            }

            // --- all listers on this desktop
            check(GlobalShortcutActions.all.contains { $0.id == GlobalShortcutActions.gatherListers }, "the move-to-this-desktop command can get a global shortcut")
            check(ListerAction.gatherListers.title == "Gather listers", "and is an action for buttons and keys")
            UserDefaults.standard.set(false, forKey: "listersOnAllDesktops")
            manager.gatherOnThisDesktop()
            check(manager.allControllers.allSatisfy { $0.window?.collectionBehavior.contains(.moveToActiveSpace) == true }, "gathering lets the listers join the desktop in view")
            check(manager.allControllers.allSatisfy { $0.window?.isVisible == true }, "and shows them")
            UserDefaults.standard.set(true, forKey: "listersOnAllDesktops")
            manager.applyDesktopBehavior()
            check(manager.allControllers.allSatisfy { $0.window?.collectionBehavior.contains(.canJoinAllSpaces) == true }, "the all-desktops setting puts every lister on every desktop")
            UserDefaults.standard.set(false, forKey: "listersOnAllDesktops")
            manager.applyDesktopBehavior()
            check(manager.allControllers.allSatisfy { $0.window?.collectionBehavior.isEmpty == true }, "turning it off returns them to their own desktop")

            // --- clearing history asks first
            PathHistory.shared.add(dirA); PathHistory.shared.add(dirB)
            var asked = 0
            let recentCount = PathHistory.shared.recent.count
            HistoryClearing.confirm = { _, _ in asked += 1; return false }
            check(HistoryClearing.confirmAndClear(.recentFolders) == false && recentCount >= 2 && PathHistory.shared.recent.count == recentCount && asked == 1, "declining keeps the recent folders")
            HistoryClearing.confirm = { _, _ in asked += 1; return true }
            check(HistoryClearing.confirmAndClear(.recentFolders) && PathHistory.shared.recent.isEmpty, "confirming clears the recent folders")
            check(HistoryClearing.confirmAndClear(.recentFolders) == false && asked == 2, "an empty list is not asked about")
            log.record(kind: .copy, items: [dirA], result: TransferResult(), from: "A", to: "B")
            HistoryClearing.confirm = { _, _ in false }
            check(HistoryClearing.confirmAndClear(.operationLog) == false && !log.records.isEmpty, "declining keeps the operation log")
            HistoryClearing.confirm = { _, _ in true }
            check(HistoryClearing.confirmAndClear(.operationLog) && log.records.isEmpty, "confirming clears the operation log")
            HistoryClearing.confirm = { title, detail in
                DebugLog.write("ops FAIL an unexpected confirmation was asked: \(title)"); return false
            }

            buttonClickChecks(one, realMouse: CommandLine.arguments.contains("--real-mouse")) {
                manager.closeAll()
                updateChecks(root, log)
            }
        }
    }

    /// Right and middle clicks on a real button, sent as system mouse events to the lister's window.
    /// By default the click is delivered straight to the button's mouse catcher, so the test never touches the real
    /// mouse. `--selftest-ops --real-mouse` also sends system mouse events (it moves the pointer and must not be
    /// disturbed; a click that misses can open a menu).
    private static func buttonClickChecks(_ controller: ListerWindowController, realMouse: Bool, done: @escaping () -> Void) {
        guard let window = controller.window, let table = controller.listerViewController?.tableView else { check(false, "window for click test"); done(); return }
        check(MouseButtonCatcher.CatcherView.accepts(.rightMouseDown) && MouseButtonCatcher.CatcherView.accepts(.otherMouseUp)
              && !MouseButtonCatcher.CatcherView.accepts(.leftMouseDown) && !MouseButtonCatcher.CatcherView.accepts(.mouseMoved),
              "the catcher answers only right and middle mouse events")
        ButtonStore.shared.save([ListerButton(title: "Probe", symbol: "star", action: .selectNone, rightAction: .selectAll, middleAction: .invertSelection)])
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            func find(_ view: NSView) -> NSView? {
                if String(describing: type(of: view)).contains("CatcherView") { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            guard let catcher = window.contentView.flatMap(find) else { check(false, "a button with extra clicks gets a mouse catcher"); done(); return }
            check(true, "a button with extra clicks gets a mouse catcher")
            if !realMouse {
                guard let view = catcher as? MouseButtonCatcher.CatcherView else { done(); return }
                table.deselectAll(nil)
                view.onClick(.right)
                check(table.selectedRowIndexes.count == table.numberOfRows && table.numberOfRows > 0, "the right-click action runs (Select All): \(table.selectedRowIndexes.count) of \(table.numberOfRows)")
                view.onClick(.middle)
                check(table.selectedRowIndexes.isEmpty, "the middle-click action runs (Invert Selection)")
                done()
                return
            }
            let inWindow = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
            let onScreen = window.convertPoint(toScreen: inWindow)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let position = CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
            func click(_ down: CGEventType, _ up: CGEventType, _ button: CGMouseButton) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: position, mouseButton: button)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: position, mouseButton: button)?.post(tap: .cghidEventTap)
            }
            table.deselectAll(nil)
            click(.rightMouseDown, .rightMouseUp, .right)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                check(table.selectedRowIndexes.count == table.numberOfRows && table.numberOfRows > 0, "a right click runs the right-click action (Select All): \(table.selectedRowIndexes.count) of \(table.numberOfRows)")
                click(.otherMouseDown, .otherMouseUp, .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    check(table.selectedRowIndexes.isEmpty, "a middle click runs the middle-click action (Invert Selection): \(table.selectedRowIndexes.count)")
                    click(.leftMouseDown, .leftMouseUp, .left)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        check(table.selectedRowIndexes.isEmpty, "a left click still runs the button's own action (Select None)")
                        done()
                    }
                }
            }
        }
    }

    // MARK: Updates

    /// `--selftest-update <feed>`: checks the feed, downloads the release and replaces this very app with it
    /// (the real install path, without the questions), then quits so the helper can start the new copy.
    static func updateInstall(feed: URL) {
        UpdateChecker.check(feed: feed) { result in
            switch result {
            case .failure(let error):
                DebugLog.write("update-install FAIL check: \(error.localizedDescription)")
                NSApp.terminate(nil)
            case .success(nil):
                DebugLog.write("update-install FAIL nothing newer in the feed")
                NSApp.terminate(nil)
            case .success(let release?):
                DebugLog.write("update-install found \(release.version), replaceable: \(UpdateChecker.canReplaceRunningApp)")
                DispatchQueue.global().async {
                    do {
                        let app = try UpdateChecker.download(release)
                        DispatchQueue.main.async {
                            do {
                                try UpdateChecker.installAfterQuit(app)
                                DebugLog.write("update-install quitting for the swap")
                            } catch { DebugLog.write("update-install FAIL install: \(error)") }
                            NSApp.terminate(nil)
                        }
                    } catch {
                        DebugLog.write("update-install FAIL download: \(error)")
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    private static func updateChecks(_ root: URL, _ log: OperationLog) {
        let fm = FileManager.default
        check(UpdateChecker.isNewer("1.10.0", than: "1.9.2") && UpdateChecker.isNewer("v2.0", than: "1.9.9") && !UpdateChecker.isNewer("1.2.0", than: "1.2.0") && !UpdateChecker.isNewer("1.2", than: "1.2.1"), "version comparison")
        let feedFile = root.appendingPathComponent("latest.json")
        func writeFeed(tag: String, zip: URL?, sum: URL?) {
            var assets: [[String: String]] = []
            if let zip { assets.append(["name": zip.lastPathComponent, "browser_download_url": zip.absoluteString]) }
            if let sum { assets.append(["name": sum.lastPathComponent, "browser_download_url": sum.absoluteString]) }
            let json: [String: Any] = ["tag_name": tag, "html_url": "https://example.org/release", "body": "Notes here", "assets": assets]
            try? JSONSerialization.data(withJSONObject: json).write(to: feedFile)
        }

        // a fake newer release: a tiny signed app in a zip with its checksum
        let version = "99.1.0"
        let app = root.appendingPathComponent("pack/MacLister.app")
        try? fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": Bundle.main.bundleIdentifier ?? "com.example.MacLister", "CFBundleExecutable": "MacLister",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL", "CFBundleName": "MacLister"]
        plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try? fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/MacLister"))
        func tool(_ path: String, _ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
        }
        let signed = tool("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let zip = root.appendingPathComponent("MacLister-\(version)-macos.zip")
        let zipped = tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        let sum = root.appendingPathComponent("MacLister-\(version)-macos.zip.sha256")
        let hash = UpdateChecker.sha256(of: zip) ?? ""
        try? "\(hash)  \(zip.lastPathComponent)\n".write(to: sum, atomically: true, encoding: .utf8)
        check(signed && zipped && hash.count == 64, "test package built")

        writeFeed(tag: "v\(version)", zip: zip, sum: sum)
        UpdateChecker.check(feed: feedFile) { result in
            guard case .success(let release?) = result else { check(false, "a newer release is reported: \(result)"); finish(root, log); return }
            check(release.version == version && release.notes == "Notes here" && release.zipURL == zip && release.checksumURL == sum, "the release feed is read")
            do {
                let downloaded = try UpdateChecker.download(release)
                check(fm.fileExists(atPath: downloaded.appendingPathComponent("Contents/Info.plist").path), "the package downloads, verifies and unpacks")
                try? fm.removeItem(at: downloaded.deletingLastPathComponent().deletingLastPathComponent())
            } catch { check(false, "download: \(error)") }

            // a wrong checksum is refused
            try? "deadbeef  x.zip".write(to: sum, atomically: true, encoding: .utf8)
            do { _ = try UpdateChecker.download(release); check(false, "a wrong checksum is refused") }
            catch { check((error as? UpdateError).map { if case .checksum = $0 { return true } else { return false } } == true, "a wrong checksum is refused: \(error.localizedDescription)") }

            // up to date and a broken feed
            writeFeed(tag: "v0.0.1", zip: nil, sum: nil)
            UpdateChecker.check(feed: feedFile) { second in
                if case .success(nil) = second { check(true, "an older release means up to date") } else { check(false, "an older release means up to date: \(second)") }
                try? Data("not json".utf8).write(to: feedFile)
                UpdateChecker.check(feed: feedFile) { third in
                    if case .failure = third { check(true, "a broken feed is an error, not a crash") } else { check(false, "a broken feed is an error") }
                    UpdateChecker.check(feed: root.appendingPathComponent("missing.json")) { fourth in
                        if case .failure = fourth { check(true, "an unreachable feed is an error") } else { check(false, "an unreachable feed is an error") }
                        check(Settings.autoUpdateCheck == false || UserDefaults.standard.object(forKey: "autoUpdateCheck") != nil, "automatic checks are off unless the user chose them")
                        finish(root, log)
                    }
                }
            }
        }
    }

    private static func finish(_ root: URL, _ log: OperationLog) {
        if let copy = doubleUndoCopy {
            check(!log.isUndoing && !FileManager.default.fileExists(atPath: copy.path), "undo: the first of two quick calls finishes and takes the copy back")
        }
        log.clear()
        AppSupport.override = nil
        try? FileManager.default.removeItem(at: root)
        // the tests trash a few files; do not leave them in the user's Trash
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for item in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] where item.hasPrefix("opstest_") {
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(item))
        }
        DebugLog.write("ops \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }
}
