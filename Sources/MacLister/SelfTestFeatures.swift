import AppKit

/// `MacLister --selftest-features`: exercises the Directory-Opus-style features through the same
/// code the buttons and menus call. Results go to ~/Library/Logs/MacLister.log. Uses a temp
/// Application Support folder so the user's bookmarks, filetypes and layout stay untouched.
enum SelfTestFeatures {
    private static var failures = 0
    private static var steps: [(delay: Double, run: () -> Void)] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("features \(condition ? "ok  " : "FAIL") \(message)")
    }

    private static func later(_ delay: Double = 0.2, _ run: @escaping () -> Void) { steps.append((delay, run)) }

    private static func runSteps(_ done: @escaping () -> Void) {
        guard !steps.isEmpty else { done(); return }
        let step = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
            step.run()
            runSteps(done)
        }
    }

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-features-\(UUID().uuidString)")
        let support = root.appendingPathComponent("support")
        AppSupport.override = support
        let dirA = root.appendingPathComponent("A"), dirB = root.appendingPathComponent("B")
        for dir in [support, dirA.appendingPathComponent("big"), dirB] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func write(_ name: String, _ bytes: Int, in dir: URL) {
            try? Data(repeating: 0x41, count: bytes).write(to: dir.appendingPathComponent(name))
        }
        write("a.txt", 1, in: dirA); write("b.jpg", 10, in: dirA); write("c.png", 20, in: dirA)
        write("one.bin", 1000, in: dirA.appendingPathComponent("big")); write("two.bin", 500, in: dirA.appendingPathComponent("big"))
        write("a.txt", 5, in: dirB)                                   // differs in size
        try? fm.copyItem(at: dirA.appendingPathComponent("b.jpg"), to: dirB.appendingPathComponent("b.jpg"))  // identical
        write("z.txt", 3, in: dirB)                                   // only in B

        // --- pure helpers
        check(NamePattern.matches("Photo.JPG", text: "*.jpg"), "pattern is case-insensitive")
        check(!NamePattern.matches("notes.txt", text: "*.jpg"), "pattern rejects other extensions")
        check(NamePattern.matches("IMG_01.png", text: "IMG_??.png"), "? matches one character")
        check(NamePattern.matches("holiday.txt", text: "holi"), "text without wildcard matches as substring")
        check(NamePattern.matches("x.png", text: "*.jpg *.png"), "several patterns separated by spaces")
        check(!NamePattern.matches("x.png", text: ""), "empty pattern matches nothing")
        check(InfoText.permissionString(0o755) == "rwxr-xr-x" && InfoText.permissionString(0o644) == "rw-r--r--", "permission string")
        let info = InfoText.make(for: [dirA.appendingPathComponent("a.txt")])
        check(info.title == "a.txt" && info.body.contains("Permissions: rw") && info.body.contains("Kind:") && info.body.contains("1 bytes"), "info text for a file")
        let folderInfo = InfoText.make(for: [dirA.appendingPathComponent("big")]).body
        let sizeLine = folderInfo.split(separator: "\n").first { $0.hasPrefix("Size:") }.map(String.init) ?? ""
        check(sizeLine.filter(\.isNumber).hasSuffix("1500"), "info text sums a folder (\(sizeLine))")   // digits only: the thousands separator is locale-dependent
        check(FolderSize.total(of: dirA.appendingPathComponent("big")) == 1500, "folder size is recursive")

        let dup1 = FileTransfer.duplicate([dirA.appendingPathComponent("a.txt")])
        let dup2 = FileTransfer.duplicate([dirA.appendingPathComponent("a.txt")])
        let dup3 = FileTransfer.duplicate([dirA.appendingPathComponent("big")])
        check(dup1.done.first?.lastPathComponent == "a copy.txt" && dup2.done.first?.lastPathComponent == "a copy 2.txt", "duplicate names: 'a copy.txt', 'a copy 2.txt'")
        check(dup3.done.first?.lastPathComponent == "big copy" && fm.fileExists(atPath: dirA.appendingPathComponent("big copy/one.bin").path), "duplicate of a folder")
        for name in ["a copy.txt", "a copy 2.txt", "big copy"] { try? fm.removeItem(at: dirA.appendingPathComponent(name)) }

        // --- listers
        let manager = ListerManager.shared
        let one = manager.openLister(directory: dirA, anchor: .cursor(NSPoint(x: 200, y: 500), centered: false))
        let two = manager.openLister(directory: dirB, anchor: .cursor(NSPoint(x: 900, y: 500), centered: false))
        guard let vc = one.listerViewController else { check(false, "view controller reachable"); finish(root); return }
        func names(_ model: ListerModel) -> Set<String> { Set(model.items.map(\.name)) }
        func selectedNames(_ model: ListerModel) -> Set<String> { Set(model.selectedURLs.map(\.lastPathComponent)) }
        // Rows carry the model's own (standardized) URLs; /var vs /private/var would otherwise differ.
        func rowURL(_ name: String) -> URL { one.model.items.first { $0.name == name }?.url ?? dirA.appendingPathComponent(name) }

        // filter
        later {
            one.model.setFilter("*.jpg *.png")
            check(names(one.model) == ["b.jpg", "c.png", "big"], "filter keeps matching files and all folders: \(names(one.model))")
            one.model.setFilter("")
            check(names(one.model) == ["a.txt", "b.jpg", "c.png", "big"], "empty filter shows everything")
        }
        // pattern selection
        later {
            vc.applyPattern("*.png", select: true)
            check(selectedNames(one.model) == ["c.png"], "select by pattern: \(selectedNames(one.model))")
            vc.applyPattern("*.jpg", select: true)
            check(selectedNames(one.model) == ["c.png", "b.jpg"], "second pattern adds to the selection")
            vc.applyPattern("c.*", select: false)
            check(selectedNames(one.model) == ["b.jpg"], "deselect by pattern")
            vc.invertSelection()
            check(selectedNames(one.model) == ["a.txt", "c.png", "big"], "invert selection: \(selectedNames(one.model))")
            vc.selectNoRows()
            check(one.model.selectedURLs.isEmpty, "select none")
            vc.selectAllRows()
            check(one.model.selectedURLs.count == 4, "select all")
            vc.select(urls: [rowURL("a.txt"), rowURL("b.jpg")])
            check(one.model.selectedBytes == 11, "selected size sums the file sizes (\(one.model.selectedBytes))")
        }
        // folder sizes
        later {
            vc.selectNoRows()
            vc.calculateFolderSizes()
        }
        later(1.0) {
            check(one.model.items.first(where: { $0.name == "big" })?.size == 1500, "calculated folder size shows in the item: \(String(describing: one.model.items.first(where: { $0.name == "big" })?.size))")
            one.model.reload()
            check(one.model.items.first(where: { $0.name == "big" })?.size == 1500, "size survives a reload")
        }
        // compare
        later {
            manager.toggleRole(.source, for: one)
            manager.toggleRole(.destination, for: two)
            vc.compareWithDestination()
            check(selectedNames(one.model) == ["a.txt", "c.png", "big"], "compare selects differences in source: \(selectedNames(one.model))")
            check(selectedNames(two.model) == ["a.txt", "z.txt"], "compare selects differences in destination: \(selectedNames(two.model))")
        }
        // show in destination / destination here
        later {
            vc.select(urls: [rowURL("big")])
            vc.showInDestination()
            check(two.model.url.lastPathComponent == "big", "open selected folder in destination")
            vc.destinationHere()
            check(two.model.url.standardizedFileURL == one.model.url.standardizedFileURL, "destination shows the source folder")
            two.model.navigate(to: dirB)
        }
        // duplicate lister
        later {
            one.model.apply(sort: .size, ascending: false, showHidden: true, filter: "*.txt")
            one.model.reload()
            let before = manager.openCount
            let copy = manager.duplicate(one)
            check(manager.openCount == before + 1 && copy !== one, "duplicate opens one more lister")
            check(copy.model.url == one.model.url, "duplicate shows the same path")
            check(copy.model.sortKey == .size && copy.model.ascending == false && copy.model.showHidden && copy.model.filter == "*.txt", "duplicate inherits sort, hidden and filter")
            check(names(copy.model) == names(one.model), "duplicate lists the same items")
            check(copy.model.role == .none, "duplicate has no source/destination role")
            copy.close()
            one.model.apply(sort: .name, ascending: true, showHidden: false, filter: "")
            one.model.reload()
        }
        // drag and drop rules + drop transfer
        later {
            let sub = dirA.appendingPathComponent("big")
            let a = rowURL("c.png")
            let both: NSDragOperation = [.copy, .move]
            typealias VC = ListerViewController
            check(VC.dragOperation(for: [a], into: dirA, modifiers: [], sourceMask: both) == [], "drop into the item's own folder is refused")
            check(VC.dragOperation(for: [rowURL("big")], into: sub.appendingPathComponent("x"), modifiers: [], sourceMask: both) == [], "drop of a folder into itself is refused")
            check(VC.dragOperation(for: [a], into: dirB, modifiers: [], sourceMask: both) == .move, "same volume → move")
            check(VC.dragOperation(for: [a], into: dirB, modifiers: [.option], sourceMask: both) == .copy, "⌥ forces copy")
            check(VC.dragOperation(for: [a], into: dirB, modifiers: [.command], sourceMask: both) == .move, "⌘ forces move")
            check(VC.dragOperation(for: [a], into: dirB, modifiers: [], sourceMask: .copy) == .copy, "source that only allows copy gets copy")
            two.model.navigate(to: dirB)
            two.listerViewController?.transfer(.copy, items: [a], into: dirB)
        }
        later(0.8) {
            check(fm.fileExists(atPath: dirB.appendingPathComponent("c.png").path) && fm.fileExists(atPath: dirA.appendingPathComponent("c.png").path), "dropped copy lands in the target and stays in the source")
            check(names(two.model).contains("c.png"), "target lister refreshed after the drop")
            two.listerViewController?.transfer(.move, items: [rowURL("big")], into: dirB)
        }
        later(0.8) {
            check(fm.fileExists(atPath: dirB.appendingPathComponent("big/one.bin").path) && !fm.fileExists(atPath: dirA.appendingPathComponent("big").path), "dropped move relocates the folder")
            check(!names(one.model).contains("big") && names(two.model).contains("big"), "both listers refreshed after the move")
        }
        // title-bar menu
        later {
            let menu = one.listerViewController?.makeTitleBarMenu()
            let titles = menu?.items.map(\.title) ?? []
            check(["Duplicate Lister", "New Lister", "Set as Source", "Set as Destination", "Swap Source and Destination",
                   "Parent", "Refresh", "Show Hidden Files", "Close Lister", "Close All Listers", "Save Layout"].allSatisfy(titles.contains),
                  "title-bar menu has the lister commands: \(titles.filter { !$0.isEmpty })")
            check(menu?.items.first { $0.title == "Set as Source" }?.state == .on, "title-bar menu shows the current role with a check mark")
            let countBefore = manager.openCount
            if let item = menu?.items.first(where: { $0.title == "Duplicate Lister" }),
               let action = item.representedObject {
                // run the menu item exactly as a click would
                (item.target as? ListerViewController)?.perform(item.action!, with: item)
                _ = action
            }
            check(manager.openCount == countBefore + 1, "choosing Duplicate Lister in the title-bar menu clones the lister")
            if let clone = manager.allControllers.last, clone !== one { clone.close() }

            if let window = one.window as? ListerWindow {
                let top = NSPoint(x: 100, y: window.frame.height - 8)
                check(window.isInTitleBar(top), "a point in the title bar is recognised")
                check(!window.isInTitleBar(NSPoint(x: 100, y: 100)), "a point in the content is not the title bar")
            } else { check(false, "lister window is a ListerWindow") }
        }
        // a synthetic right-click goes through sendEvent exactly like a real one
        later {
            guard let window = one.window as? ListerWindow else { check(false, "ListerWindow for the click test"); return }
            let original = window.titleBarMenuProvider
            var asked = 0
            var shown: NSMenu?
            window.titleBarMenuProvider = {
                asked += 1
                let menu = NSMenu()
                menu.addItem(NSMenuItem(title: "probe", action: nil, keyEquivalent: ""))
                shown = menu
                // popUpContextMenu blocks in its tracking loop: close it again shortly after it opens
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { menu.cancelTracking() }
                return menu
            }
            func rightClick(at point: NSPoint) {
                if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            rightClick(at: NSPoint(x: 100, y: 120))                       // inside the content
            check(asked == 0, "right-click in the content does not open the title-bar menu")
            rightClick(at: NSPoint(x: 100, y: window.frame.height - 8))   // on the title bar
            check(asked == 1 && shown != nil, "right-click on the title bar opens the lister menu (asked \(asked)x)")
            window.titleBarMenuProvider = original
        }
        // terminal choice
        later {
            let original = Settings.terminalBundleID
            let choices = appDelegate.terminalChoices()
            check(choices.contains { $0.id == "com.apple.Terminal" }, "Terminal.app is offered: \(choices.map(\.name))")
            if let other = choices.first(where: { $0.id != original }) {
                appDelegate.chooseTerminal(id: other.id)
                check(Settings.terminalBundleID == other.id, "choosing \(other.name) is stored as the terminal app")
            }
            appDelegate.chooseTerminal(id: original)
            check(Settings.terminalBundleID == original, "terminal choice restored")
            let titles = appDelegate.statusMenuTitles()
            check(titles.contains("Terminal App"), "status menu has the Terminal App submenu")
        }
        // bookmarks, history, filetypes
        later {
            BookmarkStore.shared.add(dirA)
            check(BookmarkStore.shared.contains(dirA) && fm.fileExists(atPath: support.appendingPathComponent("bookmarks.json").path), "bookmark added and saved")
            let bookmarkMenu = one.listerViewController?.makeTitleBarMenu().items.first { $0.title == "Bookmarks" }?.submenu
            check(bookmarkMenu?.items.map(\.title).contains(PathText.short(dirA.standardizedFileURL.path)) == true, "title-bar menu lists the bookmark: \(bookmarkMenu?.items.map(\.title) ?? [])")
            check(bookmarkMenu?.items.first { $0.title == "Remove This Folder" }?.isEnabled == true
                  && bookmarkMenu?.items.first { $0.title == "Add This Folder" }?.isEnabled == false,
                  "for a bookmarked folder the menu offers Remove, not Add")
            BookmarkStore.shared.remove(dirA.standardizedFileURL.path)
            check(!BookmarkStore.shared.contains(dirA), "bookmark removed")
            check(PathHistory.shared.recent.contains(dirB.standardizedFileURL.path), "navigation is recorded in the recent list")

            check(FiletypeStore.shared.rule(for: URL(fileURLWithPath: "/x/data.tar.gz"))?.action == .extract, "default filetype: tar.gz → extract")
            check(FiletypeStore.shared.rule(for: URL(fileURLWithPath: "/x/readme.txt")) == nil, "no rule for .txt by default")
            let custom = #"[{"extensions":["md"],"action":"quicklook"}]"#
            try? custom.write(to: FiletypeStore.shared.configURL, atomically: true, encoding: .utf8)
            check(FiletypeStore.shared.rule(for: URL(fileURLWithPath: "/x/n.MD"))?.action == .quicklook, "edited filetypes.json is picked up")
            check(FiletypeStore.shared.rule(for: URL(fileURLWithPath: "/x/a.zip")) == nil, "custom file replaces the defaults")
        }
        // layout
        later {
            let count = manager.openCount
            check(LayoutStore.save(from: manager) == count, "layout saves every open lister")
            let restored = LayoutStore.restore(into: manager)
            check(restored == count && manager.openCount == count * 2, "layout restores the same number of listers")
            check(manager.allControllers.suffix(restored).contains { $0.model.role == .source }, "layout restores the source role")
        }
        later(0.3) {
            manager.closeAll()
            finish(root)
        }
        runSteps { }
    }

    private static func finish(_ root: URL) {
        AppSupport.override = nil
        try? FileManager.default.removeItem(at: root)
        DebugLog.write("features \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }
}
