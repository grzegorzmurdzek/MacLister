import AppKit

/// One folder in the tree; its sub-folders are read the first time it is opened.
final class TreeNode: NSObject {
    let url: URL
    let name: String
    private(set) var children: [TreeNode] = []
    private(set) var isLoaded = false

    init(url: URL, name: String? = nil) {
        self.url = url
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
    }

    /// Reads the sub-folders again (folders only, no bundles; hidden ones when asked for, and the one that leads
    /// to `ensuring` even if it is hidden: the lister may be in /private/var).
    func load(showHidden: Bool, ensuring target: URL? = nil) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        let targetPath = target?.standardizedFileURL.path
        let folders = entries.filter { entry in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            var isFolder = values?.isDirectory == true
            if !isFolder, values?.isSymbolicLink == true {         // a link to a folder (/var, /tmp …) is a folder here
                var isDirectory: ObjCBool = false      // fileExists follows the link
                isFolder = FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard isFolder, values?.isPackage != true else { return false }
            if showHidden { return true }
            if values?.isHidden != true && !entry.lastPathComponent.hasPrefix(".") { return true }
            let path = url.appendingPathComponent(entry.lastPathComponent).path
            return targetPath.map { $0 == path || $0.hasPrefix(path + "/") } ?? false
        }
        // below a link such as /var the system hands back /private/var/…: build the paths from this folder's own
        let sorted = folders.map { url.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // keep the nodes that already exist, so open branches stay open
        var existing: [String: TreeNode] = [:]
        for child in children { existing[child.url.path] = child }
        children = sorted.map { existing[$0.path] ?? TreeNode(url: $0) }
        isLoaded = true
    }
}

/// The directory tree beside the file list: the home folder and every volume, folders only.
/// Choosing a folder shows it in the lister; the tree follows the lister; folders accept dropped files.
/// The outline view of the tree; tells when a drag over it ends or leaves.
final class TreeOutlineView: NSOutlineView {
    var onDragEnd: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragEnd?(); super.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragEnd?(); super.draggingEnded(sender) }
}

final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    private let outline = TreeOutlineView()
    private(set) var roots: [TreeNode] = []
    var showHidden = false
    /// The user chose a folder.
    var onSelect: ((URL) -> Void)?
    /// Files were dropped on a folder: urls, folder, the operation Finder rules chose.
    var onDrop: (([URL], URL, NSDragOperation) -> Void)?
    private var suppressSelection = false
    let springLoader = SpringLoader()
    private var lastRevealed: URL?
    private var volumeObservers: [NSObjectProtocol] = []

    deinit { volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    override init() {
        super.init()
        // a disk plugged in or ejected while the lister is open
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.buildRoots()
                if let url = self.lastRevealed { self.reveal(url) }
            })
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.style = .sourceList
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.onDragEnd = { [weak self] in self?.springLoader.cancel() }
        outline.registerForDraggedTypes([.fileURL])
        outline.draggingDestinationFeedbackStyle = .regular
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        buildRoots()
    }

    // MARK: Roots

    /// Shows only these folders as the top of the tree (the screenshots use it, so they show no real folders).
    func setRoots(_ urls: [URL]) {
        roots = urls.map { TreeNode(url: $0) }
        outline.reloadData()
    }

    /// Home first, then every mounted volume.
    func buildRoots() {
        var list: [TreeNode] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(TreeNode(url: home, name: NSUserName()))
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
            list.append(TreeNode(url: volume, name: name))
        }
        roots = list
        outline.reloadData()
    }

    // MARK: Following the lister

    /// The deepest root that contains `url`.
    private func root(containing url: URL) -> TreeNode? {
        let path = url.standardizedFileURL.path
        return roots.filter { path == $0.url.path || path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// Opens the branches down to `url` and selects it.
    func reveal(_ url: URL) {
        lastRevealed = url
        // Opening branches and reloading rows moves the selection around: none of that is the user choosing a folder.
        let wasSuppressing = suppressSelection
        suppressSelection = true
        defer { suppressSelection = wasSuppressing }
        guard url.isFileURL, var node = root(containing: url) else { select(nil); return }
        let target = url.standardizedFileURL.path
        outline.expandItem(node)
        if !node.isLoaded { node.load(showHidden: showHidden, ensuring: url); outline.reloadItem(node, reloadChildren: true); outline.expandItem(node) }
        while node.url.path != target {
            if !node.isLoaded { node.load(showHidden: showHidden, ensuring: url); outline.reloadItem(node, reloadChildren: true) }
            func child() -> TreeNode? { node.children.first(where: { target == $0.url.path || target.hasPrefix($0.url.path + "/") }) }
            if child() == nil {                     // a hidden folder on the way (or one that was just made)
                node.load(showHidden: showHidden, ensuring: url)
                outline.reloadItem(node, reloadChildren: true)
            }
            guard let next = child() else { break }
            outline.expandItem(node)
            node = next
        }
        if node.url.path == target {
            outline.expandItem(node)                 // its sub-folders are what you will want next
            select(node)
        } else {
            select(nil)
        }
    }

    private func select(_ node: TreeNode?) {
        suppressSelection = true
        defer { suppressSelection = false }
        if let node {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        } else {
            outline.deselectAll(nil)
        }
    }

    /// The folder was read again by the lister: show new or removed sub-folders.
    func refresh(_ url: URL) {
        guard url.isFileURL, let node = find(url), node.isLoaded else { return }
        let before = node.children.map(\.url.path)
        node.load(showHidden: showHidden)
        guard node.children.map(\.url.path) != before else { return }
        outline.reloadItem(node, reloadChildren: true)
        reveal(url)
    }

    private func find(_ url: URL) -> TreeNode? {
        guard var node = root(containing: url) else { return nil }
        let target = url.standardizedFileURL.path
        while node.url.path != target {
            guard node.isLoaded, let next = node.children.first(where: { target == $0.url.path || target.hasPrefix($0.url.path + "/") }) else { return nil }
            node = next
        }
        return node
    }

    /// Hidden folders were switched on or off: read everything again.
    func hiddenChanged(showing url: URL) {
        func reload(_ node: TreeNode) {
            guard node.isLoaded else { return }
            node.load(showHidden: showHidden)
            node.children.forEach(reload)
        }
        roots.forEach(reload)
        outline.reloadData()
        reveal(url)
    }

    /// The folder selected in the tree (the self-test reads it).
    var selectedURL: URL? { (outline.item(atRow: outline.selectedRow) as? TreeNode)?.url }

    /// Names of the sub-folders the tree knows below `url` (the self-test reads them).
    func knownChildren(of url: URL) -> [String] { find(url)?.children.map(\.name) ?? [] }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return roots.count }
        if !node.isLoaded { node.load(showHidden: showHidden) }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return roots[index] }
        if !node.isLoaded { node.load(showHidden: showHidden) }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        return !node.isLoaded || !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            for v in [image, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, userIsChoosing, let node = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
        onSelect?(node.url)
    }

    /// Is the selection changing because of a click in the tree or a key typed into it? A button elsewhere in the window
    /// (Back, Up) or a change of folder also moves the selection, and must never be taken for a choice.
    private var userIsChoosing: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown:
            guard event.window === outline.window else { return false }
            return outline.bounds.contains(outline.convert(event.locationInWindow, from: nil))
        case .keyDown, .keyUp:
            return outline.window?.firstResponder === outline
        default:
            return false
        }
    }

    // MARK: Dropping files on a folder

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? TreeNode, ArchiveBrowser.shared.location(of: node.url) == nil else { springLoader.cancel(); return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        // hold the files over a closed folder and it opens
        if !outlineView.isItemExpanded(node) {
            springLoader.hover(node.url) { [weak self, weak node] in if let node { self?.outline.expandItem(node) } }
        } else {
            springLoader.cancel()
        }
        let urls = ListerViewController.droppedURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        return ListerViewController.dragOperation(for: urls, into: node.url, modifiers: NSEvent.modifierFlags, sourceMask: info.draggingSourceOperationMask)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        guard let node = item as? TreeNode else { return false }
        let urls = ListerViewController.droppedURLs(from: info.draggingPasteboard)
        let operation = ListerViewController.dragOperation(for: urls, into: node.url, modifiers: NSEvent.modifierFlags, sourceMask: info.draggingSourceOperationMask)
        guard !urls.isEmpty, operation != [] else { return false }
        onDrop?(urls, node.url, operation)
        return true
    }
}
