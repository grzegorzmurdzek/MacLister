import AppKit

/// `MacLister --selftest-dual`: the two-panel window — opening it (also through the setting), the roles that follow
/// the pane you work in, Tab between the panes, Copy to the other pane, a lister you make the destination, no tabs,
/// the menus, layouts and closing. PASS/FAIL lines go to ~/Library/Logs/MacLister.log.
enum SelfTestDual {
    private static var failures = 0
    private static var steps: [(delay: Double, run: () -> Void)] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("dual \(condition ? "ok  " : "FAIL") \(message)")
    }

    private static func later(_ delay: Double = 0.3, _ run: @escaping () -> Void) { steps.append((delay, run)) }

    private static func runSteps(_ done: @escaping () -> Void) {
        guard !steps.isEmpty else { done(); return }
        let step = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
            step.run()
            runSteps(done)
        }
    }

    /// Tab pressed in a pane's file list, as the keyboard would.
    private static func pressTab(in pane: ListerWindowController) {
        guard let table = pane.listerViewController?.tableView, let window = pane.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "\t",
                                           charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { return }
        table.keyDown(with: event)
    }

    private static func menuTitles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { [$0.title] + ($0.submenu.map(menuTitles) ?? []) }
    }

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-dual-\(UUID().uuidString)")
        let support = root.appendingPathComponent("support")
        AppSupport.override = support
        let dirA = root.appendingPathComponent("Alpha"), dirB = root.appendingPathComponent("Beta"), dirC = root.appendingPathComponent("Gamma")
        for dir in [support, dirA, dirB, dirC] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let file = dirA.appendingPathComponent("report.txt")
        try? "two panels".write(to: file, atomically: true, encoding: .utf8)
        // the stored value itself, put back as it was at the end (nil: never set)
        let styleBefore = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0)?["newWindowStyle"] }
        let manager = ListerManager.shared

        // 0. By default a desktop click opens a lister, as before.
        UserDefaults.standard.removeObject(forKey: "newWindowStyle")
        check(Settings.newWindowStyle == .lister, "a lister by default")
        let plain = manager.openNew(directory: dirC, anchor: .cursor(NSPoint(x: 200, y: 700), centered: false))
        check(!plain.isPane && manager.openCount == 1 && manager.dualWindows.isEmpty, "the default opens a lister window")
        plain.close()

        // 1. The setting: a two-panel window, both panes listers of one window, left the source, right the destination.
        Settings.newWindowStyle = .twoPanel
        var dual: DualListerWindowController!
        var left: ListerWindowController!, right: ListerWindowController!
        later {
            check(manager.openCount == 0, "the lister closed")
            left = manager.openNew(directory: dirA, anchor: .cursor(NSPoint(x: 300, y: 800), centered: false))
            dual = left.dualHost
            right = dual?.rightPane
            check(dual != nil && left.isPane && right?.isPane == true && left === dual?.leftPane, "the setting opens a two-panel window")
            check(manager.openCount == 2 && manager.dualWindows.count == 1, "its two panes are listers: \(manager.openCount)")
            check(left.window != nil && left.window === right?.window && left.window === dual?.window, "both panes are in one window")
            check(left.window?.tabbingMode == .disallowed, "the two-panel window takes no tabs")
            check(right?.model.url.standardizedFileURL == dirA.standardizedFileURL, "the right pane starts on the same folder")
            check(left.model.role == .source && right?.model.role == .destination, "left is the source, right the destination: \(left.model.role), \(right?.model.role ?? .none)")
            check(dual?.activePane === left, "the left pane has the keyboard")
            check(manager.frontmost === left, "the pane you work in is the frontmost lister")
        }
        later(0.5) {
            check(left.window?.title == "Alpha", "the window has the title of the pane you work in: \(left.window?.title ?? "nil")")
            let widths = [left, right].compactMap { $0.listerViewController?.view.frame.width }
            check(widths.count == 2 && abs(widths[0] - widths[1]) < 3, "the panes are equally wide: \(widths)")
            right.model.navigate(to: dirB)
        }

        // 2. Copy (F5) from the pane you work in to the other one.
        later(0.5) {
            let row = left.model.items.first { $0.name == "report.txt" }?.url      // /private/var…, as the list has it
            left.listerViewController?.select(urls: Set([row].compactMap { $0 }))
            check(row != nil && left.model.selectedURLs == row.map { [$0] }, "a file is selected in the left pane")
            left.listerViewController?.startTransfer(.copy)
        }
        later(1.2) {
            check(fm.fileExists(atPath: dirB.appendingPathComponent("report.txt").path), "Copy copies into the folder of the other pane")
        }

        // 3. Tab moves to the other pane, and the roles go along.
        later {
            pressTab(in: left)
        }
        later {
            check(dual.activePane === right, "Tab gives the keyboard to the other pane")
            check(right.window?.firstResponder === right.listerViewController?.tableView, "the right file list has the keyboard")
            check(right.model.role == .source && left.model.role == .destination, "the right pane is now the source: \(right.model.role), \(left.model.role)")
            check(left.window?.title == "Beta", "the title follows the pane: \(left.window?.title ?? "nil")")
            check(manager.neighbour(of: right, forward: true) === left && manager.neighbour(of: left, forward: false) === right,
                  "Tab and Shift-Tab stay in the window")
            dual.focus(left)          // a click in the left pane
        }
        later {
            check(left.model.role == .source && right.model.role == .destination, "back in the left pane: it is the source again")
        }

        // 4. A lister you make the destination keeps it while you work in the panes.
        var single: ListerWindowController!
        later {
            single = manager.openLister(directory: dirC, anchor: .cursor(NSPoint(x: 900, y: 600), centered: false))
            check(!single.isPane && single.model.role == .none, "a lister beside the two-panel window gets no role")
            manager.toggleRole(.destination, for: single)
            check(single.model.role == .destination && right.model.role == .none, "the lister takes the destination from the right pane")
            dual.activate(left, takeDestination: false)          // back to the window
            check(left.model.role == .source && single.model.role == .destination && right.model.role == .none,
                  "coming back to the window keeps the lister as the destination")
            dual.focus(right)
            check(right.model.role == .source && single.model.role == .destination && left.model.role == .none,
                  "the other pane becomes the source, the lister stays the destination")
            manager.toggleRole(.destination, for: left)
            dual.focus(left)
            check(left.model.role == .source && right.model.role == .destination && single.model.role == .none,
                  "once a pane is the destination again, the roles follow the panes")
        }

        // 5. A locked pane keeps the roles where they are.
        later {
            manager.toggleRoleLock(for: left)
            dual.focus(right)
            check(left.model.role == .source && left.model.roleLocked && right.model.role == .destination, "a locked pane keeps its role")
            manager.toggleRoleLock(for: left)
            dual.focus(left)
        }

        // 6. No tabs in a two-panel window; the menus know it.
        later {
            check(manager.newTab(from: left) == nil && manager.openCount == 3, "New Tab opens nothing in a two-panel window")
            check(left.model.statusMessage == "A two-panel window has no tabs", "…and says why: \(left.model.statusMessage ?? "nil")")
            manager.mergeAllListers(into: single)
            check(single.window !== left.window && manager.tabs(of: single).count == 1, "Merge All Listers leaves the two-panel window alone")
            if let menu = left.listerViewController?.makeTitleBarMenu() {
                let titles = menuTitles(menu)
                check(titles.contains("Close Two-Panel Window") && titles.contains("New Two-Panel Window") && !titles.contains("New Tab"),
                      "the title-bar menu: close the window, a new one, no tabs")
            } else {
                check(false, "the title-bar menu")
            }
            let order = manager.menuOrder
            if let index = order.firstIndex(where: { $0.controller === left }), order.indices.contains(index + 1) {
                check(order[index + 1].controller === right && order[index + 1].isTab, "the menus list the right pane under the left one")
            } else {
                check(false, "the panes are in the menus")
            }
        }

        // 7. Split into Two Listers: each pane a lister window where it was, with its model; Join puts them back.
        var parted: [ListerWindowController] = []
        var paneFrames: [NSRect] = []
        later {
            left.model.apply(sort: .size, ascending: false, showHidden: true, filter: "*.txt")
            paneFrames = dual.paneFramesOnScreen
            let models = dual.panes.map(\.model)
            parted = manager.splitTwoPanel(dual)
            check(parted.count == 2 && parted.allSatisfy { !$0.isPane } && manager.dualWindows.allSatisfy { $0 !== dual },
                  "Split makes two lister windows of the panes")
            check(parted.count == 2 && zip(parted, models).allSatisfy { $0.model === $1 }, "…which keep the panes' listers (folder, history, filter)")
            check(manager.openCount == 3, "still three listers: \(manager.openCount)")
        }
        later(0.5) {
            guard parted.count == 2 else { return }
            check(parted[0].model.url.standardizedFileURL == dirA.standardizedFileURL && parted[0].model.filter == "*.txt"
                  && parted[1].model.url.standardizedFileURL == dirB.standardizedFileURL, "the left lister shows Alpha with its filter, the right Beta")
            check(parted[0].model.role == .source && parted[1].model.role == .destination, "the roles stay: \(parted[0].model.role), \(parted[1].model.role)")
            let contents = parted.compactMap { $0.window.map { $0.contentRect(forFrameRect: $0.frame) } }
            check(contents.count == 2 && zip(contents, paneFrames).allSatisfy { abs($0.minX - $1.minX) < 2 && abs($0.width - $1.width) < 2 },
                  "each lister is where its pane was: \(contents) \(paneFrames)")
            check(manager.joinPartner(for: parted[1]) === parted[0], "the partner of the destination is the source")
            let joined = manager.joinIntoTwoPanel(parted[1])
            check(joined != nil && joined?.leftPane.model === parted[0].model && joined?.rightPane.model === parted[1].model,
                  "Join puts the left lister in the left pane, the right one in the right")
            check(joined?.activePane === joined?.rightPane && parted[1].model.role == .source && parted[0].model.role == .destination,
                  "the lister you joined from is the pane you work in, the source")
            check(manager.openCount == 3 && manager.dualWindows.count == 1 && parted.allSatisfy { $0.window?.isVisible != true },
                  "the two lister windows are gone, one two-panel window instead")
            if let joined {
                dual = joined
                left = joined.leftPane
                right = joined.rightPane
                check(left.model.filter == "*.txt", "the joined pane keeps its filter")
                check(manager.joinPartner(for: left) == nil, "a pane joins nothing")
                left.model.setFilter("")
                dual.focus(left)
            }
        }

        // 8. A layout brings the two-panel window back with both folders.
        later {
            check(LayoutStore.save(from: manager) == 3, "the layout saves both panes and the lister")
            manager.closeAll()
        }
        later(0.6) {
            check(manager.openCount == 0 && manager.dualWindows.isEmpty, "Close All closes the two-panel window too")
            check(LayoutStore.restore(into: manager) == 3, "the layout opens three listers")
        }
        later(0.6) {
            check(manager.dualWindows.count == 1 && manager.openCount == 3, "…as one two-panel window and a lister")
            if let restored = manager.dualWindows.first {
                check(restored.leftPane.model.url.standardizedFileURL == dirA.standardizedFileURL
                      && restored.rightPane.model.url.standardizedFileURL == dirB.standardizedFileURL, "each pane shows its folder again")
                check(restored.leftPane.model.role == .source && restored.rightPane.model.role == .destination, "and has its role again")
                restored.window?.performClose(nil)
            }
        }

        // 9. Closing the window closes both panes.
        later(0.6) {
            check(manager.openCount == 1 && manager.dualWindows.isEmpty && manager.allControllers.allSatisfy { !$0.isPane },
                  "closing the window removes both panes")
        }

        runSteps {
            UserDefaults.standard.set(styleBefore, forKey: "newWindowStyle")      // nil removes it
            manager.closeAll()
            AppSupport.override = nil
            try? fm.removeItem(at: root)
            DebugLog.write("dual \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
            NSApp.terminate(nil)
        }
    }
}
