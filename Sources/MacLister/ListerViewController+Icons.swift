import AppKit

/// The icon view of a lister: the same rows as the list, as pictures with names. The list (NSTableView) and the grid
/// (NSCollectionView) are both there; model.showAsIcons says which one is shown. Everything that works on the
/// selection goes through the helpers here, so it does not matter which one it is.
extension ListerViewController {
    var iconMode: Bool { model.showAsIcons }

    /// The view that has the keyboard: the list or the grid.
    var listView: NSView { iconMode ? collectionView : tableView }

    var selectedRowIndexes: IndexSet {
        iconMode ? IndexSet(collectionView.selectionIndexPaths.map(\.item)) : tableView.selectedRowIndexes
    }

    /// Replaces the selection with these rows.
    func selectRows(_ indexes: IndexSet) {
        if iconMode {
            collectionView.selectionIndexPaths = Set(indexes.filter { rows.indices.contains($0) }.map { IndexPath(item: $0, section: 0) })
            syncSelectionToModel()
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func scrollRowToVisible(_ row: Int) {
        if iconMode {
            guard rows.indices.contains(row) else { return }
            collectionView.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .nearestVerticalEdge)
        } else {
            tableView.scrollRowToVisible(row)
        }
    }

    /// The row under the right-click that is open now, -1 for empty space.
    var clickedRowIndex: Int { iconMode ? collectionView.clickedItem : tableView.clickedRow }

    /// Where a row is, in window coordinates; nil when it is scrolled out of view.
    func rowRectInWindow(_ row: Int) -> NSRect? {
        if iconMode {
            guard rows.indices.contains(row), let item = collectionView.item(at: IndexPath(item: row, section: 0)) else { return nil }
            let rect = item.view.convert(item.view.bounds, to: nil)
            return collectionView.visibleRect.intersects(item.view.frame) ? rect : nil
        }
        guard tableView.visibleRect.intersects(tableView.rect(ofRow: row)) else { return nil }
        return tableView.convert(tableView.rect(ofRow: row), to: nil)
    }

    /// The text field with the name of a row, for Rename in place.
    func nameField(ofRow row: Int) -> NSTextField? {
        if iconMode {
            return (collectionView.item(at: IndexPath(item: row, section: 0)) as? IconGridItem)?.nameField
        }
        guard let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return nil }
        return (tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
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
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.textBackgroundColor]       // like the list: the same background in light and dark
        collectionView.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        collectionView.onDragEnd = { [weak self] in self?.springLoader.cancel() }
        collectionView.onDoubleClick = { [weak self] in self?.handleDoubleClick(row: $0) }
        collectionView.onSelectionChange = { [weak self] in self?.syncSelectionToModel() }
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
        collectionView.reloadData()
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
        collectionView.reloadData()
        select(urls: selected)
        syncSelectionToModel()
        if hadKeyboard { view.window?.makeFirstResponder(listView) }
        flash(iconMode ? tr("Icons") : tr("List"))
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
        let parent = NSMenuItem(title: view.title, action: nil, keyEquivalent: "")
        parent.submenu = view
        menu.addItem(parent)
    }
}

// MARK: - Grid data and delegate

extension ListerViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconGridItem.identifier, for: indexPath)
        if let item = item as? IconGridItem, rows.indices.contains(indexPath.item) {
            item.configure(with: rows[indexPath.item], iconSize: Settings.iconSize)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelectionToModel() }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelectionToModel() }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        dragWriter(forRow: indexPath.item)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !Self.droppedURLs(from: draggingInfo.draggingPasteboard).isEmpty, !model.isVirtual, !model.isInArchive else {
            springLoader.cancel()
            return []
        }
        let row = proposedDropIndexPath.pointee.item
        let onFolder = proposedDropOperation.pointee == .on && rows.indices.contains(row) && rows[row].isNavigable
        if onFolder {
            let folder = rows[row].url
            springLoader.hover(folder) { [weak self] in self?.model.navigate(to: folder) }
        } else {
            // anywhere else the files go into the folder shown: the end of the grid, nothing highlighted
            springLoader.cancel()
            proposedDropIndexPath.pointee = IndexPath(item: rows.count, section: 0) as NSIndexPath
            proposedDropOperation.pointee = .before
        }
        return dropOperation(for: draggingInfo, row: onFolder ? row : -1, operation: onFolder ? .on : .above)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        springLoader.cancel()
        let onFolder = dropOperation == .on && rows.indices.contains(indexPath.item) && rows[indexPath.item].isNavigable
        return performDrop(draggingInfo, row: onFolder ? indexPath.item : -1, operation: onFolder ? .on : .above)
    }
}
