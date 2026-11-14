import AppKit

/// `MacLister --selftest-ops`: undo, the operation log, the Back history, drag-select, Tab between listers
/// and the update check. Results go to ~/Library/Logs/MacLister.log.
enum SelfTestOperations {
    private static var failures = 0

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
            check(table.startsLasso(at: sizePoint), "a press on the size column starts a selection rectangle")
            check(table.startsLasso(at: farRightOfName), "a press on the blank part of the name column does too")
            check(table.startsLasso(at: below) && table.row(at: below) == -1, "and so does a press below the rows")
            check(table.startsLasso(at: namePoint), "a press on an unselected name starts one when drag-select from names is on")
            table.selectRowIndexes([1], byExtendingSelection: false)
            check(!table.startsLasso(at: namePoint), "but a selected file is dragged as a file")
            table.lassoFromNames = { false }
            table.deselectAll(nil)
            check(!table.startsLasso(at: namePoint) && table.startsLasso(at: sizePoint), "with the option off a name press drags the file")
            table.lassoFromNames = { true }

            // the rectangle itself
            table.applyLasso(from: NSPoint(x: 100, y: table.rect(ofRow: 2).midY), to: NSPoint(x: 140, y: table.rect(ofRow: 5).midY), extending: nil)
            check(table.selectedRowIndexes == IndexSet(2...5), "the rectangle selects the rows it touches: \(Array(table.selectedRowIndexes))")
            table.applyLasso(from: NSPoint(x: 100, y: table.rect(ofRow: 7).midY), to: NSPoint(x: 100, y: table.rect(ofRow: 6).midY), extending: IndexSet([0]))
            check(table.selectedRowIndexes == IndexSet([0, 6, 7]), "⌘/⇧ adds to the selection: \(Array(table.selectedRowIndexes))")
            table.applyLasso(from: NSPoint(x: 100, y: table.bounds.maxY - 2), to: NSPoint(x: 100, y: table.bounds.maxY - 40), extending: nil)
            check(table.selectedRowIndexes.isEmpty || table.selectedRowIndexes.allSatisfy { $0 >= 6 }, "a rectangle in the empty area selects nothing new: \(Array(table.selectedRowIndexes))")

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

            buttonClickChecks(one) {
                manager.closeAll()
                updateChecks(root, log)
            }
        }
    }

    /// Right and middle clicks on a real button, sent as system mouse events to the lister's window.
    private static func buttonClickChecks(_ controller: ListerWindowController, done: @escaping () -> Void) {
        guard let window = controller.window, let table = controller.listerViewController?.tableView else { check(false, "window for click test"); done(); return }
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
