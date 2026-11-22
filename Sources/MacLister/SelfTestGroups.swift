import AppKit

/// `MacLister --selftest-groups --quiet`: grouping the files of a folder (Finder's Group By): which group a file
/// goes into and the order of the groups, the headers in the list and in the icon view, selection and the rows
/// under the headers, what is remembered for each folder, and where grouping is not offered.
/// PASS/FAIL lines go to ~/Library/Logs/MacLister.log.
enum SelfTestGroups {
    private static var failures = 0
    private static var steps: [(delay: Double, run: () -> Void)] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("groups \(condition ? "ok  " : "FAIL") \(message)")
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

    private static func item(_ name: String, directory: Bool = false, size: Int64? = nil, modified: Date? = nil,
                             kind: String? = nil, tags: [String] = []) -> FileItem {
        var made = FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: directory, isPackage: false,
                            isHidden: false, size: size, modified: modified)
        made.kind = kind
        made.tags = tags
        return made
    }

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-groups-\(UUID().uuidString)")
        let support = root.appendingPathComponent("support")
        AppSupport.override = support
        ViewModeStore.shared.reload()
        let dir = root.appendingPathComponent("Files"), other = root.appendingPathComponent("Other")
        for folder in [support, dir, other, dir.appendingPathComponent("Sub")] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }

        // 1. Which group, and in which order (a fixed "now": 22 November 2026, noon).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!
        func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))! }
        func modified(_ date: Date?) -> GroupBucket { Grouping.bucket(for: item("f", modified: date), by: .modified, now: now, calendar: calendar) }
        let dates: [(Date?, String)] = [
            (day(2026, 11, 22, hour: 1), tr("Today")), (day(2026, 11, 21, hour: 23), tr("Yesterday")), (day(2026, 11, 17), tr("Previous 7 Days")),
            (day(2026, 11, 2), tr("Previous 30 Days")), (day(2026, 3, 30), "Marzec"), (day(2025, 5, 1), "2025"), (nil, tr("Unknown")),
        ]
        for (date, title) in dates {
            let bucket = modified(date)
            check(bucket.title.localizedCaseInsensitiveCompare(title) == .orderedSame || (title == "Marzec" && !bucket.title.isEmpty && bucket.order > 10 && bucket.order < 100),
                  "\(date.map { "\($0)" } ?? "no date") goes under “\(title)”: got “\(bucket.title)”")
        }
        let ordered = dates.map { modified($0.0) }
        check(ordered == ordered.sorted(), "the groups run from today back to the oldest, and no date comes last: \(ordered.map(\.title))")
        check(modified(day(2026, 11, 23)).title == tr("Today"), "a date in the future counts as today")
        check(modified(day(2026, 1, 15)).order < modified(day(2026, 1, 5)).order || modified(day(2026, 1, 15)).title == modified(day(2026, 1, 5)).title,
              "two dates of one month share a group")
        func size(_ bytes: Int64?, directory: Bool = false) -> GroupBucket { Grouping.sizeBucket(item("s", directory: directory, size: bytes)) }
        check([size(nil, directory: true), size(3_000_000_000), size(200_000_000), size(20_000_000), size(2_000_000), size(200_000), size(2_000), size(20), size(0), size(nil)]
                .map(\.order) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 100], "sizes: folders, then from the largest down, empty, unknown")
        check(size(5_000).title == size(99_000).title && size(5_000).title != size(150_000).title, "files of 5 KB and 99 KB are in one group, 150 KB is not")
        func name(_ text: String) -> GroupBucket { Grouping.bucket(for: item(text), by: .name) }
        check(name("alpha").title == "A" && name("Árvíz").title == "A" && name("123").title == "#" && name(".hidden").title == "#", "names go under their first letter, anything else under #")
        check(name("123") < name("alpha") && name("alpha") < name("beta"), "# comes before the letters")
        check(Grouping.bucket(for: item("t", tags: ["Work", "Blue"]), by: .tags).title == "Blue" && Grouping.bucket(for: item("t"), by: .tags).title == tr("No Tag"),
              "a file with several tags is under the first; without a tag: No Tag")
        check(Grouping.bucket(for: item("k", kind: "PNG image"), by: .kind).title == "PNG image" && Grouping.bucket(for: item("k", directory: true), by: .kind).title == tr("Folder"),
              "kind groups by the kind's name")

        // 2. Sorting with groups keeps each group together and sorts inside it; the layout finds the runs.
        let mixed = [item("b.txt", modified: day(2025, 1, 1)), item("a.txt", modified: day(2026, 11, 22, hour: 2)), item("c.txt", modified: day(2025, 2, 1)),
                     item("d.txt", modified: day(2026, 11, 22, hour: 3)), item("Folder", directory: true, modified: day(2026, 11, 22, hour: 4))]
        let sorted = ListerModel.sorted(mixed, by: .name, ascending: true, foldersFirst: true, grouping: .modified)
        let layout = Grouping.layout(of: sorted, by: .modified)
        check(layout.count == 2 && layout.map { $0.range.count } == [3, 2] && layout.first?.title == tr("Today") && layout.last?.title == "2025",
              "two groups, Today then 2025: \(layout.map { "\($0.title) \($0.range)" })")
        check(sorted.map(\.name) == ["Folder", "a.txt", "d.txt", "b.txt", "c.txt"], "inside a group: folders first, then by name: \(sorted.map(\.name))")
        check(Grouping.layout(of: sorted, by: .none).isEmpty && Grouping.layout(of: [], by: .kind).isEmpty, "no groups without a grouping, or without files")
        check(ListerModel.sorted(mixed, by: .name, ascending: true, foldersFirst: true).map(\.name) == ["Folder", "a.txt", "b.txt", "c.txt", "d.txt"], "without a grouping the order is as before")

        // 3. A folder with files from different days.
        let today = Date()
        let files: [(String, Date)] = [("alpha.txt", today), ("beta.txt", today.addingTimeInterval(-86_400 * 1.5)), ("gamma.png", today.addingTimeInterval(-86_400 * 20)),
                                       ("delta.md", day(2025, 5, 1))]
        for (name, date) in files {
            try? Data("x".utf8).write(to: dir.appendingPathComponent(name))
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try? Data("y".utf8).write(to: other.appendingPathComponent("o.txt"))
        let manager = ListerManager.shared
        let lister = manager.openLister(directory: dir, anchor: .cursor(NSPoint(x: 200, y: 700), centered: false))
        var vc: ListerViewController? { lister.listerViewController }

        later {
            guard let vc else { check(false, "a lister"); return }
            let model = vc.model
            check(model.groupKey == .none && !vc.isGrouped && vc.tableView.numberOfRows == vc.rows.count, "a new folder is not grouped")
            check(model.canGroup, "a local folder can be grouped")
            model.setGroup(.modified)
            check(vc.isGrouped && vc.rows.count == 5, "grouped by date: \(vc.groups.map(\.title)), \(vc.rows.count) files")
            check(vc.groups.map { $0.range.count }.reduce(0, +) == vc.rows.count && vc.groups.first?.range.lowerBound == 0 && vc.groups.last?.range.upperBound == vc.rows.count,
                  "the groups cover every file once")
            check(vc.tableView.numberOfRows == vc.rows.count + vc.groups.count, "the table has a row for each file and one for each header")
            check(vc.tableView.delegate?.tableView?(vc.tableView, isGroupRow: 0) == true && vc.isHeaderTableRow(0) && !vc.isHeaderTableRow(1),
                  "the first row is a header, the next a file")
            check((0..<vc.rows.count).allSatisfy { vc.row(forTableRow: vc.tableRow(forRow: $0)) == $0 }, "table rows and files map both ways")
            let header = vc.tableView(vc.tableView, viewFor: nil, row: 0) as? GroupHeaderView
            check(header?.shownTitle == vc.groups[0].title, "the header shows the group's title: \(header?.shownTitle ?? "none")")
            let cell = vc.tableView(vc.tableView, viewFor: vc.tableView.tableColumns[0], row: vc.tableRow(forRow: 1)) as? NSTableCellView
            check(cell?.textField?.stringValue == vc.rows[1].name, "a file row shows its file: \(cell?.textField?.stringValue ?? "none")")

            vc.selectAllRows()
            check(vc.selectedItems.count == vc.rows.count && !vc.tableView.selectedRowIndexes.contains(0) && vc.tableView.selectedRowIndexes.count == vc.rows.count,
                  "Select All selects the files and not the headers")
            vc.selectNoRows()
            vc.tableView.selectRowIndexes([0], byExtendingSelection: false)
            check(vc.tableView.selectedRowIndexes.isEmpty, "a header cannot be selected")
            vc.tableView.selectRowIndexes(IndexSet(integersIn: 0..<vc.tableView.numberOfRows), byExtendingSelection: false)
            check(vc.selectedItems.count == vc.rows.count, "dragging over headers selects the files between them")
            vc.selectRows([2])
            check(vc.selectedItems.map(\.url) == [vc.rows[2].url] && model.selectedURLs == [vc.rows[2].url], "a file is selected by its index")
            vc.selectRows([])
            check(vc.tableView.clickedRow == -1 && vc.clickedRowIndex == -1, "no row clicked: -1")

            // remembered for the folder
            check(ViewModeStore.shared.group(for: dir) == .modified && model.hasSavedView && ViewModeStore.shared.mode(for: dir) == nil,
                  "the grouping is remembered for the folder, without choosing icons or list")
            model.navigate(to: other)
            check(model.groupKey == .none && !vc.isGrouped, "another folder is not grouped")
            model.navigate(to: dir)
            check(model.groupKey == .modified && vc.isGrouped, "back in the folder: grouped again")
            ViewModeStore.shared.reload()
            check(ViewModeStore.shared.group(for: dir) == .modified, "the grouping survives a reload of the file")

            // the icon view: a section for each group
            model.setShowAsIcons(true, remember: false)
            vc.applyViewMode()
            let grid = vc.collectionView
            check(grid.numberOfSections == vc.groups.count && (0..<vc.groups.count).allSatisfy { grid.numberOfItems(inSection: $0) == vc.groups[$0].range.count },
                  "the icon view has a section for each group")
            check((0...vc.rows.count).allSatisfy { grid.row(for: grid.indexPath(forRow: $0)) == $0 } && grid.indexPath(forRow: vc.groups[1].range.lowerBound).section == 1,
                  "icons and files map both ways")
            let last = vc.rows.count - 1
            vc.selectRows([0, last])
            check(vc.selectedRowIndexes == [0, last] && Set(model.selectedURLs) == [vc.rows[0].url, vc.rows[last].url], "selecting icons in different groups reaches the model")
            vc.selectAllRows()
            check(vc.selectedItems.count == vc.rows.count, "Select All selects every icon")
            vc.selectNoRows()
            let supplementary = vc.collectionView(grid, viewForSupplementaryElementOfKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)) as? GroupHeaderView
            check(supplementary?.shownTitle == vc.groups[1].title, "an icon section has its header: \(supplementary?.shownTitle ?? "none")")
            check((grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize.height == GroupHeaderView.height, "the headers have room")
            model.setShowAsIcons(false, remember: false)
            vc.applyViewMode()
            // the grouping changes while the icons are hidden: no header of the old groups is left behind in the grid
            model.setGroup(.size)
            model.setShowAsIcons(true, remember: false)
            vc.applyViewMode()
            grid.layoutSubtreeIfNeeded()
            let shown = grid.subviews.compactMap { $0 as? GroupHeaderView }
            check(Set(shown.map { Int($0.frame.minY) }).count == shown.count && shown.allSatisfy { vc.groups.map(\.title).contains($0.shownTitle) },
                  "icons come back with the headers of the new groups only: \(shown.map(\.shownTitle)) of \(vc.groups.map(\.title))")
            model.setShowAsIcons(false, remember: false)
            vc.applyViewMode()

            // the other groupings load what they need
            for key in GroupKey.allCases where key != .none && key != .modified {
                model.setGroup(key)
                check(vc.isGrouped && vc.groups.map { $0.range.count }.reduce(0, +) == vc.rows.count && !vc.groups.contains { $0.title.isEmpty }, "grouped by \(key.rawValue): \(vc.groups.map(\.title))")
            }
            model.setGroup(.kind)
            check(vc.groups.map(\.title).contains(tr("Folder")) && vc.groups.count >= 3, "grouped by kind: folders, text, image …: \(vc.groups.map(\.title))")
            model.setGroup(.name)
            check(vc.groups.map(\.title) == ["A", "B", "D", "G", "S"].filter { initial in vc.rows.contains { $0.name.uppercased().hasPrefix(initial) } },
                  "grouped by name: the first letters: \(vc.groups.map(\.title))")
            model.setGroup(.added)
            check(vc.rows.allSatisfy { $0.added != nil }, "Date Added is read for the files")
            model.setGroup(.application)
            check(vc.isGrouped && vc.groups.map { $0.range.count }.reduce(0, +) == vc.rows.count, "grouped by application: \(vc.groups.map(\.title))")

            // switching it off
            model.setGroup(.none)
            check(!vc.isGrouped && vc.tableView.numberOfRows == vc.rows.count && ViewModeStore.shared.group(for: dir) == nil && !model.hasSavedView,
                  "No grouping: plain list again, nothing remembered")
            model.setGroup(.size)
            model.forgetSavedView()
            check(model.groupKey == .none && !vc.isGrouped && !model.hasSavedView, "Forget the view also forgets the grouping")

            // where grouping is not offered
            model.setGroup(.kind)
            model.navigate(to: VirtualPlace.recents.url)
            check(!model.canGroup && model.effectiveGroup == .none, "Recents cannot be grouped")
            model.setGroup(.name)
            check(model.groupKey == .kind, "…and asking for it does nothing")
            model.navigate(to: dir)
            check(model.groupKey == .kind && vc.isGrouped, "coming back from Recents the folder is grouped again")
            model.setGroup(.none)
        }

        // 3b. The button for the button bar.
        check(ListerAction(rawValue: "groupBy") == .groupBy && ListerAction.allCases.contains(.groupBy) && ListerAction.groupBy.title == tr("Group files by"),
              "there is a Group By action for the button bar: \(ListerAction.groupBy.title)")
        check(ListerAction.groupBy.category == .navigation && ListerAction.groupBy.suggestedSymbol == "rectangle.3.group" && ListerAction.groupBy.defaultHelp != nil,
              "…with a category, an icon and a tooltip")
        check(NSImage(systemSymbolName: ListerAction.groupBy.suggestedSymbol, accessibilityDescription: nil) != nil, "…and the icon exists on this macOS")
        later {
            guard let vc else { return }
            vc.model.navigate(to: VirtualPlace.recents.url)
            vc.perform(ListerButton(title: "Group", symbol: nil, action: .groupBy))      // no menu where nothing can be grouped
            check(vc.model.statusMessage == tr("This folder cannot be grouped"), "the button says so where grouping is not possible: \(vc.model.statusMessage ?? "nothing")")
            vc.model.navigate(to: dir)
        }

        // 4. The menu offers the groups.
        later {
            guard let vc else { return }
            let menu = NSMenu()
            vc.addViewMenu(to: menu) { title, action in
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                _ = action
                return entry
            }
            let view = menu.items.first?.submenu
            let titles = view?.items.first { $0.title == tr("Group By") }?.submenu?.items.map(\.title) ?? []
            check(titles.contains(GroupKey.name.title) && titles.contains(GroupKey.lastOpened.title) && titles.contains(GroupKey.tags.title) && titles.count == GroupKey.allCases.count + 1,
                  "the View menu has Group By with every grouping: \(titles)")
        }

        runSteps {
            manager.closeAll()
            AppSupport.override = nil
            ViewModeStore.shared.reload()
            try? fm.removeItem(at: root)
            DebugLog.write("groups \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
            NSApp.terminate(nil)
        }
    }
}
