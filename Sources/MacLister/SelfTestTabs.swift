import AppKit

/// `MacLister --selftest-tabs`: tabs in real lister windows — opening, naming, roles that follow the tab you see,
/// closing, moving out, merging, layouts and the setting itself. PASS/FAIL lines go to ~/Library/Logs/MacLister.log.
enum SelfTestTabs {
    private static var failures = 0
    private static var steps: [(delay: Double, run: () -> Void)] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("tabs \(condition ? "ok  " : "FAIL") \(message)")
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

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-tabs-\(UUID().uuidString)")
        let support = root.appendingPathComponent("support")
        AppSupport.override = support
        let dirA = root.appendingPathComponent("Alpha"), dirB = root.appendingPathComponent("Beta"), dirC = root.appendingPathComponent("Gamma")
        for dir in [support, dirA.appendingPathComponent("inner"), dirB, dirC] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        // the stored value itself (nil: never set, so the default applies), put back as it was at the end
        // (the persistent domain only: object(forKey:) would also answer with the registered default)
        let tabsBefore = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0)?["listerTabs"] }
        let manager = ListerManager.shared

        // 0. Tabs are on unless you turn them off. Off, nothing changes: ⌘T only explains.
        UserDefaults.standard.removeObject(forKey: "listerTabs")
        check(Settings.listerTabs, "tabs are on by default")
        Settings.listerTabs = false
        var one = manager.openLister(directory: dirA, anchor: .cursor(NSPoint(x: 300, y: 700), centered: false))
        check(one.window?.tabbingMode == .disallowed, "tabs off: the window takes no tabs")
        check(manager.newTab(from: one) == nil && manager.openCount == 1, "tabs off: New Tab opens nothing")
        check(one.model.statusMessage?.contains("Settings") == true, "tabs off: New Tab says where to turn tabs on: \(one.model.statusMessage ?? "nil")")

        // 1. Tabs on: ⌘T opens the same folder in a tab of the same window.
        Settings.listerTabs = true
        manager.applyTabSetting()
        check(one.window?.tabbingMode == .automatic, "tabs on: the window takes tabs")
        one.model.apply(sort: .size, ascending: false, showHidden: true, filter: "*.txt")
        var two: ListerWindowController!
        later {
            two = manager.newTab(from: one)
            check(two != nil && manager.tabs(of: one).count == 2 && manager.tabs(of: one).last === two, "New Tab adds a second tab after the first")
            check(two?.model.url.standardizedFileURL == dirA.standardizedFileURL, "the new tab shows the same folder")
            check(two?.model.sortKey == .size && two?.model.ascending == false && two?.model.showHidden == true && two?.model.filter == "",
                  "the new tab keeps the sort order and hidden files, not the filter")
            check(two?.window?.frame == one.window?.frame, "the tabs share the window frame")
            check(manager.isSelectedTab(two) && !manager.isSelectedTab(one), "the new tab is the one shown")
        }

        // 2. Tab titles: the folder's name, else the name you give it; it follows navigation.
        later {
            check(one.window?.tab.title == "Alpha", "a tab is called after its folder: \(one.window?.tab.title ?? "nil")")
            two.model.navigate(to: dirB)
        }
        later(0.5) {
            check(two.window?.tab.title == "Beta", "the tab title follows the folder: \(two.window?.tab.title ?? "nil")")
            two.model.setLabel("Backup", color: "orange")
        }
        later {
            check(two.window?.tab.title == "Backup", "a named tab keeps its name: \(two.window?.tab.title ?? "nil")")
            check(two.window?.tab.accessoryView is TabColorDot, "the label colour shows as a dot in the tab")
            check(two.listerViewController?.nameMenuTitle == "Rename This Tab…", "the name command speaks of the tab: \(two.listerViewController?.nameMenuTitle ?? "nil")")
            two.model.navigate(to: dirC)
        }
        later(0.5) {
            check(two.window?.tab.title == "Backup", "the name stays when the tab goes to another folder")
            two.model.setLabel("", color: nil)
        }
        later {
            check(two.window?.tab.title == "Gamma" && two.window?.tab.accessoryView == nil, "removing the name brings the folder's name back")
        }

        // 2b. A right-click on a tab is about that tab: find each tab's button by its title and ask which tab is there.
        var third: ListerWindowController?
        later {
            third = manager.openFolder(dirA.appendingPathComponent("inner"), inNewTabFrom: two)
        }
        later(0.8) {
            guard let window = (manager.tabs(of: one).first(where: manager.isSelectedTab)?.window) as? ListerWindow,
                  let frameView = window.contentView?.superview else { check(false, "tab bar reachable"); return }
            func buttons(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { String(describing: type(of: $0)).contains("TabButton") ? [$0] : buttons($0) }
            }
            func text(_ view: NSView) -> String {
                if let field = view as? NSTextField { return field.stringValue }
                return view.subviews.map(text).joined()
            }
            var found = 0
            for tab in manager.tabs(of: one) {
                guard let title = tab.window?.tab.title,
                      let button = buttons(frameView).first(where: { text($0) == title && !$0.isHidden }) else { continue }
                let frame = button.convert(button.bounds, to: nil)
                let hit = window.tab(at: NSPoint(x: frame.midX, y: frame.midY))
                check(hit === tab.window, "a click on the tab “\(title)” is about that tab")
                found += 1
            }
            check(found == 3, "all three tab buttons were found (\(found))")
            check(window.tab(at: NSPoint(x: 10, y: 10)) == nil, "a click in the list is not on a tab")
            third?.close()
        }

        // 3. Roles belong to the window: they go to the tab you see.
        later {
            manager.toggleRole(.source, for: two)
            check(two.model.role == .source, "the shown tab becomes the source")
            manager.select(one)
        }
        later {
            check(one.model.role == .source && two.model.role == .none, "switching tabs takes the source role along")
            check(manager.sourceController === one, "copying takes the tab you see as the source")
            manager.toggleRoleLock(for: one)
            manager.selectNeighbourTab(of: one, forward: true)
        }
        later {
            check(manager.isSelectedTab(two), "next tab shows the second tab")
            check(two.model.role == .source && two.model.roleLocked && !one.model.roleLocked, "the lock goes along with the role")
            manager.selectNeighbourTab(of: two, forward: true)
        }
        later {
            check(manager.isSelectedTab(one), "next tab wraps around to the first")
            manager.toggleRoleLock(for: one)
        }

        // 4. A second window: Tab goes between windows, never to a hidden tab; the menu lists tabs under their window.
        var three: ListerWindowController!
        later {
            three = manager.openLister(directory: dirC, anchor: .cursor(NSPoint(x: 1000, y: 700), centered: false))
            manager.toggleRole(.destination, for: three)
            check(manager.neighbour(of: one, forward: true) === three && manager.neighbour(of: three, forward: true) === one,
                  "Tab skips the hidden tab")
            let order = manager.menuOrder
            check(order.count == 3 && order[0].controller === one && order[1].controller === two && order[1].isTab && !order[2].isTab,
                  "the menu lists the tabs of a window together, the later ones indented")
        }

        // 5. Layout: tabs, the shown tab and the roles come back.
        later {
            two.model.setLabel("Second", color: nil)
            check(LayoutStore.save(from: manager) == 3, "the layout saves all three listers")
            if let data = try? Data(contentsOf: LayoutStore.url), let saved = try? JSONDecoder().decode([ListerSnapshot].self, from: data) {
                check(saved.map(\.tabGroup) == [0, 0, nil] && saved.map(\.selectedTab) == [true, false, nil],
                      "the layout knows which listers were tabs and which one was shown: \(saved.map(\.tabGroup)) \(saved.map(\.selectedTab))")
            } else {
                check(false, "layout file readable")
            }
            manager.closeAll()
        }
        later(0.6) {
            check(manager.openCount == 0, "all listers closed")
            check(LayoutStore.restore(into: manager) == 3, "the layout opens three listers")
        }
        later(0.6) {
            let all = manager.menuOrder.map(\.controller)
            guard all.count == 3 else { check(false, "three listers after restore"); return }
            let tabs = manager.tabs(of: all[0])
            check(tabs.count == 2 && tabs[1].model.label == "Second", "restored: the first window has its two tabs again, the second named")
            check(manager.isSelectedTab(tabs[0]) && tabs[0].model.role == .source && tabs[1].model.role == .none, "restored: the shown tab and its role")
            check(manager.tabs(of: all[2]).count == 1 && all[2].model.role == .destination, "restored: the separate window is still the destination")
            one = tabs[0]; two = tabs[1]; three = all[2]
        }

        // 6. Closing the tab that holds the role leaves the role with the window.
        later {
            one.close()
        }
        later(0.5) {
            check(manager.openCount == 2 && two.model.role == .source,
                  "closing the source tab leaves the source role with the tab shown next (\(manager.openCount) open, \(two.model.role))")
        }

        // 7. Merge all windows into tabs; move a tab out again.
        later {
            manager.mergeAllListers(into: three)
        }
        later(0.6) {
            let tabs = manager.tabs(of: three)
            check(tabs.count == 2, "merge: both listers are tabs of one window")
            check(manager.isSelectedTab(three) && three.model.role != .none && two.model.role == .none,
                  "merge: only the tab you see keeps a role (\(three.model.role), \(two.model.role))")
            manager.select(two)
        }
        later {
            manager.moveTabToNewLister(two)
        }
        later(0.6) {
            check(manager.tabs(of: two).count == 1 && manager.tabs(of: three).count == 1, "Move Tab to New Lister makes two windows again")
            check(two.window?.isVisible == true && three.window?.isVisible == true, "both windows are visible")
        }

        // 8. Turning tabs off splits every window into listers of their own.
        later {
            manager.mergeAllListers(into: two)
        }
        later(0.5) {
            check(manager.tabs(of: two).count == 2, "merged again")
            Settings.listerTabs = false
            manager.applyTabSetting()
        }
        later(0.6) {
            check(manager.allControllers.allSatisfy { manager.tabs(of: $0).count == 1 && $0.window?.tabbingMode == .disallowed },
                  "tabs off: every tab is a lister window of its own")
        }

        runSteps {
            UserDefaults.standard.set(tabsBefore, forKey: "listerTabs")      // nil removes it
            manager.closeAll()
            AppSupport.override = nil
            try? fm.removeItem(at: root)
            DebugLog.write("tabs \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
            NSApp.terminate(nil)
        }
    }
}
