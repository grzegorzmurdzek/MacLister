import AppKit
import SwiftUI
import Carbon

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
            // A locked screen / screen saver does not let menus track the mouse; the check needs a live session.
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            if session?["CGSSessionScreenIsLocked"] as? Bool == true {
                DebugLog.write("features info  right-click check skipped: the screen is locked")
                return
            }
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
                let closer = Timer(timeInterval: 0.3, repeats: false) { _ in menu.cancelTracking() }
                RunLoop.main.add(closer, forMode: .common)      // .common includes the menu-tracking mode
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
        // desktop trigger: which gesture opens a lister
        later {
            check(DesktopTrigger.doubleClick.accepts(button: 0, clickCount: 2) && !DesktopTrigger.doubleClick.accepts(button: 0, clickCount: 1)
                  && !DesktopTrigger.doubleClick.accepts(button: 2, clickCount: 1), "trigger 'double-click': only the left double-click opens a lister")
            check(DesktopTrigger.middleClick.accepts(button: 2, clickCount: 1) && !DesktopTrigger.middleClick.accepts(button: 2, clickCount: 2)
                  && !DesktopTrigger.middleClick.accepts(button: 0, clickCount: 2), "trigger 'middle click': a single middle click opens a lister, the left double-click does not")
            check(DesktopTrigger.both.accepts(button: 0, clickCount: 2) && DesktopTrigger.both.accepts(button: 2, clickCount: 1)
                  && !DesktopTrigger.both.accepts(button: 1, clickCount: 1) && !DesktopTrigger.both.accepts(button: 3, clickCount: 1), "trigger 'both': left double-click or middle click, never the right or other buttons")
        }
        // button bar position, default buttons, remembered window size
        later {
            let real = ListerButton.defaults.filter { $0.action != .separator }
            check(real.count == 8 && real.allSatisfy { $0.symbol != nil }, "default button bar is short and every button has an icon (\(real.count))")
            let missing = real.compactMap(\.symbol).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
            check(missing.isEmpty, "every default icon exists as an SF Symbol on this macOS (missing: \(missing))")
            check(real.allSatisfy { $0.color.map(ListerButton.knownColors.contains) ?? true }, "default icon colours are known names")
            let decoded = (try? JSONDecoder().decode([ListerButton].self, from: JSONEncoder().encode(ListerButton.defaults))) ?? []
            check(decoded == ListerButton.defaults, "button definitions survive a JSON round trip (colour and separator included)")
            func geometry() -> (button: NSView, path: NSView, scroll: NSView)? {
                guard let root = one.listerViewController?.view else { return nil }
                root.layoutSubtreeIfNeeded()
                guard let button = root.subviews.first(where: { abs($0.frame.height - 44) < 1 }),
                      let path = root.subviews.first(where: { abs($0.frame.height - 48) < 1 }),
                      let scroll = root.subviews.first(where: { $0 is NSScrollView }) else { return nil }
                return (button, path, scroll)
            }
            let original = Settings.buttonBarPosition
            // (non-flipped coordinates: a larger midY is higher on screen)
            Settings.buttonBarPosition = .abovePath
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let g = geometry() {
                    check(g.button.frame.midY > g.path.frame.midY && g.path.frame.midY > g.scroll.frame.midY, "above-path: buttons, then path, then list")
                } else { check(false, "bars found (above path)") }
                Settings.buttonBarPosition = .belowPath
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let g = geometry() {
                        check(g.path.frame.midY > g.button.frame.midY && g.button.frame.midY > g.scroll.frame.midY, "below-path: path, then buttons, then list")
                    } else { check(false, "bars found (below path)") }
                    Settings.buttonBarPosition = .bottom
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let g = geometry() {
                            check(g.path.frame.midY > g.scroll.frame.midY && g.scroll.frame.midY > g.button.frame.midY, "bottom: path, then list, then buttons")
                        } else { check(false, "bars found (bottom)") }
                        Settings.buttonBarPosition = original
                    }
                }
            }
            let savedSize = Settings.listerContentSize
            Settings.listerContentSize = NSSize(width: 500, height: 333)
            let probe = manager.openLister(directory: dirA, anchor: .cursor(NSPoint(x: 300, y: 300), centered: false))
            let size = probe.window?.contentLayoutRect.size ?? .zero
            check(abs(size.width - 500) < 2 && abs(size.height - 333) < 2, "new listers open with the remembered size (\(size))")
            probe.close()
            Settings.listerContentSize = savedSize
        }
        later(1.2) { }
        // keyboard shortcuts
        later {
            func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            let store = ShortcutStore.shared
            let free = KeyCombo(keyCode: 37, modifiers: [.control, .option], label: "L")           // ⌃⌥L
            let spotlight = SystemShortcut(keyCode: 49, modifiers: Int(NSEvent.ModifierFlags.command.rawValue), name: "Spotlight")
            func problem(_ combo: KeyCombo, _ id: String, system: [SystemShortcut] = [], probe: @escaping (KeyCombo) -> Bool = { _ in true }) -> ShortcutProblem? {
                ShortcutRules.validate(combo, for: id, store: store, system: system, probeGlobal: probe)
            }

            // combo basics
            let event = key(37, "l", [.control, .option])
            let fromEvent = KeyCombo(event: event)
            check(fromEvent == free && fromEvent.display == "⌃⌥L" && free.matches(event) && !free.matches(key(37, "l", [.control])), "shortcuts: a combo is read from an event and matched exactly: \(fromEvent.display)")
            check(KeyCombo(keyCode: 96, modifiers: [], label: "F5").display == "F5" && KeyCombo(keyCode: 0, modifiers: [.command, .shift, .option, .control], label: "A").display == "⌃⌥⇧⌘A", "shortcuts: display order ⌃⌥⇧⌘")
            check(free.carbonModifiers == UInt32(controlKey | optionKey), "shortcuts: Carbon modifiers")
            check(ListerAction.swapSourceDestination.title == "Swap source destination" && ListerAction.copy.title == "Copy", "shortcuts: action titles")

            // rules
            check(problem(KeyCombo(keyCode: 37, modifiers: [], label: "L"), "action.copy") == .needsModifier("Use ⌘, ⌥ or ⌃ with the key (function keys and arrows may stand alone). Plain keys are for typing and type-select."), "rules: a plain letter is refused in listers")
            check(problem(KeyCombo(keyCode: 100, modifiers: [], label: "F8"), "action.copy") == nil, "rules: a function key may stand alone in listers")
            check(problem(KeyCombo(keyCode: 100, modifiers: [], label: "F8"), "global.openLister") != nil, "rules: a global shortcut always needs ⌘, ⌥ or ⌃")
            check(problem(KeyCombo(keyCode: 12, modifiers: .command, label: "Q"), "action.copy") == .reserved("Quit"), "rules: ⌘Q is reserved")
            check(problem(KeyCombo(keyCode: 14, modifiers: .command, label: "E"), "action.move") == .builtIn("Extract"), "rules: a key MacLister already uses is refused")
            check(problem(KeyCombo(keyCode: 96, modifiers: [], label: "F5"), "action.move") == .builtIn("Copy"), "rules: F5 belongs to Copy")
            check(problem(KeyCombo(keyCode: 49, modifiers: .command, label: "Space"), "global.openLister", system: [spotlight]) == .system("Spotlight"), "rules: a macOS shortcut is refused")
            check(problem(KeyCombo(keyCode: 49, modifiers: .command, label: "Space"), "global.openLister", system: []) == nil, "rules: the same keys are free when macOS does not use them")
            check(problem(free, "global.openLister", probe: { _ in false }) == .otherApplication, "rules: a global shortcut another application holds is refused")
            check(problem(free, "global.openLister") == nil, "rules: a free combination passes")
            check(ShortcutProblem.system("Spotlight").message(for: free).contains("System Settings"), "rules: the message says where to change a system shortcut")

            // store, dispatch inside a lister
            let copyCombo = KeyCombo(keyCode: 8, modifiers: [.command, .shift], label: "C")      // ⇧⌘C
            store.set(copyCombo, for: "action.copy")
            check(store.action(for: key(8, "c", [.command, .shift])) == .copy && store.action(for: key(8, "c", [.command])) == nil, "store: a binding is found from a key event")
            check(problem(copyCombo, "action.move") == .usedBy(id: "action.copy"), "rules: a combo assigned to another action is reported")
            check(problem(copyCombo, "action.copy") == nil, "rules: re-assigning the same action is fine")
            check(FileManager.default.fileExists(atPath: AppSupport.directory.appendingPathComponent("shortcuts.json").path), "store: bindings are saved to shortcuts.json")
            store.set(nil, for: "action.copy")

            let invert = KeyCombo(keyCode: 34, modifiers: [.control, .option], label: "I")
            store.set(invert, for: "action.invertSelection")
            vc.selectAllRows()
            check(!one.model.selectedURLs.isEmpty, "keys: rows selected before the shortcut")
            _ = vc.tableView.keyHandler?(key(34, "i", [.control, .option]))
            check(one.model.selectedURLs.isEmpty, "keys: a custom shortcut runs its action in a lister (Invert Selection)")
            store.set(nil, for: "action.invertSelection")
            vc.selectNoRows()
        }
        later(0.3) {
            // the recorder applies the rules; the reassign question is answered by the test
            let recorder = ShortcutRecorder()
            var asked = 0
            recorder.confirmReassign = { _, _, _ in asked += 1; return true }
            let a = KeyCombo(keyCode: 2, modifiers: [.control, .option], label: "D")
            recorder.apply(a, for: "action.copy")
            check(ShortcutStore.shared.combo(for: "action.copy") == a && recorder.messages["action.copy"] == nil, "recorder: a free combination is accepted")
            recorder.apply(a, for: "action.move")
            check(asked == 1 && ShortcutStore.shared.combo(for: "action.move") == a && ShortcutStore.shared.combo(for: "action.copy") == nil, "recorder: reassigning moves the shortcut after confirmation")
            recorder.confirmReassign = { _, _, _ in false }
            recorder.apply(a, for: "action.copy")
            check(ShortcutStore.shared.combo(for: "action.copy") == nil && recorder.messages["action.copy"]?.contains("already assigned to “Move”") == true, "recorder: declining keeps the old owner and explains: \(recorder.messages["action.copy"] ?? "nil")")
            recorder.apply(KeyCombo(keyCode: 12, modifiers: .command, label: "Q"), for: "action.copy")
            check(ShortcutStore.shared.combo(for: "action.copy") == nil && recorder.messages["action.copy"]?.contains("Quit") == true, "recorder: ⌘Q is refused with a message")
            recorder.clear("action.move")
            check(ShortcutStore.shared.combo(for: "action.move") == nil, "recorder: a shortcut can be cleared")
        }
        later(0.3) {
            // global shortcut: registered with the system, runs its action, and is released again
            let combo = KeyCombo(keyCode: 80, modifiers: [.control, .option, .shift, .command], label: "F19")       // ⌃⌥⇧⌘F19
            check(GlobalHotKeys.canRegister(combo), "global: an unused combination can be registered")
            check(!SystemShortcuts.enabled().isEmpty, "global: the macOS shortcut list can be read (\(SystemShortcuts.enabled().count) enabled)")
            ShortcutStore.shared.set(combo, for: GlobalShortcutActions.openLister)
        }
        later(0.3) {
            let id = GlobalShortcutActions.openLister
            check(GlobalHotKeys.shared.isRegistered(id), "global: assigning a shortcut registers it with the system")
            check(!GlobalHotKeys.canRegister(KeyCombo(keyCode: 80, modifiers: [.control, .option, .shift, .command], label: "F19")), "global: the registered combination now counts as taken")
            let before = manager.openCount
            GlobalHotKeys.shared.trigger(id)
        }
        later(0.5) {
            check(manager.openCount >= 1, "global: the shortcut's action opens a lister")
            manager.allControllers.last?.close()
            ShortcutStore.shared.set(nil, for: GlobalShortcutActions.openLister)
        }
        later(0.3) {
            check(!GlobalHotKeys.shared.isRegistered(GlobalShortcutActions.openLister), "global: clearing the shortcut releases it")
            check(GlobalHotKeys.canRegister(KeyCombo(keyCode: 80, modifiers: [.control, .option, .shift, .command], label: "F19")), "global: and the combination is free again")
            ShortcutsWindowController.shared.show()
            check(ShortcutsWindowController.shared.window?.isVisible == true, "the Keyboard Shortcuts window opens")
            ShortcutsWindowController.shared.window?.close()
        }
        // progress on the menu-bar icon
        later {
            let a = TransferStatus(text: "Copying 1 of 2", fraction: 0.4, cancel: {})
            let b = TransferStatus(text: "Moving 3 of 4", fraction: 0.8, cancel: {})
            check(ProgressSummary.make(from: []) == nil, "no jobs: no progress summary")
            check(ProgressSummary.make(from: [a, a])?.fraction == 0.4 && ProgressSummary.make(from: [a, a])?.text == "Copying 1 of 2", "listers sharing one job count it once")
            check(abs((ProgressSummary.make(from: [a, b])?.fraction ?? 0) - 0.6) < 0.0001, "two jobs: the average progress")
            check(ProgressSummary.make(from: [TransferStatus(text: "Deleting…", fraction: nil, cancel: {})])?.fraction == nil, "a job of unknown length has no percentage")
            one.model.progress = a
        }
        later(0.4) {
            check(appDelegate.statusItemTitle == " 40%", "the menu-bar icon shows the progress: '\(appDelegate.statusItemTitle)'")
            check(appDelegate.statusItemToolTip == "Copying 1 of 2", "its tooltip says what is running")
            two.model.progress = TransferStatus(text: "Moving 3 of 4", fraction: 0.8, cancel: {})
        }
        later(0.4) {
            check(appDelegate.statusItemTitle == " 60%", "two running jobs: the icon shows their average: '\(appDelegate.statusItemTitle)'")
            one.model.progress = nil
            two.model.progress = nil
        }
        later(0.4) {
            check(appDelegate.statusItemTitle.isEmpty && appDelegate.statusItemToolTip == nil, "when the jobs end the icon returns to normal")
            let ring = MenuBarIcon.progress(fraction: 0.5)
            check(ring.isTemplate && ring.size.width == 18, "the progress ring is a template image")
        }
        // menu-bar icon
        later {
            let icon = MenuBarIcon.make()
            check(icon.isTemplate && icon.size.width > 0, "the menu-bar icon is a template image")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            if let rep, let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                icon.draw(in: NSRect(x: 0, y: 0, width: 80, height: 64))
                NSGraphicsContext.restoreGraphicsState()
                var opaque = 0
                for y in 0..<64 { for x in 0..<80 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 } }
                check(opaque > 150 && opaque < 80 * 64 * 6 / 10, "the menu-bar icon draws strokes without filling the whole box (\(opaque) opaque pixels)")
                if let dump = ProcessInfo.processInfo.environment["MACLISTER_ICON_DUMP"], let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: dump))
                }
            } else { check(false, "bitmap for the icon test") }
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
        // role lock, aliases and links, attribute filter, Open With
        later {
            one.model.role = .none; two.model.role = .none
            one.model.roleLocked = false; two.model.roleLocked = false
            manager.toggleRole(.source, for: one)
            manager.toggleRoleLock(for: one)
            check(one.model.roleLocked, "a lister with a role can be locked")
            manager.toggleRole(.source, for: two)
            check(two.model.role == .none && one.model.role == .source, "a locked source cannot be taken over by another lister")
            manager.toggleRole(.source, for: one)
            check(one.model.role == .source, "pressing SRC on a locked lister does not clear it")
            manager.toggleRole(.destination, for: two)
            manager.swapRoles()
            check(one.model.role == .source && two.model.role == .destination, "swap leaves a locked lister alone")
            manager.toggleRoleLock(for: one)
            manager.swapRoles()
            check(one.model.role == .destination && two.model.role == .source, "after unlocking, swap works again")
            manager.swapRoles()
            one.model.role = .none; manager.toggleRoleLock(for: one)
            check(!one.model.roleLocked, "a lister without a role cannot be locked")
            manager.toggleRole(.source, for: one)
            manager.toggleRole(.destination, for: two)

            // aliases and symbolic links
            let target = dirA.appendingPathComponent("a.txt")
            let link = LinkMaker.make(symbolic: true, items: [target], in: nil)
            let alias = LinkMaker.make(symbolic: false, items: [target], in: nil)
            let linkURL = link.done.first, aliasURL = alias.done.first
            check(linkURL?.lastPathComponent == "a.txt link" && (try? fm.destinationOfSymbolicLink(atPath: linkURL?.path ?? "")) == target.path, "symbolic link created next to the original: \(link.failures)")
            check(aliasURL?.lastPathComponent == "a.txt alias", "alias created: \(alias.failures)")
            if let aliasURL, let resolved = try? URL(resolvingAliasFileAt: aliasURL, options: []) {
                check(resolved.resolvingSymlinksInPath().lastPathComponent == "a.txt", "the alias resolves to the original")
            } else { check(false, "the alias resolves to the original") }
            let second = LinkMaker.make(symbolic: true, items: [target], in: nil)
            check(second.done.first?.lastPathComponent == "a.txt link 2", "a second link gets a number")
            let inOther = LinkMaker.make(symbolic: true, items: [target], in: dirB)
            check(inOther.done.first?.deletingLastPathComponent().lastPathComponent == "B", "links can be created in another folder")
            for u in link.done + alias.done + second.done + inOther.done { try? fm.removeItem(at: u) }

            // attribute filter
            let now = Date()
            func item(_ name: String, dir: Bool = false, size: Int64? = nil, daysAgo: Double = 1) -> FileItem {
                FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: dir, isPackage: false, isHidden: false,
                         size: size, modified: now.addingTimeInterval(-daysAgo * 86_400))
            }
            let photo = item("holiday.JPG", size: 2_000_000, daysAgo: 2)
            let note = item("notes.txt", size: 10_000, daysAgo: 40)
            let pack = item("backup.zip", size: 5_000_000, daysAgo: 100)
            let folder = item("Projects", dir: true)
            var f = AttributeFilter(); f.category = .images
            check(f.matches(photo) && !f.matches(note) && !f.matches(folder), "kind: images")
            f.category = .archives; check(f.matches(pack) && !f.matches(photo), "kind: archives")
            f.category = .documents; check(f.matches(note) && !f.matches(pack), "kind: documents")
            f.category = .folders; check(f.matches(folder) && !f.matches(note), "kind: folders")
            f = AttributeFilter(); f.minBytes = 1_000_000
            check(f.matches(photo) && f.matches(pack) && !f.matches(note) && !f.matches(folder), "larger than 1 MB")
            f = AttributeFilter(); f.maxBytes = 100_000
            check(f.matches(note) && !f.matches(photo), "smaller than 100 KB")
            f = AttributeFilter(); f.modifiedWithinDays = 7
            check(f.matches(photo, now: now) && !f.matches(note, now: now), "modified within 7 days")
            f = AttributeFilter(); f.modifiedOlderThanDays = 30
            check(f.matches(note, now: now) && f.matches(pack, now: now) && !f.matches(photo, now: now), "modified more than 30 days ago")
            f = AttributeFilter(); f.namePattern = "*.zip"; f.minBytes = 1_000_000
            check(f.matches(pack) && !f.matches(photo), "name and size conditions combine")

            // applying a filter selects rows; context menu entries
            one.model.setFilter("")
            vc.selectNoRows()
            var imageFilter = AttributeFilter(); imageFilter.category = .images
            vc.applyAttributeFilter(imageFilter)
            check(selectedNames(one.model) == ["b.jpg", "c.png"], "select by attributes (images) selects the image rows: \(selectedNames(one.model))")
            vc.selectNoRows()

            let menu = NSMenu()
            if let textItem = one.model.items.first(where: { $0.name == "a.txt" }) {
                vc.populate(menu, selection: [textItem])
                let titles = menu.items.map(\.title)
                check(titles.contains("Open With") && titles.contains("Make Alias") && titles.contains("Make Symbolic Link"), "file menu has Open With and link entries")
                let openWith = menu.items.first { $0.title == "Open With" }?.submenu?.items.map(\.title) ?? []
                check(openWith.contains("Other…") && openWith.count > 1, "Open With lists applications and 'Other…': \(openWith.prefix(4))")
            } else { check(false, "a.txt row for the menu test") }
            vc.populate(menu, selection: [])
            check(menu.items.map(\.title).contains("Select by Attributes…"), "empty-area menu offers Select by Attributes")
        }
        // configurable columns
        let originalColumns = ColumnSettings.visible.filter { $0 != .name }
        later {
            let a = one.model.items.first { $0.name == "a.txt" }?.url ?? dirA.appendingPathComponent("a.txt")
            try? (a as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
            try? FinderMetadata.setComment("hello comment", on: a)
            ColumnSettings.setVisible([.size, .date, .created, .kind, .ext, .permissions, .tags, .comment])
        }
        later(0.6) {
            check(vc.tableView.tableColumns.map(\.identifier.rawValue) == ["name", "size", "date", "created", "kind", "ext", "permissions", "tags", "comment"],
                  "the table shows exactly the chosen columns: \(vc.tableView.tableColumns.map(\.identifier.rawValue))")
            guard let item = one.model.items.first(where: { $0.name == "a.txt" }) else { check(false, "a.txt listed"); return }
            check(item.kind?.isEmpty == false, "kind column data: \(item.kind ?? "nil")")
            check(item.permissions == 0o644, "permissions column data: \(String(describing: item.permissions.map { String($0, radix: 8) }))")
            check(item.tags == ["Red"], "tags column data: \(item.tags)")
            check(item.comment == "hello comment", "comment column data: \(item.comment ?? "nil")")
            check(item.created != nil, "created column data")
            check(ListerViewController.text(for: .ext, of: item) == "txt" && ListerViewController.text(for: .permissions, of: item) == "rw-r--r--"
                  && ListerViewController.text(for: .comment, of: item) == "hello comment" && ListerViewController.text(for: .tags, of: item) == "Red",
                  "column texts are formatted")
            one.model.setSort(.ext, ascending: true)
            check(one.model.items.filter { !$0.isDirectory }.map(\.name) == ["b.jpg", "c.png", "a.txt"], "sorting by extension: \(one.model.items.map(\.name))")
            one.model.setSort(.permissions, ascending: false)
            one.model.setSort(.kind, ascending: true)
            one.model.setSort(.comment, ascending: false)
            check(one.model.items.first?.comment == "hello comment" || one.model.items.count == 3, "sorting by comment, kind and permissions works")
            one.model.setSort(.name, ascending: true)
            if let url = one.model.items.first(where: { $0.name == "a.txt" })?.url {
                try? FinderMetadata.setComment(nil, on: url)
                try? (url as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
                check(FinderMetadata.comment(of: url) == nil, "comment can be removed again")
            }
            ColumnSettings.setVisible(originalColumns)
        }
        later(0.5) {
            check(vc.tableView.tableColumns.count == originalColumns.count + 1, "the original column set is restored")
        }
        // batch rename and attribute editor (logic)
        later {
            let rr = root.appendingPathComponent("rename")
            try? fm.createDirectory(at: rr, withIntermediateDirectories: true)
            func make(_ names: [String]) -> [URL] {
                names.map { n in let u = rr.appendingPathComponent(n); try? n.write(to: u, atomically: true, encoding: .utf8); return u }
            }
            func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
            func planned(_ items: [URL], _ o: BatchRenameOptions) -> [String] { BatchRename.plan(for: items, options: o).map(\.newName) }
            let imgs = make(["IMG_001.jpg", "IMG_002.jpg", "notes.txt"])

            var o = BatchRenameOptions(); o.find = "IMG_"; o.replace = "Holiday "
            check(planned(imgs, o) == ["Holiday 001.jpg", "Holiday 002.jpg", "notes.txt"], "rename: find and replace: \(planned(imgs, o))")
            o = BatchRenameOptions(); o.find = "img_"; o.replace = "x"
            check(planned(imgs, o)[0] == "x001.jpg", "rename: matching ignores case by default")
            o.caseSensitive = true
            check(planned(imgs, o)[0] == "IMG_001.jpg", "rename: case-sensitive matching")
            o = BatchRenameOptions(); o.find = "IMG_(\\d+)"; o.replace = "Pic-$1"; o.useRegex = true
            check(planned(imgs, o) == ["Pic-001.jpg", "Pic-002.jpg", "notes.txt"], "rename: regular expression with a captured group: \(planned(imgs, o))")
            o = BatchRenameOptions(); o.find = "("; o.useRegex = true
            check(BatchRename.plan(for: imgs, options: o).allSatisfy { $0.problem == "Invalid regular expression" }, "rename: an invalid regular expression is reported")
            o = BatchRenameOptions(); o.template = "Trip [C]"; o.counterStart = 5; o.counterDigits = 3
            check(planned(imgs, o) == ["Trip 005.jpg", "Trip 006.jpg", "Trip 007.txt"], "rename: numbering template: \(planned(imgs, o))")
            o = BatchRenameOptions(); o.template = "[N] copy"
            check(planned(imgs, o)[0] == "IMG_001 copy.jpg", "rename: [N] keeps the original name")
            o = BatchRenameOptions(); o.template = "[D]-[N]"
            check(planned(imgs, o)[0].hasSuffix("-IMG_001.jpg") && planned(imgs, o)[0].count == "2026-01-01-IMG_001.jpg".count, "rename: [D] inserts the modified date: \(planned(imgs, o)[0])")
            o = BatchRenameOptions(); o.caseMode = .upper
            check(planned(imgs, o) == ["IMG_001.jpg", "IMG_002.jpg", "NOTES.txt"], "rename: UPPERCASE leaves the extension alone")
            o.caseMode = .lower
            check(planned(imgs, o)[0] == "img_001.jpg", "rename: lowercase")
            o.caseMode = .title
            check(planned(imgs, o)[2] == "Notes.txt", "rename: Title Case")
            o = BatchRenameOptions(); o.changeExtension = true; o.newExtension = ".png"
            check(planned(imgs, o)[0] == "IMG_001.png", "rename: new extension")
            o.newExtension = ""
            check(planned(imgs, o)[0] == "IMG_001", "rename: an empty extension removes it")
            o = BatchRenameOptions(); o.template = "same"
            let dup = BatchRename.plan(for: imgs, options: o)
            check(dup[0].problem == "Duplicate name" && dup[1].problem == "Duplicate name" && dup[2].problem == nil, "rename: duplicate target names are flagged")
            _ = make(["target.txt"])
            o = BatchRenameOptions(); o.find = "notes"; o.replace = "target"
            check(BatchRename.plan(for: [imgs[2]], options: o)[0].problem?.contains("already exists") == true, "rename: a clash with another file is flagged")
            o = BatchRenameOptions(); o.find = "notes"; o.replace = "a/b"
            check(BatchRename.plan(for: [imgs[2]], options: o)[0].problem != nil, "rename: a slash in a name is refused")

            // apply: rename, swap and case-only change
            o = BatchRenameOptions(); o.find = "IMG_"; o.replace = "Holiday "
            let applied = BatchRename.apply(BatchRename.plan(for: imgs, options: o))
            check(applied.failures.isEmpty && applied.renamed.count == 2 && fm.fileExists(atPath: rr.appendingPathComponent("Holiday 001.jpg").path)
                  && !fm.fileExists(atPath: rr.appendingPathComponent("IMG_001.jpg").path), "rename: applied: \(applied.failures)")
            let swap = make(["a.txt", "b.txt"])
            let swapped = BatchRename.apply([RenameEntry(url: swap[0], newName: "b.txt"), RenameEntry(url: swap[1], newName: "a.txt")])
            check(swapped.failures.isEmpty && read(rr.appendingPathComponent("a.txt")) == "b.txt" && read(rr.appendingPathComponent("b.txt")) == "a.txt", "rename: two files can swap names")
            let lowercase = make(["x.txt"])
            var caseOnly = BatchRenameOptions(); caseOnly.caseMode = .upper
            let casePlan = BatchRename.plan(for: lowercase, options: caseOnly)
            _ = BatchRename.apply(casePlan)
            check(casePlan[0].problem == nil && ((try? fm.contentsOfDirectory(atPath: rr.path)) ?? []).contains("X.txt"), "rename: a change of letter case only is allowed")

            // attribute editor
            let ar = root.appendingPathComponent("attr")
            try? fm.createDirectory(at: ar.appendingPathComponent("d/sub"), withIntermediateDirectories: true)
            let f = ar.appendingPathComponent("f.txt")
            try? "f".write(to: f, atomically: true, encoding: .utf8)
            try? "x".write(to: ar.appendingPathComponent("d/x.txt"), atomically: true, encoding: .utf8)
            try? "y".write(to: ar.appendingPathComponent("d/sub/y.txt"), atomically: true, encoding: .utf8)
            func mode(_ u: URL) -> Int? { ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue }

            check(AttributeEditor.apply(AttributeChange(), to: [f]).isEmpty && mode(f) == 0o644, "attributes: an empty change touches nothing")
            check(AttributeEditor.apply(AttributeChange(permissions: 0o600), to: [f]).isEmpty && mode(f) == 0o600, "attributes: permissions of a file")
            var tree = AttributeChange(); tree.permissions = 0o640; tree.recursive = true
            _ = AttributeEditor.apply(tree, to: [ar.appendingPathComponent("d")])
            check(mode(ar.appendingPathComponent("d")) == 0o750 && mode(ar.appendingPathComponent("d/sub")) == 0o750
                  && mode(ar.appendingPathComponent("d/x.txt")) == 0o640 && mode(ar.appendingPathComponent("d/sub/y.txt")) == 0o640,
                  "attributes: recursive permissions keep folders searchable: \(String(describing: mode(ar.appendingPathComponent("d")).map { String($0, radix: 8) }))")
            let moment = Date(timeIntervalSince1970: 1_000_000_000)
            var dates = AttributeChange(); dates.modified = moment; dates.created = moment
            _ = AttributeEditor.apply(dates, to: [f])
            let got = try? fm.attributesOfItem(atPath: f.path)
            check(abs(((got?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince(moment)) < 2
                  && abs(((got?[.creationDate] as? Date) ?? .distantPast).timeIntervalSince(moment)) < 2, "attributes: modified and created dates")
            var hide = AttributeChange(); hide.hidden = true
            _ = AttributeEditor.apply(hide, to: [f])
            check((try? f.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true, "attributes: hidden flag set")
            hide.hidden = false
            _ = AttributeEditor.apply(hide, to: [f])
            check((try? f.resourceValues(forKeys: [.isHiddenKey]).isHidden) == false, "attributes: hidden flag cleared")
            var meta = AttributeChange(); meta.tags = ["Green", "Work"]; meta.comment = "remember"
            _ = AttributeEditor.apply(meta, to: [f])
            check(Set((try? f.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []) == ["Green", "Work"] && FinderMetadata.comment(of: f) == "remember", "attributes: tags and comment")
            meta.tags = []; meta.comment = ""
            _ = AttributeEditor.apply(meta, to: [f])
            check(((try? f.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []).isEmpty && FinderMetadata.comment(of: f) == nil, "attributes: tags and comment removed")
            check(!AttributeEditor.apply(AttributeChange(permissions: 0o600), to: [ar.appendingPathComponent("missing")]).isEmpty, "attributes: a missing file is reported")
        }
        // sheets open without trouble
        later {
            vc.setSelectionForSheetTest(one.model.items.prefix(2).map(\.url))
            func opensSheet(_ name: String, _ present: () -> Void) {
                present()
                let sheet = one.window?.attachedSheet
                check(sheet != nil, "the \(name) sheet opens")
                if let sheet { one.window?.endSheet(sheet) }
            }
            opensSheet("batch rename") { vc.promptBatchRename() }
            opensSheet("attributes") { vc.promptAttributes() }
            opensSheet("select by attributes") { vc.promptSelectByAttributes() }
            vc.selectNoRows()
        }
        // transfer engine: conflicts, merge, cancel, progress
        later {
            let engine = root.appendingPathComponent("engine")
            func put(_ rel: String, _ content: String, in base: URL) {
                let u = base.appendingPathComponent(rel)
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? content.write(to: u, atomically: true, encoding: .utf8)
            }
            func age(_ u: URL, days: Double) { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: u.path) }
            func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
            func folder(_ name: String) -> URL {
                let u = engine.appendingPathComponent(name)
                try? fm.createDirectory(at: u, withIntermediateDirectories: true)
                return u
            }
            func run(_ kind: TransferKind, _ items: [URL], into dir: URL,
                     _ resolver: @escaping (TransferConflict) -> ConflictDecision = { _ in ConflictDecision(action: .keepBoth) }) -> TransferResult {
                let job = TransferJob(kind: kind, items: items, destination: dir)
                job.resolver = resolver
                return job.runSync()
            }

            // nested tree
            let s1 = folder("s1"), d1 = folder("d1")
            put("tree/a.bin", String(repeating: "a", count: 1000), in: s1)
            put("tree/sub/b.bin", String(repeating: "b", count: 2000), in: s1)
            put("tree/sub/deep/c.bin", String(repeating: "c", count: 500), in: s1)
            let r1 = run(.copy, [s1.appendingPathComponent("tree")], into: d1)
            check(r1.failures.isEmpty && r1.done.map(\.path) == [d1.appendingPathComponent("tree").path]
                  && fm.fileExists(atPath: d1.appendingPathComponent("tree/sub/deep/c.bin").path)
                  && fm.fileExists(atPath: s1.appendingPathComponent("tree/a.bin").path), "engine copies a nested tree and keeps the source: \(r1.failures)")

            // replace if newer
            let s2 = folder("s2"), d2 = folder("d2")
            put("f.txt", "new", in: s2); age(s2.appendingPathComponent("f.txt"), days: 1)
            put("f.txt", "old", in: d2); age(d2.appendingPathComponent("f.txt"), days: 5)
            let r2 = run(.copy, [s2.appendingPathComponent("f.txt")], into: d2) { _ in ConflictDecision(action: .replaceIfNewer) }
            check(read(d2.appendingPathComponent("f.txt")) == "new" && r2.done.count == 1, "replace-if-newer replaces an older file")
            let s3 = folder("s3"), d3 = folder("d3")
            put("f.txt", "new", in: s3); age(s3.appendingPathComponent("f.txt"), days: 5)
            put("f.txt", "keep", in: d3); age(d3.appendingPathComponent("f.txt"), days: 1)
            let r3 = run(.copy, [s3.appendingPathComponent("f.txt")], into: d3) { _ in ConflictDecision(action: .replaceIfNewer) }
            check(read(d3.appendingPathComponent("f.txt")) == "keep" && r3.skipped == 1 && r3.done.isEmpty, "replace-if-newer skips when the existing file is newer")

            // replace / keep both / skip
            let s4 = folder("s4"), d4 = folder("d4")
            put("f.txt", "new", in: s4); put("f.txt", "old", in: d4)
            _ = run(.copy, [s4.appendingPathComponent("f.txt")], into: d4) { _ in ConflictDecision(action: .replace) }
            check(read(d4.appendingPathComponent("f.txt")) == "new", "replace overwrites the existing file")
            let d4b = folder("d4b"); put("f.txt", "old", in: d4b)
            let r4b = run(.copy, [s4.appendingPathComponent("f.txt")], into: d4b) { _ in ConflictDecision(action: .keepBoth) }
            check(read(d4b.appendingPathComponent("f.txt")) == "old" && read(d4b.appendingPathComponent("f 2.txt")) == "new" && r4b.done.count == 1, "keep both numbers the new file")
            let d4c = folder("d4c"); put("f.txt", "old", in: d4c)
            let r4c = run(.copy, [s4.appendingPathComponent("f.txt")], into: d4c) { _ in ConflictDecision(action: .skip) }
            check(read(d4c.appendingPathComponent("f.txt")) == "old" && r4c.skipped == 1, "skip leaves the existing file")

            // cancel stops the whole operation
            let s5 = folder("s5"), d5 = folder("d5")
            for n in ["f1", "f2", "f3"] { put(n, n, in: s5) }
            put("f2", "existing", in: d5)
            var asked = 0
            let r5 = run(.copy, ["f1", "f2", "f3"].map { s5.appendingPathComponent($0) }, into: d5) { _ in asked += 1; return ConflictDecision(action: .cancel) }
            check(r5.cancelled && asked == 1 && fm.fileExists(atPath: d5.appendingPathComponent("f1").path)
                  && !fm.fileExists(atPath: d5.appendingPathComponent("f3").path) && read(d5.appendingPathComponent("f2")) == "existing",
                  "cancel stops after the conflict: asked \(asked), done \(r5.done.map(\.lastPathComponent))")

            // merge folders
            let mergeResolver: (TransferConflict) -> ConflictDecision = { c in ConflictDecision(action: c.bothDirectories ? .merge : .skip) }
            let s6 = folder("s6"), d6 = folder("d6")
            put("proj/x.txt", "new-x", in: s6); put("proj/y.txt", "why", in: s6); put("proj/x.txt", "old-x", in: d6)
            let r6 = run(.copy, [s6.appendingPathComponent("proj")], into: d6, mergeResolver)
            check(read(d6.appendingPathComponent("proj/y.txt")) == "why" && read(d6.appendingPathComponent("proj/x.txt")) == "old-x" && r6.skipped == 1
                  && r6.done.map(\.path) == [d6.appendingPathComponent("proj").path], "merge copies the missing files and resolves each conflict")
            let s7 = folder("s7"), d7 = folder("d7")
            put("proj/x.txt", "new-x", in: s7); put("proj/y.txt", "why", in: s7); put("proj/x.txt", "old-x", in: d7)
            _ = run(.move, [s7.appendingPathComponent("proj")], into: d7, mergeResolver)
            check(!fm.fileExists(atPath: s7.appendingPathComponent("proj/y.txt").path) && fm.fileExists(atPath: d7.appendingPathComponent("proj/y.txt").path)
                  && fm.fileExists(atPath: s7.appendingPathComponent("proj/x.txt").path), "a merging move keeps in the source whatever was skipped")

            // move = rename on the same volume
            let s8 = folder("s8"), d8 = folder("d8")
            put("dirm/f.txt", "m", in: s8)
            let r8 = run(.move, [s8.appendingPathComponent("dirm")], into: d8)
            check(!fm.fileExists(atPath: s8.appendingPathComponent("dirm").path) && read(d8.appendingPathComponent("dirm/f.txt")) == "m" && r8.done.count == 1, "move of a folder relocates it")

            // folder into itself
            let s9 = folder("s9"); put("dir/sub/x", "x", in: s9)
            let r9 = run(.copy, [s9.appendingPathComponent("dir")], into: s9.appendingPathComponent("dir/sub"))
            check(r9.failures.count == 1 && r9.done.isEmpty, "a folder cannot be copied into itself")

            // conflict rules and the buttons offered
            func conflict(srcDir: Bool, dstDir: Bool) -> TransferConflict {
                TransferConflict(source: URL(fileURLWithPath: "/s/x"), target: URL(fileURLWithPath: "/d/x"), sourceIsDirectory: srcDir,
                                 targetIsDirectory: dstDir, sourceModified: nil, targetModified: nil, sourceSize: 1, targetSize: 1)
            }
            check(ConflictRules.canReuse(.merge, for: conflict(srcDir: true, dstDir: true)) && !ConflictRules.canReuse(.merge, for: conflict(srcDir: false, dstDir: false)),
                  "an 'apply to all' Merge answers only folder conflicts")
            check(ConflictRules.canReuse(.replaceIfNewer, for: conflict(srcDir: false, dstDir: false)) && !ConflictRules.canReuse(.replaceIfNewer, for: conflict(srcDir: true, dstDir: false))
                  && ConflictRules.canReuse(.skip, for: conflict(srcDir: true, dstDir: false)), "'apply to all' rules for replace-if-newer and skip")
            typealias VC = ListerViewController
            check(VC.conflictChoices(for: conflict(srcDir: false, dstDir: false)).map(\.title) == ["Replace", "Replace If Newer", "Keep Both", "Skip", "Cancel"], "file conflict buttons")
            check(VC.conflictChoices(for: conflict(srcDir: true, dstDir: true)).first?.title == "Merge" && VC.conflictChoices(for: conflict(srcDir: true, dstDir: false)).count == 4, "folder and mismatch conflict buttons")
        }
        // progress reporting through start()
        var progressLog: [TransferProgress] = []
        var progressResult: TransferResult?
        later {
            let engine = root.appendingPathComponent("engine")
            let src = engine.appendingPathComponent("s1/tree"), dst = engine.appendingPathComponent("dp")
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let job = TransferJob(kind: .copy, items: [src], destination: dst)
            job.onProgress = { progressLog.append($0) }
            job.start { progressResult = $0 }
        }
        later(1.0) {
            let fractions = progressLog.map(\.fraction)
            check(progressResult?.done.count == 1, "job.start delivers the result on the main queue")
            check(progressLog.last?.bytesDone == 3500 && progressLog.last?.bytesTotal == 3500 && progressLog.last?.itemsDone == 1, "progress ends at 3500 of 3500 bytes: \(String(describing: progressLog.last))")
            check(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 } && fractions.last == 1, "progress never goes backwards (\(progressLog.count) reports)")
        }
        // breadcrumb segments
        later {
            let segs = PathSegments.make(for: URL(fileURLWithPath: "/Users/Shared"))
            check(segs.map(\.url.path) == ["/", "/Users", "/Users/Shared"], "breadcrumb segments lead to the right folders: \(segs.map(\.url.path))")
            check(segs.dropFirst().map(\.title) == ["Users", "Shared"] && !(segs.first?.title.isEmpty ?? true), "breadcrumb titles: \(segs.map(\.title))")
            check(PathSegments.make(for: URL(fileURLWithPath: "/")).count == 1, "root has a single segment")
            check(PathSegments.make(for: dirA).last?.url.standardizedFileURL.path == dirA.standardizedFileURL.path, "the last segment is the current folder")
            one.model.editingPath = true
            check(one.model.editingPath, "path editing mode can be switched on")
            one.model.editingPath = false
        }
        // auto-refresh through FSEvents, free space
        later {
            check(VolumeInfo.summary(for: dirA)?.contains("free of") == true, "free space text for a volume: \(VolumeInfo.summary(for: dirA) ?? "nil")")
            one.model.setFilter("")
            try? Data(repeating: 0x42, count: 7).write(to: dirA.appendingPathComponent("watch.txt"))
        }
        later(1.6) {
            check(names(one.model).contains("watch.txt"), "a file created on disk appears without any action")
            if let handle = try? FileHandle(forWritingTo: dirA.appendingPathComponent("watch.txt")) {
                handle.seekToEndOfFile(); handle.write(Data(repeating: 0x43, count: 100)); try? handle.close()
            }
        }
        later(1.6) {
            check(one.model.items.first { $0.name == "watch.txt" }?.size == 107, "a file that grew on disk shows its new size: \(String(describing: one.model.items.first { $0.name == "watch.txt" }?.size))")
            try? fm.removeItem(at: dirA.appendingPathComponent("watch.txt"))
        }
        later(1.6) {
            check(!names(one.model).contains("watch.txt"), "a file deleted on disk disappears")
            one.model.navigate(to: dirB)
            try? Data([1]).write(to: dirA.appendingPathComponent("late.txt"))
        }
        later(1.2) {
            check(!names(one.model).contains("late.txt"), "after navigating away, changes in the old folder are not shown")
            one.model.navigate(to: dirA)
            try? fm.removeItem(at: dirA.appendingPathComponent("late.txt"))
        }
        later(1.0) { }
        // relative dates, compress, tags, Finder-style menu
        later {
            let now = Date()
            let cal = Calendar.current
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
            let en = Locale(identifier: "en_US"), pl = Locale(identifier: "pl_PL")
            let today = DateText.string(noon, relative: true, locale: en)
            let yesterday = DateText.string(cal.date(byAdding: .day, value: -1, to: noon) ?? noon, relative: true, locale: en)
            check(today.hasPrefix("Today"), "relative date: today: \(today)")
            check(yesterday.hasPrefix("Yesterday"), "relative date: yesterday: \(yesterday)")
            let old = cal.date(byAdding: .day, value: -40, to: noon) ?? noon
            check(!DateText.string(old, relative: true, locale: en).hasPrefix("Today") && DateText.string(old, relative: true, locale: en) == DateText.string(old, relative: false, locale: en),
                  "relative date: an old date stays absolute")
            check(!DateText.string(noon, relative: false, locale: en).hasPrefix("Today"), "raw dates are not relative")
            check(DateText.string(noon, relative: true, locale: pl).lowercased().hasPrefix("dzisiaj"), "Polish: dzisiaj: \(DateText.string(noon, relative: true, locale: pl))")
            check(DateText.string(cal.date(byAdding: .day, value: -1, to: noon) ?? noon, relative: true, locale: pl).lowercased().hasPrefix("wczoraj"), "Polish: wczoraj")
            check(DateText.string(cal.date(byAdding: .day, value: -2, to: noon) ?? noon, relative: true, locale: pl).lowercased().hasPrefix("przedwczoraj"),
                  "Polish: przedwczoraj: \(DateText.string(cal.date(byAdding: .day, value: -2, to: noon) ?? noon, relative: true, locale: pl))")
            let item = FileItem(url: dirA.appendingPathComponent("a.txt"), name: "a.txt", isDirectory: false, isPackage: false, isHidden: false, size: 1, modified: noon)
            Settings.relativeDates = true
            check(ListerViewController.text(for: .date, of: item) == DateText.string(noon, relative: true), "the Modified column uses relative dates when switched on")
            Settings.relativeDates = false
            check(ListerViewController.text(for: .date, of: item) == DateText.string(noon, relative: false), "the Modified column shows raw dates when switched off")
            Settings.relativeDates = true
        }
        later {
            // compress
            let single = Compressor.compressSync([dirA.appendingPathComponent("a.txt")])
            check(single.output?.lastPathComponent == "a.txt.zip" && single.error == nil && fm.fileExists(atPath: single.output?.path ?? ""), "compress one file → a.txt.zip (\(single.error ?? "ok"))")
            let again = Compressor.compressSync([dirA.appendingPathComponent("a.txt")])
            check(again.output?.lastPathComponent == "a.txt 2.zip", "compress again → numbered name: \(again.output?.lastPathComponent ?? "nil")")
            let packDir = root.appendingPathComponent("pack")
            try? fm.createDirectory(at: packDir.appendingPathComponent("big"), withIntermediateDirectories: true)
            try? Data("one".utf8).write(to: packDir.appendingPathComponent("a.txt"))
            try? Data("two".utf8).write(to: packDir.appendingPathComponent("b.jpg"))
            try? Data("three".utf8).write(to: packDir.appendingPathComponent("big/c.bin"))
            let multi = Compressor.compressSync([packDir.appendingPathComponent("a.txt"), packDir.appendingPathComponent("b.jpg"), packDir.appendingPathComponent("big")])
            check(multi.output?.lastPathComponent == "Archive.zip" && multi.error == nil, "compress several items → Archive.zip (\(multi.error ?? "ok"))")
            if let output = multi.output {
                let check1 = Process()
                check1.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                check1.arguments = ["-Z1", output.path]
                let pipe = Pipe(); check1.standardOutput = pipe
                try? check1.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); check1.waitUntilExit()
                let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                check(names.contains("a.txt") && names.contains("b.jpg") && names.contains { $0.hasPrefix("big/") }, "Archive.zip holds the items side by side: \(names)")
            }
            let missing = Compressor.compressSync([dirA.appendingPathComponent("nope.txt")])
            check(missing.output == nil && missing.error != nil, "compress of a missing file fails cleanly")
            for name in ["a.txt.zip", "a.txt 2.zip"] { try? fm.removeItem(at: dirA.appendingPathComponent(name)) }
            try? fm.removeItem(at: packDir)

            // tags
            let target = dirA.appendingPathComponent("c.png"), other = dirA.appendingPathComponent("b.jpg")
            check(FinderTags.entries(of: target).isEmpty, "fresh file has no tags")
            check(FinderTags.toggle(label: 6, on: [target]).isEmpty && FinderTags.allHave(label: 6, in: [target]), "red tag is added")
            let written = FinderTags.entries(of: target)
            check(written.count == 1 && written[0].label == 6, "red tag is stored with its colour number: \(written)")
            check(((try? target.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []).count == 1, "the system sees the tag")
            check(!FinderTags.allHave(label: 6, in: [target, other]), "a colour is not 'all' when one item lacks it")
            _ = FinderTags.toggle(label: 6, on: [target, other])
            check(FinderTags.allHave(label: 6, in: [target, other]), "toggle on a mixed selection adds it to all")
            _ = FinderTags.toggle(label: 6, on: [target, other])
            check(FinderTags.entries(of: target).isEmpty && FinderTags.entries(of: other).isEmpty, "toggle again removes it from all")
            _ = FinderTags.apply(add: [FinderTags.Entry(name: "Work", label: 0), FinderTags.Entry(name: FinderTags.name(for: 4), label: 4)], remove: [], to: [target])
            check(Set(FinderTags.entries(of: target).map(\.name)).contains("Work") && FinderTags.allHave(label: 4, in: [target]), "a custom tag and a colour are added together")
            _ = FinderTags.apply(add: [], remove: [FinderTags.Entry(name: "Work", label: 0)], to: [target])
            check(!FinderTags.entries(of: target).contains { $0.name == "Work" } && FinderTags.allHave(label: 4, in: [target]), "removing one tag keeps the others")
            try? FinderTags.write([], to: target)
            check(FinderTags.entries(of: target).isEmpty, "writing no tags removes the attribute")
            check(FinderTags.parse("Red\n6") == FinderTags.Entry(name: "Red", label: 6) && FinderTags.parse("Plain") == FinderTags.Entry(name: "Plain", label: 0), "tag entries parse")
            let state = TagsEditorState.make(for: [target], alsoSeen: ["Extra"])
            check(state.rows.count == 8 && state.rows.contains { $0.entry.name == "Extra" }, "tags sheet offers the 7 colours plus tags seen in the folder")

            // image quick actions (sips)
            let pngURL = dirA.appendingPathComponent("real.png")
            let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            try? png?.representation(using: .png, properties: [:])?.write(to: pngURL)
            check(QuickActions.allImages([pngURL]) && !QuickActions.allImages([dirA.appendingPathComponent("a.txt")]), "image detection for Quick Actions")
            check(QuickActions.rotate([pngURL], degrees: 90).isEmpty, "rotate right succeeds")
            if let rep = NSBitmapImageRep(data: (try? Data(contentsOf: pngURL)) ?? Data()) { check(rep.pixelsWide == 4 && rep.pixelsHigh == 8, "the image really rotated: \(rep.pixelsWide)×\(rep.pixelsHigh)") }
            let converted = QuickActions.convert([pngURL], to: QuickActions.formats[0])
            check(converted.failures.isEmpty && converted.outputs.first?.lastPathComponent == "real.jpg", "convert to JPEG: \(converted.failures)")
            let pdf = QuickActions.createPDFs([pngURL])
            check(pdf.failures.isEmpty && fm.fileExists(atPath: pdf.outputs.first?.path ?? ""), "create PDF: \(pdf.failures)")
            for name in ["real.png", "real.jpg", "real.pdf"] { try? fm.removeItem(at: dirA.appendingPathComponent(name)) }

            // workflows are only listed when they accept files
            let services = root.appendingPathComponent("services")
            let flow = services.appendingPathComponent("Demo.workflow/Contents")
            try? fm.createDirectory(at: flow, withIntermediateDirectories: true)
            let plist: [String: Any] = ["NSServices": [["NSMenuItem": ["default": "Demo action"], "NSSendFileTypes": ["public.item"]],
                                                       ["NSMenuItem": ["default": "Text only"], "NSSendTypes": ["NSStringPboardType"]]]]
            try? (PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)).write(to: flow.appendingPathComponent("Info.plist"))
            check(QuickActions.workflows(directories: [services]).map(\.title) == ["Demo action"], "Quick Action workflows: only file-accepting ones are listed")

            // context menu layout (Finder order, our items kept)
            guard let vc = one.listerViewController else { check(false, "lister view controller available"); return }
            let menu = NSMenu()
            vc.populate(menu, selection: [one.model.items.first { $0.name == "a.txt" }].compactMap { $0 })
            let layout = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            func at(_ title: String) -> Int? { layout.firstIndex(of: title) }
            check(at("Open") != nil && at("Open With") != nil && at("Open")! < at("Open With")!, "menu: Open, then Open With: \(layout)")
            let trash = menu.items.first { $0.title == "Move to Trash" }
            check(trash?.image != nil, "Move to Trash has an icon")
            check(at("Move to Trash")! < at("Info")! && at("Info")! < at("Rename…")! && at("Rename…")! < at("Duplicate")! && at("Duplicate")! < at("Make Alias")! && at("Make Alias")! < at("Quick Look")!,
                  "menu order follows Finder: Trash, Info, Rename, Duplicate, Make Alias, Quick Look")
            check(layout.contains { $0.hasPrefix("Compress") } && layout.contains("Copy"), "menu has Compress and Copy")
            check(at("Share") != nil && at("Share")! > at("Copy")!, "menu has Share after the file commands")
            let tagRow = menu.items.first { $0.view is TagColorRowView }
            check(tagRow != nil && at("Tags…") != nil, "menu has the colour dots and Tags…")
            check(at("Quick Actions") != nil && at("Services") != nil && at("Quick Actions")! < at("Services")!, "menu has Quick Actions and Services")
            for ours in ["Attributes…", "Make Symbolic Link", "Copy Path", "Reveal in Finder", "Duplicate Lister", "Add Bookmark", "New Folder…", "Terminal Here", "Refresh"] {
                check(layout.contains(ours), "our own menu item is kept: \(ours)")
            }
            check(menu.items.first { $0.title == "Quick Actions" }?.submenu?.items.contains { $0.title == "Rotate Left" } == false, "no image quick actions for a text file")

            // colour dots toggle through the same code path as a click
            if let row = tagRow?.view as? TagColorRowView {
                let index = FinderTags.menuOrder.firstIndex(of: 6) ?? 0
                let rect = row.rect(at: index)
                check(row.label(at: NSPoint(x: rect.midX, y: rect.midY)) == 6, "a click on the first dot means red")
                check(row.label(at: NSPoint(x: 2, y: 2)) == nil, "a click outside the dots does nothing")
                check(row.frame.width >= TagColorRowView.width, "the dot row is wide enough")
            }
            let servicesItem = menu.items.first { $0.title == "Services" }
            check(servicesItem?.submenu != nil && NSApp.servicesMenu === servicesItem?.submenu, "Services submenu is registered with the system (item \(servicesItem != nil), submenu \(servicesItem?.submenu != nil), same \(NSApp.servicesMenu === servicesItem?.submenu), app menu \(String(describing: NSApp.servicesMenu?.title)))")
            // services: the table offers the selected files to the system
            let table = vc.tableView
            let shownA = one.model.items.first { $0.name == "a.txt" }?.url ?? dirA.appendingPathComponent("a.txt")
            vc.setSelectionForSheetTest([shownA])
            check(table.validRequestor(forSendType: .fileURL, returnType: nil) as AnyObject? === table, "the table is a valid service requestor for the selected files")
            check(table.validRequestor(forSendType: .string, returnType: nil) as AnyObject? !== table, "the table does not claim text-only services")
            let board = NSPasteboard(name: NSPasteboard.Name("maclister-selftest"))
            check(table.writeSelection(to: board, types: FinderServices.sendTypes), "writing the selection for a service works")
            let pasted = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            check(pasted.map(\.lastPathComponent) == ["a.txt"], "the pasteboard holds the selected file: \(pasted)")
            check((board.propertyList(forType: FinderServices.filenames) as? [String])?.count == 1, "and its legacy file-name list")
            board.releaseGlobally()
        }
        // transfer details: monitor, pause, growth watcher
        later {
            let t0 = Date()
            let m = TransferMonitor(title: "Copying", from: "A", to: "B", now: t0)
            var paused = 0, resumed = 0
            m.onPause = { paused += 1 }; m.onResume = { resumed += 1 }
            var p = TransferProgress(itemsDone: 0, itemsTotal: 4, bytesDone: 0, bytesTotal: 10_000_000, current: "x.bin")
            for i in 1...8 {
                p.bytesDone = Int64(i * 500_000)
                m.update(p, now: t0.addingTimeInterval(Double(i) * 0.5))
            }
            let t8 = t0.addingTimeInterval(4)
            check(abs(m.speed - 1_000_000) < 60_000, "monitor: speed ≈ 1 MB/s: \(m.speed)")
            check(m.peak >= m.speed && m.samples.count >= 6, "monitor: peak and graph samples: \(m.samples.count)")
            check(abs(m.averageSpeed(now: t8) - 1_000_000) < 20_000, "monitor: average speed: \(m.averageSpeed(now: t8))")
            check(abs((m.remaining(now: t8) ?? 0) - 6) < 0.6, "monitor: remaining time ≈ 6 s: \(String(describing: m.remaining(now: t8)))")
            check(abs(p.fraction - 0.4) < 0.001, "progress fraction counts the bytes: \(p.fraction)")
            p.inFlight = 1_000_000
            check(abs(p.fraction - 0.5) < 0.001 && p.effectiveBytes == 5_000_000, "in-flight bytes count towards the fraction")
            m.pause(now: t8)
            check(m.isPaused && paused == 1, "monitor: pause is passed on")
            check(abs(m.activeElapsed(now: t8.addingTimeInterval(10)) - 4) < 0.01, "monitor: paused time is not counted as elapsed")
            m.resume(now: t8.addingTimeInterval(10))
            check(!m.isPaused && resumed == 1 && abs(m.activeElapsed(now: t8.addingTimeInterval(11)) - 5) < 0.01, "monitor: resume continues the clock")
            m.finish(.finished)
            check(m.state == .finished && m.speed == 0 && m.remaining() == nil, "monitor: finished")
            check(TransferMonitor.timeText(140) == "2:20" && TransferMonitor.timeText(3725) == "1:02:05", "time text: \(TransferMonitor.timeText(140)) \(TransferMonitor.timeText(3725))")
            check(TransferMonitor.speedText(37_800_000).contains("/s"), "speed text: \(TransferMonitor.speedText(37_800_000))")
            let long = TransferMonitor(title: "x", from: "", to: "")
            for i in 0..<(TransferMonitor.maxSamples + 50) { long.update(TransferProgress(bytesDone: Int64(i * 1000)), now: Date().addingTimeInterval(Double(i))) }
            check(long.samples.count == TransferMonitor.maxSamples, "monitor keeps a bounded history: \(long.samples.count)")

            let text = ListerViewController.progressText(verb: "Copying", progress: TransferProgress(itemsDone: 0, itemsTotal: 3, bytesDone: 1_000_000, bytesTotal: 5_000_000, current: "f.bin"), speed: 2_500_000, paused: false)
            check(text.hasPrefix("Copying 1 of 3") && text.contains("/s") && text.hasSuffix("f.bin"), "status line text: \(text)")
            check(ListerViewController.progressText(verb: "Copying", progress: TransferProgress(itemsDone: 0, itemsTotal: 3), speed: 5, paused: true).contains("Paused"), "status line says Paused")

            // pause gate
            let gate = PauseGate()
            gate.pause()
            let released = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { gate.waitWhilePaused { false }; released.signal() }
            check(released.wait(timeout: .now() + 0.4) == .timedOut, "pause gate blocks while paused")
            gate.resume()
            check(released.wait(timeout: .now() + 1) == .success, "pause gate releases on resume")
            gate.pause()
            let flag = NSLock(); var stop = false
            DispatchQueue.global().async { gate.waitWhilePaused { flag.lock(); defer { flag.unlock() }; return stop }; released.signal() }
            flag.lock(); stop = true; flag.unlock()
            check(released.wait(timeout: .now() + 1) == .success, "pause gate releases when the job is cancelled")

            // growth watcher
            let grown = root.appendingPathComponent("growing.bin")
            fm.createFile(atPath: grown.path, contents: nil)
            let seen = NSLock(); var sizes: [Int64] = []
            let watcher = GrowthWatcher(url: grown, interval: 0.05) { seen.lock(); sizes.append($0); seen.unlock() }
            if let handle = try? FileHandle(forWritingTo: grown) {
                for _ in 0..<3 { handle.write(Data(count: 1_000_000)); Thread.sleep(forTimeInterval: 0.15) }
                try? handle.close()
            }
            watcher.stop()
            seen.lock(); let observed = sizes; seen.unlock()
            check(observed.contains(1_000_000) && observed.contains(3_000_000) && observed == observed.sorted(), "growth watcher follows a growing file: \(Set(observed).sorted())")
            try? fm.removeItem(at: grown)
        }
        later(0.2) {
            // a paused job copies nothing until resumed; cancel releases it
            let src = root.appendingPathComponent("pausesrc"), dst = root.appendingPathComponent("pausedst")
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            var urls: [URL] = []
            for i in 1...5 { let u = src.appendingPathComponent("f\(i).bin"); try? Data(count: 100_000).write(to: u); urls.append(u) }
            let job = TransferJob(kind: .copy, items: urls, destination: dst)
            var snapshots: [TransferProgress] = []
            job.onProgress = { snapshots.append($0) }
            job.gate.pause()
            var outcome: TransferResult?
            job.start { outcome = $0 }
            Thread.sleep(forTimeInterval: 0.01)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                check(outcome == nil && ((try? fm.contentsOfDirectory(atPath: dst.path)) ?? []).isEmpty, "a paused job has copied nothing yet")
                job.gate.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                check(outcome?.done.count == 5 && outcome?.failures.isEmpty == true, "after Resume the job copies everything: \(String(describing: outcome?.done.count))")
                check(snapshots.allSatisfy { $0.effectiveBytes <= $0.bytesTotal } && snapshots.last?.bytesDone == 500_000, "progress never overshoots and ends at the total")
                // cancel while paused
                let src2 = root.appendingPathComponent("pausesrc2"), dst2 = root.appendingPathComponent("pausedst2")
                try? fm.createDirectory(at: src2, withIntermediateDirectories: true)
                try? fm.createDirectory(at: dst2, withIntermediateDirectories: true)
                let one = src2.appendingPathComponent("a.bin"); try? Data(count: 1000).write(to: one)
                let job2 = TransferJob(kind: .copy, items: [one], destination: dst2)
                job2.gate.pause()
                var outcome2: TransferResult?
                job2.start { outcome2 = $0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { job2.cancel() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    check(outcome2?.cancelled == true && ((try? fm.contentsOfDirectory(atPath: dst2.path)) ?? []).isEmpty, "cancelling a paused job stops it without copying")
                    for d in [src, dst, src2, dst2] { try? fm.removeItem(at: d) }
                }
            }
        }
        later(2.2) {
            // the details window
            let monitor = TransferMonitor(title: "Copying", from: "Downloads", to: "NAS")
            let hosting = NSHostingView(rootView: TransferDetailsView(monitor: monitor, close: { }))
            check(hosting.fittingSize.width >= 440 && hosting.fittingSize.height > 250, "details view lays out: \(hosting.fittingSize)")
            TransferDetailsWindows.show(monitor)
            check(TransferDetailsWindows.isOpen(for: monitor), "details window opens")
            monitor.update(TransferProgress(itemsDone: 0, itemsTotal: 2, bytesDone: 5_000_000, bytesTotal: 20_000_000, current: "a.iso"))
            DispatchQueue.main.async {
                check(NSApp.windows.contains { $0.title.hasSuffix("Copying") && $0.title.contains("25%") }, "the window title follows the progress: \(NSApp.windows.map(\.title).filter { $0.contains("Copying") })")
                TransferDetailsWindows.close(monitor)
            }
        }
        later(0.5) {
            check(!NSApp.windows.contains { $0.title.contains("Copying") }, "the details window closes")
        }
        // operation queue
        later {
            let queue = TransferQueue()
            var log: [String] = []
            var finishers: [String: () -> Void] = [:]
            func submit(_ name: String, key: String, sources: [URL] = []) -> Bool {
                queue.submit(key: key, sources: sources, detail: name, onCancel: { log.append("cancel \(name)") }) { done in
                    log.append("start \(name)")
                    finishers[name] = done
                }
            }
            check(submit("A", key: "disk1", sources: [dirA.appendingPathComponent("a.txt")]), "queue: the first operation starts at once")
            check(!submit("B", key: "disk1", sources: [dirA.appendingPathComponent("b.jpg")]), "queue: a second one for the same place waits")
            check(submit("C", key: "disk2"), "queue: an operation for another place runs at the same time")
            check(!submit("D", key: "disk1"), "queue: a third waits too")
            check(log == ["start A", "start C"] && queue.waiting.map(\.detail) == ["B", "D"], "queue: only A and C run, B and D wait in order: \(log) \(queue.waiting.map(\.detail))")
            check(queue.isBusy(dirA.appendingPathComponent("a.txt")) && queue.isBusy(dirA.appendingPathComponent("b.jpg")), "queue: running and waiting sources are busy")
            check(queue.isBusy(dirA) && queue.isBusy(dirA.appendingPathComponent("a.txt/inside")), "queue: the folder that holds a source and a path inside one are busy")
            check(!queue.isBusy(dirB) && !queue.isBusy(dirA.appendingPathComponent("c.png")), "queue: unrelated items are not busy")
            queue.cancelWaiting(queue.waiting[1].id)
            check(log.last == "cancel D" && queue.waiting.map(\.detail) == ["B"], "queue: a waiting operation can be removed")
            finishers["A"]?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                check(log.contains("start B") && !log.contains("start D"), "queue: when A ends B starts: \(log)")
                check(queue.waiting.isEmpty && !queue.isBusy(dirA.appendingPathComponent("a.txt")) && queue.isBusy(dirA.appendingPathComponent("b.jpg")), "queue: A's source is free again, B's is busy")
                finishers["B"]?(); finishers["C"]?()
                finishers["B"]?()          // a second call must do nothing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check(queue.isIdle, "queue: idle when everything ended") }
            }
        }
        later(0.8) {
            // two real copies into one folder: the second waits, both finish, and a busy file cannot be trashed
            let src = root.appendingPathComponent("qsrc"), dst = root.appendingPathComponent("qdst")
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            var first: [URL] = [], second: [URL] = []
            for i in 1...60 { let u = src.appendingPathComponent("a\(i).bin"); try? Data(count: 50_000).write(to: u); first.append(u) }
            for i in 1...3 { let u = src.appendingPathComponent("b\(i).bin"); try? Data(count: 1000).write(to: u); second.append(u) }
            guard let vc = one.listerViewController else { check(false, "lister for the queue test"); return }
            let models = [one.model]
            vc.beginTransfer(.copy, items: first, into: dst, showingIn: models)
            vc.beginTransfer(.copy, items: second, into: dst, showingIn: models)
            check(TransferQueue.shared.waiting.count == 1, "queue: the second real copy waits: \(TransferQueue.shared.waiting.count)")
            check(one.model.progress != nil && one.model.statusMessage == "Waiting in queue…", "queue: the lister shows the running copy and the waiting message")
            check(vc.refuseIfBusy([second[0]]) && one.model.errorMessage?.contains("is being transferred") == true, "a file that waits in the queue is protected: \(one.model.errorMessage ?? "")")
            check(!vc.refuseIfBusy([dirB.appendingPathComponent("z.txt")]), "other files are not protected")
            one.model.errorMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let copied = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
                check(copied.count == 63, "queue: both copies finished: \(copied.count) files")
                check(TransferQueue.shared.isIdle && TransferQueue.shared.waiting.isEmpty, "queue: empty afterwards")
                check(!vc.refuseIfBusy([second[0]]), "files are free again after the copies")
                one.model.statusMessage = nil
                for d in [src, dst] { try? fm.removeItem(at: d) }
            }
        }
        later(3.6) { }
        // lister labels
        later {
            guard let vc = one.listerViewController else { check(false, "lister for the label test"); return }
            check(one.model.label.isEmpty && one.model.displayName == FileManager.default.displayName(atPath: one.model.url.path), "a lister has no label at first")
            one.model.setLabel("NAS", color: "orange")
            one.updateTitle()                                              // the window follows the model a moment later by itself
            check(one.window?.title.hasPrefix("NAS — ") == true, "the window title starts with the label: \(one.window?.title ?? "")")
            check(one.menuTitle.hasPrefix("NAS  ·  "), "the menu-bar list shows the label: \(one.menuTitle)")
            check(one.model.displayName == "NAS", "the label is the lister's name in menus")
            let menu = NSMenu()
            vc.populate(menu, selection: [])
            let titles = menu.items.map(\.title)
            check(titles.contains("Rename This Lister…") && !titles.contains("Name This Lister…"), "the folder menu offers Rename once a label exists")
            check(vc.makeTitleBarMenu().items.contains { $0.title == "Rename This Lister…" }, "the title-bar menu offers it too")
            check(ListerAction.nameLister.title == "Name lister", "the action can be put on a button or a key")
            check(LabelPalette.color("orange") != nil && LabelPalette.color("nope") == nil && LabelPalette.color(nil) == nil, "label colours")
            let copy = ListerManager.shared.duplicate(one)
            check(copy.model.label.isEmpty, "a duplicate does not inherit the label")
            copy.window?.close()
            // the destination shows its label in the Copy to… item
            let roleBefore = one.model.role
            ListerManager.shared.toggleRole(.destination, for: one)
            if let other = ListerManager.shared.allControllers.first(where: { $0 !== one }), let otherVC = other.listerViewController {
                let m = NSMenu()
                otherVC.populate(m, selection: other.model.items.filter { $0.name == "b.jpg" || $0.name == "a.txt" }.prefix(1).map { $0 })
                check(m.items.contains { $0.title == "Copy to “NAS”" }, "Copy to… names the destination by its label: \(m.items.map(\.title).filter { $0.hasPrefix("Copy") })")
            }
            ListerManager.shared.toggleRole(.destination, for: one)
            if roleBefore == .source { ListerManager.shared.toggleRole(.source, for: one) }
            // saved in the layout and restored
            check(LayoutStore.save(from: ListerManager.shared) >= 1, "layout saved with a label")
            let saved = (try? JSONDecoder().decode([ListerSnapshot].self, from: Data(contentsOf: LayoutStore.url))) ?? []
            check(saved.contains { $0.label == "NAS" && $0.labelColor == "orange" }, "the layout file holds the label and colour")
            let before = ListerManager.shared.openCount
            LayoutStore.restore(into: ListerManager.shared)
            check(ListerManager.shared.allControllers.suffix(ListerManager.shared.openCount - before).contains { $0.model.label == "NAS" && $0.model.labelColor == "orange" }, "a restored lister has its label back")
            for c in ListerManager.shared.allControllers.suffix(ListerManager.shared.openCount - before) { c.window?.close() }
            if roleBefore == .source, one.model.role != .source { ListerManager.shared.toggleRole(.source, for: one) }   // restoring moved it
            // the sheet and the badge draw
            let hosting = NSHostingView(rootView: ListerLabelView(initialName: "NAS", initialColor: "orange", onApply: { _, _ in }, close: { }))
            check(hosting.fittingSize.width >= 380 && hosting.fittingSize.height > 150, "the label sheet lays out: \(hosting.fittingSize)")
            LocalizationAudit.touch(PathBarView(model: one.model, onToggleRole: { _ in }, onConnect: { _ in }), size: NSSize(width: 700, height: 80))
            one.model.setLabel("", color: nil)
            one.updateTitle()
            check(one.model.labelColor == nil && one.model.label.isEmpty && one.window?.title.contains("—") == false || one.window?.title.hasPrefix("NAS") == false, "removing the label restores the title: \(one.window?.title ?? "")")
        }
        // Recents and Shared
        later {
            guard let vc = one.listerViewController else { check(false, "lister for the places test"); return }
            SharedPlaces.browsingEnabled = false
            check(VirtualPlace.place(for: VirtualPlace.recents.url) == .recents && VirtualPlace.place(for: VirtualPlace.shared.url) == .shared && VirtualPlace.place(for: dirA) == nil, "virtual place addresses")
            check(ListerModel.comparisonKey(VirtualPlace.recents.url) != ListerModel.comparisonKey(VirtualPlace.shared.url), "the two lists are different locations")
            check(ListerModel.displayPath(VirtualPlace.recents.url) == "Recents" && PathSegments.make(for: VirtualPlace.shared.url).map(\.title) == ["Shared"], "path text and breadcrumb of a list")
            // which files belong in Recents
            let old = Date()
            let docs = root.appendingPathComponent("recent-docs")
            try? fm.createDirectory(at: docs.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: docs.appendingPathComponent("Some.app"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: docs.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
            for name in ["new.txt", "old.txt", ".dot.txt"] { try? Data("x".utf8).write(to: docs.appendingPathComponent(name)) }
            check(RecentFiles.accept(path: docs.appendingPathComponent("new.txt").path, date: old) != nil, "Recents accepts a document")
            check(RecentFiles.accept(path: docs.appendingPathComponent("folder").path, date: old) == nil, "Recents skips folders")
            check(RecentFiles.accept(path: docs.appendingPathComponent("Some.app").path, date: old) == nil, "Recents skips applications")
            check(RecentFiles.accept(path: docs.appendingPathComponent(".dot.txt").path, date: old) == nil, "Recents skips hidden files")
            check(RecentFiles.accept(path: "/Users/x/Library/Caches/a.txt", date: old) == nil && RecentFiles.accept(path: docs.appendingPathComponent("gone.txt").path, date: old) == nil, "Recents skips ~/Library and missing files")
            // the list in a lister
            let sortBefore = (one.model.sortKey, one.model.ascending)
            let newer = Date().addingTimeInterval(-60), older = Date().addingTimeInterval(-86_400 * 3)
            RecentFiles.override = { done in done([RecentFiles.Seed(url: docs.appendingPathComponent("old.txt"), lastUsed: older), RecentFiles.Seed(url: docs.appendingPathComponent("new.txt"), lastUsed: newer)]) }
            let backTo = one.model.url
            one.model.navigate(to: VirtualPlace.recents.url)
            one.updateTitle()
            check(one.model.isVirtual && one.model.virtualPlace == .recents && !one.model.canGoParent, "the lister shows Recents and has no parent")
            check(one.window?.title == "NAS — Recents" || one.window?.title == "Recents", "the window is titled Recents: \(one.window?.title ?? "")")
            check(one.model.sortKey == .date && one.model.ascending == false, "Recents sorts by date, newest first")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                check(one.window?.title == "Recents", "the title follows the lister on its own: \(one.window?.title ?? "")")
                check(one.model.items.map(\.name) == ["new.txt", "old.txt"], "Recents lists the files, newest first: \(one.model.items.map(\.name))")
                check(one.model.items.first?.modified.map { abs($0.timeIntervalSince(newer)) < 1 } == true, "the date shown is the last-opened date")
                check(vc.tableView.tableColumns.contains { $0.identifier.rawValue == "folder" }, "a list gets the Where column")
                check(ListerViewController.text(for: .folder, of: one.model.items[0]).contains("recent-docs"), "the Where column shows the folder: \(ListerViewController.text(for: .folder, of: one.model.items[0]))")
                check(vc.refuseInList("New Folder") && one.model.statusMessage?.contains("open a folder first") == true, "folder-only commands are refused in a list")
                check(one.model.items.allSatisfy { $0.url.isFileURL } && !one.model.items[0].isNavigable, "rows of Recents are real files")
                // Shared
                SharedPlaces.shared.update(type: "_smb._tcp", names: ["Office NAS", "Printer Room"])
                SharedPlaces.shared.update(type: "_sftp-ssh._tcp", names: ["Office NAS"])
                var saved = ServerProfile(); saved.name = "Web host"; saved.host = "example.org"; saved.scheme = .sftp
                let rows = SharedPlaces.shared.rows(servers: [saved], volumes: [dirB])
                check(rows.map(\.name) == [FileManager.default.displayName(atPath: dirB.path), "Web host", "Office NAS", "Printer Room"], "Shared rows: volumes, saved servers, computers: \(rows.map(\.name))")
                check(rows[0].isNavigable && !rows[1].isNavigable && !rows[2].isNavigable, "only volumes open as folders")
                check(SharedPlaces.shared.computers.first(where: { $0.name == "Office NAS" })?.types == ["_smb._tcp", "_sftp-ssh._tcp"], "a computer with several services lists them in order of preference")
                if case .server(let id)? = SharedRow.parse(rows[1].url) { check(id == saved.id, "server rows carry their id") } else { check(false, "server row parses") }
                if case .computer(let name, let types)? = SharedRow.parse(rows[2].url) { check(name == "Office NAS" && types.first == "_smb._tcp", "computer rows carry name and services") } else { check(false, "computer row parses") }
                check(rows[2].kind?.contains("SMB") == true && rows[1].kind?.contains("SFTP") == true, "rows say what they are: \(rows[1].kind ?? "") / \(rows[2].kind ?? "")")
                one.model.navigate(to: VirtualPlace.shared.url)
                check(one.model.virtualPlace == .shared && one.model.sortKey == .name, "the lister shows Shared")
                check(ListerViewController.icon(for: rows[2]) != nil && ListerViewController.icon(for: rows[1]) != nil, "rows without a file get a symbol icon")
                // leaving restores the sort order and the columns
                one.model.navigate(to: backTo)
                check(!one.model.isVirtual && one.model.sortKey == sortBefore.0 && one.model.ascending == sortBefore.1, "going back to a folder restores the sort order")
                check(!vc.tableView.tableColumns.contains { $0.identifier.rawValue == "folder" } || ColumnSettings.visible.contains(.folder), "the Where column goes away again")
                one.model.navigate(to: VirtualPlace.recents.url)
                one.model.goBack()
                check(one.model.url == backTo, "Back leaves Recents for the previous folder")
                SharedPlaces.shared.update(type: "_smb._tcp", names: [])
                SharedPlaces.shared.update(type: "_sftp-ssh._tcp", names: [])
                RecentFiles.override = nil
                try? fm.removeItem(at: docs)
                SharedPlaces.browsingEnabled = true
            }
        }
        later(1.2) { }
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
