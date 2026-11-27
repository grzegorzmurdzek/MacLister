import AppKit

/// The icon view of a lister: the same rows as the list, as pictures with names. The list (NSTableView) and the grid
/// (NSCollectionView) are both there; model.showAsIcons says which one is shown. Everything that works on the
/// selection goes through the helpers here, so it does not matter which one it is.
extension ListerViewController {
    var iconMode: Bool { model.showAsIcons }

    /// The view that has the keyboard: the list or the grid.
    var listView: NSView { iconMode ? collectionView : tableView }

    var selectedRowIndexes: IndexSet {
        if iconMode { return IndexSet(collectionView.selectionIndexPaths.map { collectionView.row(for: $0) }) }
        return isGrouped ? IndexSet(tableView.selectedRowIndexes.compactMap { row(forTableRow: $0) }) : tableView.selectedRowIndexes
    }

    /// Replaces the selection with these rows.
    func selectRows(_ indexes: IndexSet) {
        if iconMode {
            collectionView.selectionIndexPaths = Set(indexes.filter { rows.indices.contains($0) }.map { collectionView.indexPath(forRow: $0) })
            syncSelectionToModel()
        } else if isGrouped {
            tableView.selectRowIndexes(IndexSet(indexes.filter { rows.indices.contains($0) }.map { tableRow(forRow: $0) }), byExtendingSelection: false)
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func scrollRowToVisible(_ row: Int) {
        if iconMode {
            guard rows.indices.contains(row) else { return }
            if row == 0, isGrouped { collectionView.scroll(.zero); return }       // all the way up: the first header shows too
            collectionView.scrollToItems(at: [collectionView.indexPath(forRow: row)], scrollPosition: .nearestVerticalEdge)
        } else {
            tableView.scrollRowToVisible(row == 0 ? 0 : tableRow(forRow: row))
        }
    }

    /// The row under the right-click that is open now, -1 for empty space.
    var clickedRowIndex: Int { iconMode ? collectionView.clickedItem : (row(forTableRow: tableView.clickedRow) ?? -1) }

    /// Where a row is, in window coordinates; nil when it is scrolled out of view.
    func rowRectInWindow(_ row: Int) -> NSRect? {
        if iconMode {
            guard rows.indices.contains(row), let item = collectionView.item(at: collectionView.indexPath(forRow: row)) else { return nil }
            let rect = item.view.convert(item.view.bounds, to: nil)
            return collectionView.visibleRect.intersects(item.view.frame) ? rect : nil
        }
        let tableRow = self.tableRow(forRow: row)
        guard tableView.visibleRect.intersects(tableView.rect(ofRow: tableRow)) else { return nil }
        return tableView.convert(tableView.rect(ofRow: tableRow), to: nil)
    }

    /// The text field with the name of a row, for Rename in place.
    func nameField(ofRow row: Int) -> NSTextField? {
        if iconMode {
            return (collectionView.item(at: collectionView.indexPath(forRow: row)) as? IconGridItem)?.nameField
        }
        guard let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return nil }
        return (tableView.view(atColumn: column, row: tableRow(forRow: row), makeIfNecessary: true) as? NSTableCellView)?.textField
    }

    // MARK: Setting up

    func configureIcons() {
        let flow = NSCollectionViewFlowLayout()
        flow.minimumInteritemSpacing = 4
        flow.minimumLineSpacing = 6
        flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView.collectionViewLayout = flow
        updateIconLayout()
        collectionView.register(IconGridItem.self, forItemWithIdentifier: IconGridItem.identifier)
        collectionView.register(GroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: GroupHeaderView.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.textBackgroundColor]       // like the list: the same background in light and dark
        collectionView.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        collectionView.onDragEnd = { [weak self] in self?.springLoader.cancel() }
        collectionView.onDoubleClick = { [weak self] in self?.handleDoubleClick(row: $0) }
        collectionView.onSelectionChange = { [weak self] in
            self?.iconNavigationAnchor = nil
            self?.iconNavigationCursor = nil
            self?.syncSelectionToModel()
        }
        collectionView.servicesURLs = { [weak self] in
            guard let self, !self.isRemote else { return [] }
            return self.selectedItems.map(\.url)
        }
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        collectionView.menu = menu

        iconScroll.documentView = collectionView
        iconScroll.hasVerticalScroller = true
        iconScroll.autohidesScrollers = true
        iconScroll.drawsBackground = true
        iconScroll.backgroundColor = .textBackgroundColor
    }

    func updateIconLayout() {
        (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize = IconGridMetrics.cellSize(forIcon: Settings.iconSize)
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    /// Icon size from the menu: the pictures change, the layout follows.
    func setIconSize(_ size: CGFloat) {
        Settings.iconSize = size
        updateIconLayout()
        reloadGrid()
    }

    /// Finder-like arrow navigation for the icon view:
    /// - When nothing is selected, Right/Down selects the first item and Left/Up selects the last item.
    /// - When an item is selected, Left/Right step sequentially across items (even in 1-item folders without
    ///   getting stuck on stale NSCollectionView focus), and Up/Down move to the closest item in the row above/below.
    func handleIconArrowKey(_ keyCode: UInt16, extendSelection: Bool) -> Bool {
        guard !rows.isEmpty else { return true }
        let selected = selectedRowIndexes
        let target: Int
        if selected.isEmpty {
            target = (keyCode == 124 || keyCode == 125) ? 0 : (rows.count - 1)
            iconNavigationAnchor = target
            selectRows([target])
            scrollRowToVisible(target)
            return true
        }
        let anchor = iconNavigationAnchor.flatMap { selected.contains($0) ? $0 : nil } ?? selected.first!
        let cursor = iconNavigationCursor.flatMap { selected.contains($0) ? $0 : nil }
            ?? ((keyCode == 123 || keyCode == 126) ? selected.first! : selected.last!)
        switch keyCode {
        case 123: // Left
            target = max(0, cursor - 1)
        case 124: // Right
            target = min(rows.count - 1, cursor + 1)
        case 125, 126: // Down / Up
            target = verticalIconNeighbour(from: cursor, down: keyCode == 125) ?? cursor
        default:
            return false
        }
        iconNavigationCursor = target
        if extendSelection {
            iconNavigationAnchor = anchor
            let lo = min(anchor, target), hi = max(anchor, target)
            selectRows(IndexSet(integersIn: lo...hi))
        } else {
            iconNavigationAnchor = target
            selectRows([target])
        }
        scrollRowToVisible(target)
        return true
    }

    /// Finds the item directly below or above `row` in the grid (works across grouped sections too).
    private func verticalIconNeighbour(from row: Int, down: Bool) -> Int? {
        collectionView.layoutSubtreeIfNeeded()
        func frame(of r: Int) -> NSRect? {
            collectionView.collectionViewLayout?.layoutAttributesForItem(at: collectionView.indexPath(forRow: r))?.frame
        }
        guard let current = frame(of: row) else {
            return down ? min(rows.count - 1, row + 1) : max(0, row - 1)
        }
        let isFlipped = collectionView.isFlipped
        let candidates: [(index: Int, frame: NSRect)] = (0..<rows.count).compactMap { index in
            guard let f = frame(of: index) else { return nil }
            let strictlyOtherSide = isFlipped
                ? (down ? f.midY > current.midY + 4 : f.midY < current.midY - 4)
                : (down ? f.midY < current.midY - 4 : f.midY > current.midY + 4)
            return strictlyOtherSide ? (index, f) : nil
        }
        guard !candidates.isEmpty else { return nil }
        let targetRowY: CGFloat
        if isFlipped {
            targetRowY = down ? candidates.map(\.frame.midY).min()! : candidates.map(\.frame.midY).max()!
        } else {
            targetRowY = down ? candidates.map(\.frame.midY).max()! : candidates.map(\.frame.midY).min()!
        }
        let rowItems = candidates.filter { abs($0.frame.midY - targetRowY) < 6 }
        return rowItems.min { abs($0.frame.midX - current.midX) < abs($1.frame.midX - current.midX) }?.index
    }

    /// The list turned into icons or the other way round: the other view takes over the rows, the selection and the keyboard.
    func applyViewMode() {
        let selected = Set(model.selectedURLs)
        let hadKeyboard = view.window.map { window in
            [tableView, collectionView].contains { (window.firstResponder as? NSView)?.isDescendant(of: $0) == true }
        } ?? false
        tableScroll.isHidden = iconMode
        iconScroll.isHidden = !iconMode
        updateIconLayout()
        tableView.reloadData()
        reloadGrid()
        select(urls: selected)
        syncSelectionToModel()
        if hadKeyboard { view.window?.makeFirstResponder(listView) }
        if !model.viewChangedByNavigation { flash(iconMode ? tr("Icons") : tr("List")) }
    }

    // MARK: Menu entries

    /// "View": icons or list, the size of the icons, and the sort order (a list has it in its header).
    func addViewMenu(to menu: NSMenu, make: (String, @escaping () -> Void) -> NSMenuItem) {
        let view = NSMenu(title: tr("View"))
        view.autoenablesItems = false
        let icons = make(tr("as Icons")) { [weak self] in self?.model.setShowAsIcons(true) }
        icons.state = iconMode ? .on : .off
        let list = make(tr("as List")) { [weak self] in self?.model.setShowAsIcons(false) }
        list.state = iconMode ? .off : .on
        view.addItem(icons)
        view.addItem(list)
        func attach(_ sub: NSMenu) {
            let parent = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            view.addItem(parent)
        }
        if iconMode {
            let sizes = NSMenu(title: tr("Icon Size"))
            sizes.autoenablesItems = false
            for size in IconGridMetrics.sizes {
                let item = make("\(Int(size)) pt") { [weak self] in self?.setIconSize(size) }
                item.state = Settings.iconSize == size ? .on : .off
                sizes.addItem(item)
            }
            attach(sizes)
        }
        let sort = NSMenu(title: tr("Sort By"))
        sort.autoenablesItems = false
        for key in [ListerModel.SortKey.name, .size, .date, .created, .kind, .ext] {
            let column = ListerColumn(rawValue: key.rawValue)
            let item = make(column?.title ?? key.rawValue) { [weak self] in
                guard let self else { return }
                self.model.setSort(key, ascending: self.model.ascending)
            }
            item.state = model.sortKey == key ? .on : .off
            sort.addItem(item)
        }
        sort.addItem(.separator())
        let up = make(tr("Ascending")) { [weak self] in self.map { $0.model.setSort($0.model.sortKey, ascending: true) } }
        up.state = model.ascending ? .on : .off
        let down = make(tr("Descending")) { [weak self] in self.map { $0.model.setSort($0.model.sortKey, ascending: false) } }
        down.state = model.ascending ? .off : .on
        sort.addItem(up)
        sort.addItem(down)
        attach(sort)
        if model.canGroup {
            let group = NSMenu(title: tr("Group By"))
            group.autoenablesItems = false
            for key in GroupKey.allCases {
                let item = make(key.title) { [weak self] in self?.model.setGroup(key) }
                item.state = model.groupKey == key ? .on : .off
                group.addItem(item)
                if key == .none { group.addItem(.separator()) }
            }
            attach(group)
        }
        if model.hasSavedView {
            view.addItem(.separator())
            view.addItem(make(tr("Forget the View of This Folder")) { [weak self] in self?.model.forgetSavedView() })
        }
        let parent = NSMenuItem(title: view.title, action: nil, keyEquivalent: "")
        parent.submenu = view
        menu.addItem(parent)
    }
}

// MARK: - Grid data and delegate

extension ListerViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { max(groups.count, 1) }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard isGrouped else { return rows.count }
        return groups.indices.contains(section) ? groups[section].range.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconGridItem.identifier, for: indexPath)
        let row = (collectionView as? ListerCollectionView)?.row(for: indexPath) ?? indexPath.item
        if let item = item as? IconGridItem, rows.indices.contains(row) {
            item.configure(with: rows[row], iconSize: Settings.iconSize)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GroupHeaderView.identifier, for: indexPath)
        if let header = view as? GroupHeaderView, groups.indices.contains(indexPath.section) { header.show(groups[indexPath.section]) }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        iconNavigationAnchor = nil
        iconNavigationCursor = nil
        syncSelectionToModel()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        iconNavigationAnchor = nil
        iconNavigationCursor = nil
        syncSelectionToModel()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        dragWriter(forRow: self.collectionView.row(for: indexPath))
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !Self.droppedURLs(from: draggingInfo.draggingPasteboard).isEmpty, !model.isVirtual, !model.isInArchive else {
            springLoader.cancel()
            return []
        }
        let row = self.collectionView.row(for: proposedDropIndexPath.pointee as IndexPath)
        let onFolder = proposedDropOperation.pointee == .on && rows.indices.contains(row) && rows[row].isNavigable
        if onFolder {
            let folder = rows[row].url
            springLoader.hover(folder) { [weak self] in self?.model.navigate(to: folder) }
        } else {
            // anywhere else the files go into the folder shown: the end of the grid, nothing highlighted
            springLoader.cancel()
            proposedDropIndexPath.pointee = self.collectionView.indexPath(forRow: rows.count) as NSIndexPath
            proposedDropOperation.pointee = .before
        }
        return dropOperation(for: draggingInfo, row: onFolder ? row : -1, operation: onFolder ? .on : .above)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        springLoader.cancel()
        let row = self.collectionView.row(for: indexPath)
        let onFolder = dropOperation == .on && rows.indices.contains(row) && rows[row].isNavigable
        return performDrop(draggingInfo, row: onFolder ? row : -1, operation: onFolder ? .on : .above)
    }
}
