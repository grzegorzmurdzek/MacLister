import AppKit
import SwiftUI
import Combine
import QuickLookUI

/// NSTableView that routes key presses (Space, Return, Backspace, ⌘↑ …) to a handler first.
final class ListerTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘-combinations normally never reach keyDown; give the handler a chance first.
        if window?.firstResponder === self, event.modifierFlags.contains(.command), keyHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Content of a lister window: path bar (SwiftUI) / file table (AppKit) / button bar (SwiftUI).
final class ListerViewController: NSViewController {
    let model: ListerModel
    let tableView = ListerTableView()
    var rows: [FileItem] = []
    private var lastURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private var layouts: [ButtonBarPosition: [NSLayoutConstraint]] = [:]
    private var currentPosition: ButtonBarPosition?
    private var didFitColumns = false
    private let columnMenu = NSMenu(title: "Columns")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Text shown in a column for an item.
    static func text(for column: ListerColumn, of item: FileItem) -> String {
        switch column {
        case .name: return item.name
        case .size: return item.size.map { sizeFormatter.string(fromByteCount: $0) } ?? "--"
        case .date: return item.modified.map(dateFormatter.string(from:)) ?? "--"
        case .created: return item.created.map(dateFormatter.string(from:)) ?? "--"
        case .kind: return item.kind ?? (item.isDirectory ? "Folder" : "--")
        case .ext: return item.isDirectory && !item.isPackage ? "" : item.url.pathExtension.lowercased()
        case .permissions: return item.permissions.map(InfoText.permissionString) ?? "--"
        case .tags: return item.tags.joined(separator: ", ")
        case .comment: return item.comment ?? ""
        }
    }

    init(model: ListerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 440))

        let pathBar = NSHostingView(rootView: PathBarView(model: model,
                                                          onToggleRole: { [weak self] in self?.toggleRole($0) },
                                                          onConnect: { [weak self] in self?.connectChoice($0) }))
        let buttonBar = NSHostingView(rootView: ButtonBarView(model: model, store: .shared) { [weak self] in
            self?.perform($0)
        })
        let statusBar = NSHostingView(rootView: StatusBarView(model: model))
        // Fixed-height bars: don't let SwiftUI's ideal size drive the window size.
        pathBar.sizingOptions = []
        buttonBar.sizingOptions = []
        statusBar.sizingOptions = []

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        configureTable()

        for v in [pathBar, scrollView, buttonBar, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            pathBar.heightAnchor.constraint(equalToConstant: 48),
            buttonBar.heightAnchor.constraint(equalToConstant: 44),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        // The vertical stacking of the bars is switchable.
        layouts = [
            .abovePath: [
                buttonBar.topAnchor.constraint(equalTo: root.topAnchor),
                pathBar.topAnchor.constraint(equalTo: buttonBar.bottomAnchor),
                scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
                scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            ],
            .belowPath: [
                pathBar.topAnchor.constraint(equalTo: root.topAnchor),
                buttonBar.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
                scrollView.topAnchor.constraint(equalTo: buttonBar.bottomAnchor),
                scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            ],
            .bottom: [
                pathBar.topAnchor.constraint(equalTo: root.topAnchor),
                scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
                buttonBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
                buttonBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            ],
        ]
        view = root
        applyButtonBarPosition()
    }

    /// Restacks the bars when the button-bar position setting changes.
    private func applyButtonBarPosition() {
        let position = Settings.buttonBarPosition
        guard position != currentPosition else { return }
        if let old = currentPosition { NSLayoutConstraint.deactivate(layouts[old] ?? []) }
        NSLayoutConstraint.activate(layouts[position] ?? [])
        currentPosition = position
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.publisher(for: .columnsChanged)
            .sink { [weak self] _ in
                self?.rebuildColumns()
                self?.model.reload()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.applyButtonBarPosition() }
            .store(in: &cancellables)
        // Combine's $items emits the *new* value before the property changes, so use the argument.
        model.$items
            .sink { [weak self] items in self?.apply(items) }
            .store(in: &cancellables)
    }

    /// Columns start with fixed widths; once the real width is known the Name column takes what is left,
    /// so the Modified column is not cut off in narrow windows.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didFitColumns, let scroll = tableView.enclosingScrollView, scroll.contentSize.width > 0,
              let name = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) else { return }
        didFitColumns = true
        let others = tableView.tableColumns.filter { $0 !== name }.map(\.width).reduce(0, +)
        let spacing = CGFloat(tableView.tableColumns.count) * tableView.intercellSpacing.width
        name.width = max(name.minWidth, scroll.contentSize.width - others - spacing)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
    }

    /// (Re)creates the table columns from the visible-columns setting.
    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for column in ColumnSettings.visible {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column.rightAligned { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: model.sortKey.rawValue, ascending: model.ascending)]
        didFitColumns = false
        if isViewLoaded { view.needsLayout = true }   // (`view` itself must not be touched inside loadView)
    }

    private func configureTable() {
        rebuildColumns()

        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .fullWidth
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        // Right-click on the header chooses the columns.
        columnMenu.delegate = self
        tableView.headerView?.menu = columnMenu

        // Drag and drop: files can be dragged out of this table and dropped onto it (or onto a folder row).
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular

        let contextMenu = NSMenu()
        contextMenu.delegate = self      // rebuilt on every right-click, see menuNeedsUpdate
        tableView.menu = contextMenu
    }

    // MARK: - Model → table

    private func apply(_ items: [FileItem]) {
        let sameFolder = lastURL == model.url
        let previouslySelected = Set(selectedItems.map(\.url))
        lastURL = model.url

        rows = items
        tableView.reloadData()

        var toSelect = IndexSet()
        if let reveal = model.revealOnLoad, let i = rows.firstIndex(where: { $0.url == reveal }) {
            toSelect.insert(i)
        } else if sameFolder {
            for (i, item) in rows.enumerated() where previouslySelected.contains(item.url) { toSelect.insert(i) }
        }
        model.revealOnLoad = nil
        tableView.selectRowIndexes(toSelect, byExtendingSelection: false)
        if let first = toSelect.first {
            tableView.scrollRowToVisible(first)
        } else if !sameFolder {
            tableView.scrollRowToVisible(0)
        }
        syncSelectionToModel()
    }

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    private func syncSelectionToModel() {
        model.selectedURLs = selectedItems.map(\.url)
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
           panel.isVisible, panel.dataSource === self {
            if isRemote { refreshRemoteQuickLook() } else { panel.reloadData() }
        }
    }

    // MARK: - Opening

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }   // header click
        open(rows[row])
    }

    private func open(_ item: FileItem) {
        if isRemote { openRemote(item); return }
        if item.isNavigable {
            model.navigate(to: item.url)
        } else if let rule = FiletypeStore.shared.rule(for: item.url), runFiletype(rule, on: item) {
            return
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func openSelection() {
        let items = selectedItems
        if items.count == 1 { open(items[0]); return }
        for item in items {
            if item.isNavigable {
                ListerManager.shared.openLister(directory: item.url, anchor: .cascade(from: view.window))
            } else {
                open(item)
            }
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        // shortcuts the user assigned (Keyboard Shortcuts…) win over everything below
        if let action = ShortcutStore.shared.action(for: event) {
            perform(ListerButton(title: action.title, symbol: nil, action: action))
            return true
        }
        // Arrow and function keys always carry .function / .numericPad; they are not real modifiers.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        let plain = mods.isEmpty
        let command = mods == .command

        // Directory Opus habit: + and - select / deselect by pattern, * inverts the selection.
        if mods.subtracting(.shift).isEmpty, let typed = event.characters {
            switch typed {
            case "+": promptPattern(select: true); return true
            case "-": promptPattern(select: false); return true
            case "*": invertSelection(); return true
            default: break
            }
        }

        switch event.keyCode {
        case 49 where plain:                      // Space → Quick Look
            toggleQuickLook()
        case 36 where plain, 76 where plain:      // Return / Enter → open
            openSelection()
        case 51 where plain:                      // Backspace → Parent
            model.goParent()
        case 126 where command:                   // ⌘↑ → Parent
            model.goParent()
        case 125 where command:                   // ⌘↓ → open selection
            openSelection()
        case 51 where command:                    // ⌘⌫ → Trash
            perform(ListerButton(title: "Delete", symbol: nil, action: .delete))
        case 37 where mods == [.command, .shift]: // ⌘⇧L → all listers to the front
            ListerManager.shared.bringAllToFront()
        case 40 where command:                    // ⌘K → connect to a server
            connectToServer()
        case 37 where command:                    // ⌘L → type a path
            model.editingPath = true
        case 34 where command:                    // ⌘I → info
            showInfo()
        case 34 where mods == [.command, .option]: // ⌥⌘I → attributes
            promptAttributes()
        case 2 where command:                     // ⌘D → duplicate the selected files
            duplicateSelection()
        case 2 where mods == [.command, .option]: // ⌥⌘D → duplicate this lister
            duplicateLister()
        case 3 where command:                     // ⌘F → filter
            promptFilter()
        case 11 where command:                    // ⌘B → bookmark this folder
            addBookmark()
        case 120 where plain:                     // F2 → rename
            if selectedItems.count == 1 { promptRename(selectedItems[0]) } else { promptBatchRename() }
        case 14 where command:                    // ⌘E → extract archives
            extractSelection()
        case 96 where plain:                      // F5 → copy to destination
            startTransfer(.copy)
        case 97 where plain:                      // F6 → move to destination
            startTransfer(.move)
        case 47 where mods == [.command, .shift]: // ⌘⇧. → hidden files
            model.toggleHidden()
        default:
            return false
        }
        return true
    }

    // MARK: - Quick Look

    func toggleQuickLook() {
        if isRemote { remoteQuickLook(); return }
        guard !selectedItems.isEmpty, let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // The window finds us through the responder chain (view → view controller → window).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Table

extension ListerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        switch column.identifier.rawValue {
        case "name":
            let cell = reusableCell("NameCell", in: tableView, make: makeNameCell)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.textField?.stringValue = item.name
            cell.textField?.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
            return cell
        default:
            guard let kind = ListerColumn(rawValue: column.identifier.rawValue) else { return nil }
            let cell = reusableCell("Cell-\(kind.rawValue)", in: tableView) {
                self.makeTextCell($0, alignment: kind.rightAligned ? .right : .left)
            }
            cell.textField?.stringValue = Self.text(for: kind, of: item)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncSelectionToModel()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
              let sortKey = ListerModel.SortKey(rawValue: key) else { return }
        model.setSort(sortKey, ascending: descriptor.ascending)
    }

    /// Lets files be dragged out of the lister (Finder, Mail, other listers…).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // files on a server cannot be dragged out yet (they would have to be downloaded first)
        rows.indices.contains(row) && !isRemote ? rows[row].url as NSURL : nil
    }

    // MARK: Drop target

    /// Dropping on a folder row targets that folder; anywhere else targets the lister's own folder.
    private func dropFolder(forRow row: Int, operation: NSTableView.DropOperation) -> URL {
        if operation == .on, rows.indices.contains(row), rows[row].isNavigable { return rows[row].url }
        return model.url
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = Self.droppedURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        let folder = dropFolder(forRow: row, operation: dropOperation)
        if folder == model.url {
            tableView.setDropRow(-1, dropOperation: .on)        // highlight the whole table
        } else {
            tableView.setDropRow(row, dropOperation: .on)       // highlight the folder row
        }
        if RemoteURL.isRemote(folder) { return Self.remoteDragOperation(for: urls, modifiers: NSEvent.modifierFlags) }
        return Self.dragOperation(for: urls, into: folder, modifiers: NSEvent.modifierFlags,
                                  sourceMask: info.draggingSourceOperationMask)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = Self.droppedURLs(from: info.draggingPasteboard)
        let folder = dropFolder(forRow: row, operation: dropOperation)
        let operation = RemoteURL.isRemote(folder)
            ? Self.remoteDragOperation(for: urls, modifiers: NSEvent.modifierFlags)
            : Self.dragOperation(for: urls, into: folder, modifiers: NSEvent.modifierFlags,
                                 sourceMask: info.draggingSourceOperationMask)
        guard !urls.isEmpty, operation != [] else { return false }
        transfer(operation == .move ? .move : .copy, items: urls, into: folder)
        return true
    }

    // Cell construction

    private func reusableCell(_ id: String, in tableView: NSTableView,
                              make: (NSUserInterfaceItemIdentifier) -> NSTableCellView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        return tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? make(identifier)
    }

    private func makeNameCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for v in [icon, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = icon
        cell.textField = text
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeTextCell(_ identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.alignment = alignment
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Quick Look data

extension ListerViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = quickLookURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 126, 123, 124:        // arrows: move the table selection while the panel is key
            tableView.keyDown(with: event)
            return true
        case 49:                        // Space closes the panel again
            panel.orderOut(nil)
            return true
        default:
            return false
        }
    }

    /// Source rect for the zoom animation.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL,
              let row = rows.firstIndex(where: { $0.url == url }),
              tableView.visibleRect.intersects(tableView.rect(ofRow: row)),
              let window = view.window else { return .zero }
        return window.convertToScreen(tableView.convert(tableView.rect(ofRow: row), to: nil))
    }
}

// MARK: - Button actions

extension ListerViewController {
    func perform(_ button: ListerButton) {
        switch button.action {
        case .newFolder:      promptNewFolder()
        case .terminalHere:   openTerminal()
        case .delete:         confirmTrash()
        case .parent:         model.goParent()
        case .back:           model.goBack()
        case .refresh:        model.reload()
        case .toggleHidden:   model.toggleHidden()
        case .open:           openSelection()
        case .newLister:      ListerManager.shared.openLister(directory: model.url, anchor: .cascade(from: view.window))
        case .revealInFinder: revealInFinder()
        case .shell:          runShell(button.command)
        case .copy:           startTransfer(.copy)
        case .move:           startTransfer(.move)
        case .setSource:      toggleRole(.source)
        case .setDestination: toggleRole(.destination)
        case .swapSourceDestination: ListerManager.shared.swapRoles()
        case .extract:        extractSelection()
        case .separator:      break
        case .batchRename:    promptBatchRename()
        case .attributes:     promptAttributes()
        case .connectToServer: connectToServer()
        case .makeAlias:      makeLinks(symbolic: false)
        case .makeSymlink:    makeLinks(symbolic: true)
        case .selectByAttributes: promptSelectByAttributes()
        case .toggleRoleLock: if let c = view.window?.windowController as? ListerWindowController { ListerManager.shared.toggleRoleLock(for: c) }
        case .bringAllToFront: ListerManager.shared.bringAllToFront()
        case .duplicateLister: duplicateLister()
        case .duplicateFile:  duplicateSelection()
        case .selectPattern:  promptPattern(select: true)
        case .deselectPattern: promptPattern(select: false)
        case .selectAll:      selectAllRows()
        case .selectNone:     selectNoRows()
        case .invertSelection: invertSelection()
        case .filter:         promptFilter()
        case .clearFilter:    model.setFilter("")
        case .calcSizes:      calculateFolderSizes()
        case .compare:        compareWithDestination()
        case .info:           showInfo()
        case .showInDestination: showInDestination()
        case .destinationHere: destinationHere()
        case .addBookmark:    addBookmark()
        }
    }

    // MARK: Source / destination

    func toggleRole(_ role: ListerRole) {
        guard let controller = view.window?.windowController as? ListerWindowController else { return }
        ListerManager.shared.toggleRole(role, for: controller)
    }

    /// Copy / Move: selection of the source lister → folder of the destination lister.
    /// The source is the lister marked SRC, or, if none is marked, the one whose button was pressed.
    func startTransfer(_ kind: TransferKind) {
        let manager = ListerManager.shared
        guard let destination = manager.destinationController else {
            model.errorMessage = "No destination lister: press DST in the lister that should receive the files"
            return
        }
        let sourceModel = manager.sourceController?.model ?? model
        let destinationModel = destination.model

        guard sourceModel !== destinationModel else {
            model.errorMessage = "Source and destination are the same lister: mark another one as DST"
            return
        }
        let items = sourceModel.selectedURLs
        guard !items.isEmpty else {
            model.errorMessage = "Nothing selected in the source lister"
            return
        }
        guard ListerModel.comparisonKey(sourceModel.url) != ListerModel.comparisonKey(destinationModel.url) else {
            model.errorMessage = "Source and destination show the same folder"
            return
        }
        model.errorMessage = nil

        if sourceModel.isRemote || destinationModel.isRemote {
            let sizes = Dictionary(sourceModel.items.compactMap { item in item.size.map { (item.url, $0) } }, uniquingKeysWith: { first, _ in first })
            beginRemoteTransfer(kind, items: items, into: destinationModel.url, showingIn: [sourceModel, destinationModel], knownSizes: sizes)
            return
        }
        beginTransfer(kind, items: items, into: destinationModel.url, showingIn: [sourceModel, destinationModel])
    }

    /// Extract: archives selected in the source lister → new sub-folders in the destination
    /// lister's folder (or beside the archives when no destination is set).
    func extractSelection() {
        if remoteUnavailable("Extract") { return }
        let manager = ListerManager.shared
        let sourceModel = manager.sourceController?.model ?? model
        let archives = sourceModel.selectedURLs.filter(ArchiveExtractor.isArchive)
        guard !archives.isEmpty else {
            model.errorMessage = sourceModel.selectedURLs.isEmpty
                ? "Nothing selected in the source lister"
                : "The selection contains no supported archive (zip, tar, tgz, 7z, rar, gz, bz2…)"
            return
        }
        extractArchives(archives, from: sourceModel)
    }

    /// Unpacks the given archives into sub-folders of the destination lister's folder, or of the
    /// folder of `sourceModel` when no destination is set.
    func extractArchives(_ archives: [URL], from sourceModel: ListerModel) {
        let manager = ListerManager.shared
        model.errorMessage = nil
        let targetModel = manager.destinationController?.model ?? sourceModel
        let target = targetModel.url
        let message = "Extracting \(archives.count) archive\(archives.count == 1 ? "" : "s")…"
        sourceModel.statusMessage = message
        targetModel.statusMessage = message

        ArchiveExtractor.extract(archives, into: target) { [weak self] result in
            sourceModel.statusMessage = nil
            targetModel.statusMessage = nil
            var selection: [ObjectIdentifier: URL] = [:]
            if let first = result.outputs.first {
                let shown = manager.destinationController ?? manager.sourceController
                if let shown { selection[ObjectIdentifier(shown)] = first }
            }
            manager.reloadListers(showing: [target, sourceModel.url], selecting: selection)
            if !result.failures.isEmpty { self?.model.errorMessage = result.failures.joined(separator: "; ") }
        }
    }

    private func openTerminal() {
        if remoteUnavailable("Terminal Here") { return }
        let configuration = NSWorkspace.OpenConfiguration()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Settings.terminalBundleID) else {
            model.errorMessage = "Terminal app not found (\(Settings.terminalBundleID)): choose another under the menu-bar icon → Terminal App"
            return
        }
        // Handing a folder to a terminal app opens a new window/tab already cd'd there.
        NSWorkspace.shared.open([model.url], withApplicationAt: app, configuration: configuration) { [weak model] _, error in
            if let error { DispatchQueue.main.async { model?.errorMessage = error.localizedDescription } }
        }
    }

    private func revealInFinder() {
        if remoteUnavailable("Reveal in Finder") { return }
        let urls = model.selectedURLs
        if urls.isEmpty {
            NSWorkspace.shared.open(model.url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func promptNewFolder() {
        guard let window = view.window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = uniqueName("untitled folder")

        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name of the new folder in “\(model.url.lastPathComponent)”:"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
                self.model.errorMessage = "Invalid folder name"
                return
            }
            if self.isRemote { self.remoteMakeDirectory(name); return }
            let target = self.model.url.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                self.model.reload(selecting: target)
            } catch {
                self.model.errorMessage = error.localizedDescription
            }
        }
        // Select the whole default name so typing replaces it.
        field.selectText(nil)
    }

    private func uniqueName(_ base: String) -> String {
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: model.url.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    private func confirmTrash() {
        if isRemote { confirmRemoteDelete(); return }
        let urls = model.selectedURLs
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Move “\(urls[0].lastPathComponent)” to the Trash?"
            : "Move \(urls.count) items to the Trash?"
        alert.informativeText = "You can restore them from the Trash."
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var failures: [String] = []
            for url in urls {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            self.model.reload()
            if !failures.isEmpty { self.model.errorMessage = failures.joined(separator: "; ") }
        }
    }

    func runShell(_ command: String?) {
        if remoteUnavailable("Shell commands") { return }
        guard let command, !command.isEmpty else {
            model.errorMessage = "Button has no \"command\""
            return
        }
        let directory = model.url
        let selection = model.selectedURLs.map(\.path).joined(separator: "\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak model] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["LISTER_DIR"] = directory.path
            environment["LISTER_SELECTION"] = selection
            process.environment = environment
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice

            var failure: String?
            do {
                try process.run()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    failure = "exit \(process.terminationStatus)" + (text.isEmpty ? "" : ": \(text)")
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                model?.reload()
                if let failure { model?.errorMessage = failure }
            }
        }
    }
}

// MARK: - Context menu (right click / ctrl-click)

/// Holds the closure of a context-menu item (NSMenuItem has no block API).
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

extension ListerViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === columnMenu { populateColumnMenu(menu); return }
        let row = tableView.clickedRow
        if rows.indices.contains(row) {
            // Like Finder: right-clicking an unselected row selects just that row.
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
            }
            populate(menu, selection: selectedItems)
        } else {
            populate(menu, selection: [])    // empty area: folder-level commands only
        }
    }

    /// Builds the menu for the given selection (internal so the self-test can inspect it).
    func populate(_ menu: NSMenu, selection items: [FileItem]) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        func add(_ title: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(contextMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run)
            menu.addItem(item)
        }

        if !items.isEmpty {
            add(items.count == 1 ? "Open" : "Open \(items.count) Items") { [weak self] in self?.openSelection() }
            add("Quick Look") { [weak self] in self?.toggleQuickLook() }
            if !isRemote, items.contains(where: { ArchiveExtractor.isArchive($0.url) }) {
                add("Extract") { [weak self] in self?.extractSelection() }
            }
            menu.addItem(.separator())

            if let destination = ListerManager.shared.destinationController, destination.model !== model {
                let name = destination.model.url.lastPathComponent
                add("Copy to “\(name)”") { [weak self] in self?.startTransfer(.copy) }
                add("Move to “\(name)”") { [weak self] in self?.startTransfer(.move) }
                menu.addItem(.separator())
            }
            if items.count == 1 {
                add("Rename…") { [weak self] in self?.promptRename(items[0]) }
            } else if !isRemote {
                add("Rename \(items.count) Items…") { [weak self] in self?.promptBatchRename() }
            }
            if !isRemote {
                add("Attributes…") { [weak self] in self?.promptAttributes() }
                addOpenWith(to: menu, items: items)
                add("Make Alias") { [weak self] in self?.makeLinks(symbolic: false) }
                add("Make Symbolic Link") { [weak self] in self?.makeLinks(symbolic: true) }
                add("Info") { [weak self] in self?.showInfo() }
                add("Duplicate") { [weak self] in self?.duplicateSelection() }
            }
            if items.count == 1, items[0].isNavigable, let dst = ListerManager.shared.destinationController, dst.model !== model {
                add("Open in Destination") { [weak self] in self?.showInDestination() }
            }
            if !isRemote { add("Reveal in Finder") { [weak self] in self?.revealInFinder() } }
            add("Copy Path") { [weak self] in self?.copyPaths(items.map(\.url)) }
            add(isRemote ? "Delete from Server…" : "Move to Trash") { [weak self] in self?.confirmTrash() }
            menu.addItem(.separator())
        }

        if items.isEmpty {
            add("Select by Pattern…") { [weak self] in self?.promptPattern(select: true) }
            add("Select by Attributes…") { [weak self] in self?.promptSelectByAttributes() }
            add("Select All") { [weak self] in self?.selectAllRows() }
            add("Invert Selection") { [weak self] in self?.invertSelection() }
            add("Filter…") { [weak self] in self?.promptFilter() }
            if !model.filter.isEmpty { add("Clear Filter (\(model.filter))") { [weak self] in self?.model.setFilter("") } }
            if !isRemote { add("Calculate Folder Sizes") { [weak self] in self?.calculateFolderSizes() } }
            if ListerManager.shared.destinationController != nil {
                add("Compare with Destination") { [weak self] in self?.compareWithDestination() }
            }
            menu.addItem(.separator())
        }
        add("Duplicate Lister") { [weak self] in self?.duplicateLister() }
        add("Add Bookmark") { [weak self] in self?.addBookmark() }
        menu.addItem(.separator())
        add("New Folder…") { [weak self] in self?.promptNewFolder() }
        if !isRemote { add("Terminal Here") { [weak self] in self?.openTerminal() } }
        if items.isEmpty {
            add("Copy Folder Path") { [weak self] in self.map { $0.copyPaths([$0.model.url]) } }
        }
        let hidden = NSMenuItem(title: "Show Hidden Files", action: #selector(contextMenuItemChosen(_:)), keyEquivalent: "")
        hidden.target = self
        hidden.state = model.showHidden ? .on : .off
        hidden.representedObject = MenuAction { [weak self] in self?.model.toggleHidden() }
        menu.addItem(hidden)
        add("Refresh") { [weak self] in self?.model.reload() }
    }

    @objc private func contextMenuItemChosen(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(ListerModel.displayPath).joined(separator: "\n"), forType: .string)
    }

    // MARK: Rename

    func promptRename(_ item: FileItem) {
        if isRemote { promptRemoteRename(item); return }
        guard let window = view.window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.name

        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if case .failure(let error) = self.rename(item, to: field.stringValue) {
                self.model.errorMessage = error.message
            }
        }
        field.selectText(nil)
    }

    struct RenameError: Error { let message: String }

    /// Renames in place and reselects the item. Internal for the self-test.
    func rename(_ item: FileItem, to newName: String) -> Result<URL, RenameError> {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            return .failure(RenameError(message: "Invalid name"))
        }
        guard name != item.name else { return .success(item.url) }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(RenameError(message: "“\(name)” already exists"))
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            var selecting: [ObjectIdentifier: URL] = [:]
            if let controller = view.window?.windowController { selecting[ObjectIdentifier(controller)] = target }
            ListerManager.shared.reloadListers(showing: [item.url.deletingLastPathComponent()], selecting: selecting)
            return .success(target)
        } catch {
            return .failure(RenameError(message: error.localizedDescription))
        }
    }
}

// MARK: - Title-bar menu (right-click on the window's title bar)

extension ListerViewController {
    /// Lister-level commands, like the lister menu of Directory Opus Magellan.
    func makeTitleBarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = ListerManager.shared
        let controller = view.window?.windowController as? ListerWindowController

        /// A submenu whose items run closures; `build` receives the submenu and an item adder.
        func addSubmenu(_ title: String, to parent: NSMenu, _ build: (NSMenu, (String, Bool, @escaping () -> Void) -> Void) -> Void) {
            let sub = NSMenu(title: title)
            sub.autoenablesItems = false
            build(sub) { itemTitle, enabled, run in
                let item = NSMenuItem(title: itemTitle, action: #selector(self.contextMenuItemChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MenuAction(run)
                item.isEnabled = enabled
                sub.addItem(item)
            }
            let parentItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parentItem.submenu = sub
            parent.addItem(parentItem)
        }

        @discardableResult
        func add(_ title: String, key: String = "", mask: NSEvent.ModifierFlags = [.command],
                 checked: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(contextMenuItemChosen(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            item.representedObject = MenuAction(run)
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }

        add("Duplicate Lister", key: "d", mask: [.command, .option]) { [weak self] in self?.duplicateLister() }
        add("New Lister") {
            manager.openLister(directory: Settings.startDirectory, anchor: .cascade(from: controller?.window))
        }
        add("Connect to Server…", key: "k") { [weak self] in self?.connectToServer() }
        add("Keyboard Shortcuts…") { ShortcutsWindowController.shared.show() }
        if isRemote { add("Disconnect from \(RemoteURL.serverLabel(of: model.url))") { [weak self] in self?.disconnectCurrent() } }
        menu.addItem(.separator())

        add("Set as Source", checked: model.role == .source) { [weak self] in self?.toggleRole(.source) }
        add("Set as Destination", checked: model.role == .destination) { [weak self] in self?.toggleRole(.destination) }
        add(model.roleLocked ? "Unlock Role" : "Lock Role", enabled: model.role != .none) {
            if let controller { manager.toggleRoleLock(for: controller) }
        }
        add("Swap Source and Destination", enabled: manager.sourceController != nil || manager.destinationController != nil) {
            manager.swapRoles()
        }
        menu.addItem(.separator())

        add("Parent", enabled: model.canGoParent) { [weak self] in self?.model.goParent() }
        add("Back", enabled: model.canGoBack) { [weak self] in self?.model.goBack() }
        add("Refresh") { [weak self] in self?.model.reload() }
        add("Show Hidden Files", checked: model.showHidden) { [weak self] in self?.model.toggleHidden() }
        add(model.filter.isEmpty ? "Filter…" : "Filter… (\(model.filter))", key: "f") { [weak self] in self?.promptFilter() }
        addSubmenu("Bookmarks", to: menu) { sub, addItem in
            let bookmarks = BookmarkStore.shared.paths
            if bookmarks.isEmpty { addItem("No bookmarks", false) { } }
            for path in bookmarks {
                addItem(PathText.short(path), true) { [weak self] in self?.model.navigate(to: URL(fileURLWithPath: path)) }
            }
            sub.addItem(.separator())
            addItem("Add This Folder", !BookmarkStore.shared.contains(model.url)) { [weak self] in self?.addBookmark() }
            addItem("Remove This Folder", BookmarkStore.shared.contains(model.url)) { [weak self] in
                guard let self else { return }
                BookmarkStore.shared.remove(self.model.url.standardizedFileURL.path)
            }
        }
        addSubmenu("Recent Folders", to: menu) { _, addItem in
            let recent = PathHistory.shared.recent
            if recent.isEmpty { addItem("No recent folders", false) { } }
            for path in recent {
                addItem(PathText.short(path), true) { [weak self] in self?.model.navigate(to: URL(fileURLWithPath: path)) }
            }
        }
        add("Terminal Here", enabled: !isRemote) { [weak self] in self?.openTerminal() }
        menu.addItem(.separator())

        add("Bring All Listers to Front", enabled: manager.openCount > 1) { manager.bringAllToFront() }
        add("Close Lister", key: "w") { [weak self] in self?.view.window?.performClose(nil) }
        add("Close All Listers", enabled: manager.openCount > 1) { manager.closeAll() }
        menu.addItem(.separator())

        add("Save Layout") { LayoutStore.save(from: manager) }
        add("Restore Layout") { LayoutStore.restore(into: manager) }
        return menu
    }
}

// MARK: - Open With

extension ListerViewController {
    /// "Open With" submenu: the applications that can open the first selected file, default first.
    fileprivate func addOpenWith(to menu: NSMenu, items: [FileItem]) {
        guard let first = items.first, !first.isNavigable else { return }
        let urls = items.filter { !$0.isNavigable }.map(\.url)
        let sub = NSMenu(title: "Open With")
        sub.autoenablesItems = false

        func appItem(_ title: String, _ appURL: URL?, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(contextMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run)
            if let appURL, let icon = NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            sub.addItem(item)
        }

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first.url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
        if let defaultApp { apps.removeAll { $0 == defaultApp }; apps.insert(defaultApp, at: 0) }
        for app in apps.prefix(15) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            appItem(app == defaultApp ? "\(name) (default)" : name, app) { [weak self] in self?.open(urls, with: app) }
        }
        if !apps.isEmpty { sub.addItem(.separator()) }
        appItem("Other…", nil) { [weak self] in self?.chooseApplication(for: urls) }

        let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func chooseApplication(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let app = panel.url { self?.open(urls, with: app) }
        }
    }
}

// MARK: - Column chooser (header menu)

extension ListerViewController {
    fileprivate func populateColumnMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = ColumnSettings.visible
        for column in ListerColumn.allCases where column != .name {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = visible.contains(column) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Columns", action: #selector(resetColumns), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc fileprivate func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = ListerColumn(rawValue: raw) else { return }
        ColumnSettings.set(column, visible: sender.state != .on)
    }

    @objc fileprivate func resetColumns() { ColumnSettings.reset() }
}
