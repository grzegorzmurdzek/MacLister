import AppKit

/// `MacLister --selftest-workspaces --quiet`: saving the open listers as named workspaces, opening them in place of
/// the open listers or in addition to them, what a workspace keeps (icons or list, sorting, columns), the store
/// (names, rename, duplicate, order, a file that cannot be read), the menu. PASS/FAIL lines go to ~/Library/Logs/MacLister.log.
enum SelfTestWorkspaces {
    private static var failures = 0
    private static var steps: [(delay: Double, run: () -> Void)] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("workspaces \(condition ? "ok  " : "FAIL") \(message)")
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
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-workspaces-\(UUID().uuidString)")
        let support = root.appendingPathComponent("support")
        AppSupport.override = support
        let dirA = root.appendingPathComponent("Alpha"), dirB = root.appendingPathComponent("Beta"), dirC = root.appendingPathComponent("Gamma")
        for dir in [support, dirA, dirB, dirC] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        // stored values as they were (nil: never set), put back at the end
        let keys = ["visibleColumns", "columnWidths", "iconSize", "startupWorkspaceID"]
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        let manager = ListerManager.shared
        let store = WorkspaceStore.shared
        store.reload()
        check(store.workspaces.isEmpty, "a fresh support folder has no workspaces")

        // 1. The store: names, rename, duplicate, order, delete.
        let first = store.add(name: "  Work   desk ", listers: [])
        check(first.name == "Work desk", "the name is cleaned up: '\(first.name)'")
        let second = store.add(name: "work DESK", listers: [])
        check(second.name == "work DESK 2" || second.name.lowercased() == "work desk 2", "a name that is taken gets a number: '\(second.name)'")
        check(!store.rename(second.id, to: "WORK desk") && !store.rename(second.id, to: "   "), "rename refuses a taken or an empty name")
        check(store.rename(second.id, to: "Music") && store.workspace(named: "music")?.id == second.id, "rename works and the name is found without case")
        let copy = store.duplicate(second.id)
        check(copy != nil && copy?.name == "Music copy" && store.workspaces.map(\.name) == ["Work desk", "Music", "Music copy"], "duplicate follows the original: \(store.workspaces.map(\.name))")
        store.move(from: IndexSet(integer: 2), to: 0)
        check(store.workspaces.map(\.name) == ["Music copy", "Work desk", "Music"], "move changes the order: \(store.workspaces.map(\.name))")
        store.reload()
        check(store.workspaces.map(\.name) == ["Music copy", "Work desk", "Music"], "the workspaces are read back from the file")
        UserDefaults.standard.set(first.id.uuidString, forKey: "startupWorkspaceID")
        store.remove(copy!.id)
        check(store.workspaces.count == 2, "delete removes it")
        store.remove(first.id)
        check(Settings.startupWorkspaceID.isEmpty, "deleting the workspace chosen for launch goes back to the last session")
        store.remove(second.id)

        // 1b. A file that cannot be read is kept, not lost.
        let file = support.appendingPathComponent("workspaces.json")
        try? Data("not json".utf8).write(to: file)
        store.reload()
        check(store.workspaces.isEmpty && fm.fileExists(atPath: file.appendingPathExtension("bak").path), "an unreadable workspaces.json is copied to .bak")
        try? fm.removeItem(at: file)
        store.reload()

        // 2. Save: two listers, one as icons with a sort order and a name, columns that are not the default.
        ColumnSettings.setVisible([.size, .date, .kind])
        Settings.iconSize = IconGridMetrics.sizes.last ?? IconGridMetrics.defaultSize
        let one = manager.openLister(directory: dirA, anchor: .cursor(NSPoint(x: 200, y: 700), centered: false))
        let two = manager.openLister(directory: dirB, anchor: .cursor(NSPoint(x: 700, y: 700), centered: false))
        var workspace: Workspace!
        later {
            one.model.setShowAsIcons(true, remember: false)
            two.model.apply(sort: .size, ascending: false, showHidden: true, filter: "*.txt")
            two.model.setLabel("Second", color: nil)
            manager.toggleRole(.source, for: one)
            manager.toggleRole(.destination, for: two)
            workspace = store.addCurrent(name: "Two", from: manager)
            check(workspace.listers.count == 2 && workspace.listers.map(\.icons) == [true, false], "the workspace keeps both listers and icons or list for each: \(workspace.listers.map(\.icons))")
            check(workspace.view?.columns == ["size", "date", "kind"], "…and the columns: \(String(describing: workspace.view?.columns))")
            // after saving the look changes, to see it come back
            ColumnSettings.setVisible([.size])
            Settings.iconSize = IconGridMetrics.defaultSize
            manager.closeAll()
        }

        // 3. Open in place of the open listers (there are none now), then again while some are open.
        later(0.6) {
            check(manager.openCount == 0, "all listers closed")
            let opened = store.open(workspace.id, replace: true)
            check(opened == 2, "the workspace opens two listers: \(opened)")
        }
        later(0.6) {
            let all = manager.menuOrder.map(\.controller)
            guard all.count == 2 else { check(false, "two listers after opening: \(all.count)"); return }
            check(all[0].model.url.standardizedFileURL == dirA.standardizedFileURL && all[0].model.showAsIcons, "the first lister shows its folder as icons again")
            check(all[1].model.url.standardizedFileURL == dirB.standardizedFileURL && !all[1].model.showAsIcons, "the second lister shows its folder as a list")
            check(all[1].model.sortKey == .size && !all[1].model.ascending && all[1].model.showHidden && all[1].model.filter == "*.txt" && all[1].model.label == "Second",
                  "sorting, hidden files, filter and name are back")
            check(all[0].model.role == .source && all[1].model.role == .destination, "the roles are back")
            check(ColumnSettings.visible == [.name, .size, .date, .kind] && Settings.iconSize == (IconGridMetrics.sizes.last ?? IconGridMetrics.defaultSize),
                  "opening in place of the listers brings the columns and icon size of the workspace: \(ColumnSettings.visible.map(\.rawValue))")
            // In addition: the others stay, and the look of the app is left alone.
            ColumnSettings.setVisible([.size])
            let added = store.open(workspace.id, replace: false)
            check(added == 2 && manager.openCount == 4, "opened in addition: two more listers, the two before stay (\(manager.openCount))")
            check(ColumnSettings.visible == [.name, .size], "…and the columns are left as they are")
        }

        // 4. A folder that is gone is skipped and reported.
        later(0.6) {
            manager.closeAll()
        }
        later(0.6) {
            try? fm.removeItem(at: dirB)
            let current = store.workspace(id: workspace.id)
            check(current?.missingFolders == [dirB.path], "a missing folder is listed: \(current?.missingFolders ?? [])")
            check(store.open(workspace.id, replace: true) == 1 && manager.openCount == 1, "only the folder that exists opens")
        }

        // 5. Update from the open listers.
        later(0.6) {
            let before = store.workspace(id: workspace.id)?.modified
            let extra = manager.openLister(directory: dirC, anchor: .cursor(NSPoint(x: 400, y: 600), centered: false))
            _ = extra
            store.update(workspace.id, from: manager)
            let after = store.workspace(id: workspace.id)
            check(after?.listers.count == 2 && after?.listers.last?.path == dirC.path && (after?.modified ?? .distantPast) >= (before ?? .distantFuture),
                  "Update replaces the saved listers with the open ones: \(after?.listers.map(\.path) ?? [])")
        }

        // 6. Menu: a workspace opens on a click, a second item (⌥) adds it; Save and Manage are there.
        later {
            let menu = NSMenu()
            WorkspaceActions.shared.populate(menu)
            let titles = menu.items.map(\.title)
            check(titles.first == "Two" && menu.items[1].isAlternate && menu.items[1].keyEquivalentModifierMask == .option,
                  "the menu lists the workspace, and the ⌥ alternate adds it: \(titles)")
            check(titles.contains(tr("Save Open Listers as Workspace…")) && titles.contains(tr("Manage Workspaces…")), "the menu can save and manage")
            let empty = NSMenu()
            store.remove(workspace.id)
            WorkspaceActions.shared.populate(empty)
            check(empty.items.first?.title == tr("No workspaces") && empty.items.first?.isEnabled == false, "with none saved the menu says so")
        }

        // 7. The last session keeps icons or list too (layouts saved before it was kept still open).
        later {
            manager.closeAll()
        }
        later(0.5) {
            let lister = manager.openLister(directory: dirA, anchor: .cursor(NSPoint(x: 300, y: 600), centered: false))
            lister.model.setShowAsIcons(true, remember: false)
            check(LayoutStore.save(from: manager) == 1, "the last session saves")
            manager.closeAll()
            let old = """
            [{"path":"\(dirA.path)","x":100,"y":100,"width":600,"height":400,"role":"none","sort":"name","ascending":true,"showHidden":false,"filter":""}]
            """
            try? Data(old.utf8).write(to: LayoutStore.url)
            check((try? JSONDecoder().decode([ListerSnapshot].self, from: Data(old.utf8)))?.first?.icons == nil, "a layout saved before icons were kept reads fine")
        }
        later(0.6) {
            check(LayoutStore.restore(into: manager) == 1, "…and opens")
        }

        runSteps {
            for key in keys {
                if let value = domain[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            NotificationCenter.default.post(name: .columnsChanged, object: nil)
            manager.closeAll()
            AppSupport.override = nil
            store.reload()
            try? fm.removeItem(at: root)
            DebugLog.write("workspaces \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
            NSApp.terminate(nil)
        }
    }
}
