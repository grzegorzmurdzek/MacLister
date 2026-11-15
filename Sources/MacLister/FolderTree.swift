import AppKit

/// One row of the tree pane: a folder of the tree (its sub-folders are read the first time it is opened), or one of the
/// rows Finder's sidebar has around the tree: Recents, Shared, the Favorites, AirDrop, Trash and the Tags, under headers.
final class TreeNode: NSObject {
    enum Kind: Equatable {
        case folder                 // a folder of the tree: it opens and shows its sub-folders
        case shortcut               // a folder that does not open: a favourite, the Trash, the list of volumes
        case place(VirtualPlace)    // Recents, Shared
        case tag(String)            // the files that carry a Finder tag
        case allTags                // "All Tags…": a menu of every tag
        case airDrop
        case header                 // Favorites, Locations, Tags
    }

    let url: URL
    let name: String
    let kind: Kind
    /// An SF Symbol to show instead of the folder's own icon.
    var symbol: String?
    /// Files may be dropped on this shortcut (a favourite; not the Trash or the list of volumes).
    var acceptsDrops = false
    /// The header this row sits under.
    weak var section: TreeNode?
    private(set) var children: [TreeNode] = []
    private(set) var isLoaded = false

    init(url: URL, name: String? = nil, kind: Kind = .folder) {
        self.url = url
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
        self.kind = kind
        isLoaded = kind != .folder
    }

    /// What identifies a header whatever the language (the English title), for remembering that it is closed.
    private(set) var key = ""

    init(header name: String, key: String, children: [TreeNode]) {
        url = URL(string: "\(VirtualPlace.scheme)://section")!
        self.name = name
        self.key = key
        kind = .header
        self.children = children
        isLoaded = true
        super.init()
        children.forEach { $0.section = self }
    }

    /// Can files be dropped on this row?
    var isDropTarget: Bool { kind == .folder || (kind == .shortcut && acceptsDrops) }

    /// Reads the sub-folders again (folders only, no bundles; hidden ones when asked for, and the one that leads
    /// to `ensuring` even if it is hidden: the lister may be in /private/var).
    func load(showHidden: Bool, ensuring target: URL? = nil) {
        guard kind == .folder else { return }
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

/// The outline view of the tree; tells when a drag over it ends or leaves.
final class TreeOutlineView: NSOutlineView {
    var onDragEnd: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragEnd?(); super.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragEnd?(); super.draggingEnded(sender) }
}

/// The two parts of the pane (Finder's sidebar above, the tree below): the first time it is laid out the sidebar gets
/// the height the user last dragged it to, or a share of the pane.
final class SidebarSplitView: NSSplitView {
    var onFirstLayout: (() -> Void)?
    private var placed = false

    override func layout() {
        super.layout()
        guard !placed, !isHidden, bounds.height > 200, arrangedSubviews.count == 2 else { return }
        placed = true
        onFirstLayout?()
    }
}

/// The pane beside the file list. Above it has what Finder's sidebar has (Recents, Shared, the Favorites, the
/// Locations, the Tags), read from Finder itself, so the two stay the same. Below it is the directory tree, always in
/// view: the home folder, iCloud Drive and every volume, folders only. The divider between them can be dragged.
/// Choosing a row shows it in the lister; the pane follows the lister; folders accept dropped files.
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate {
    /// The whole pane: put this beside the file list.
    let paneView = SidebarSplitView()
    private let sidebarScroll = NSScrollView()
    private let treeScroll = NSScrollView()
    private let sidebarOutline = TreeOutlineView()
    private let treeOutline = TreeOutlineView()
    /// The rows at the top of the sidebar: Recents, Shared and the headers.
    private(set) var sections: [TreeNode] = []
    /// The folders at the top of the tree (the home folder, iCloud Drive, the volumes).
    private(set) var roots: [TreeNode] = []
    /// Rows that open a folder or a list without being part of the tree: favourites, Trash, the list of volumes.
    private var shortcuts: [TreeNode] = []
    private var tagRows: [TreeNode] = []
    private var placeRows: [TreeNode] = []
    private var sidebarTags: [String] = []
    var showHidden = false
    /// The user chose a folder, a list or a tag search.
    var onSelect: ((URL) -> Void)?
    /// Files were dropped on a folder: urls, folder, the operation Finder rules chose.
    var onDrop: (([URL], URL, NSDragOperation) -> Void)?
    private var suppressSelection = false
    let springLoader = SpringLoader()
    private var lastRevealed: URL?
    private var volumeObservers: [NSObjectProtocol] = []
    private var sidebarObserver: NSObjectProtocol?

    /// The name of this Mac. Asked once: the system can be slow to answer, and buildRoots runs on every change.
    private static let computerName = Host.current().localizedName ?? tr("Computer")

    static let airDropApp = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
    private static let collapsedKey = "collapsedSidebarSections"

    deinit {
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let sidebarObserver { NotificationCenter.default.removeObserver(sidebarObserver) }
    }

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
        // something changed in Finder's sidebar: a favourite added, a tag renamed …
        sidebarObserver = NotificationCenter.default.addObserver(forName: .finderSidebarChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.buildRoots()
            if let url = self.lastRevealed { self.reveal(url) }
        }
        for (outline, scroll) in [(sidebarOutline, sidebarScroll), (treeOutline, treeScroll)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
            column.resizingMask = .autoresizingMask
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.headerView = nil
            outline.rowSizeStyle = .small
            outline.style = .sourceList
            outline.floatsGroupRows = false
            outline.indentationPerLevel = 12
            outline.dataSource = self
            outline.delegate = self
            outline.onDragEnd = { [weak self] in self?.springLoader.cancel() }
            outline.registerForDraggedTypes([.fileURL])
            outline.draggingDestinationFeedbackStyle = .regular
            scroll.documentView = outline
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
        }
        paneView.isVertical = false
        paneView.dividerStyle = .thin
        paneView.delegate = self
        paneView.addArrangedSubview(sidebarScroll)
        paneView.addArrangedSubview(treeScroll)
        paneView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)     // the tree takes the changes of height
        paneView.onFirstLayout = { [weak self] in self?.placeDivider() }
        buildRoots()
    }

    // MARK: The two parts

    /// The sidebar keeps the height the user gave it; before that it takes 45 % of the pane.
    private func placeDivider() {
        guard !sidebarScroll.isHidden else { return }
        let saved = Settings.sidebarHeight
        let height = saved > 0 ? saved : paneView.bounds.height * 0.45
        paneView.setPosition(min(max(height, 100), paneView.bounds.height - 120), ofDividerAt: 0)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !sidebarScroll.isHidden, paneView.bounds.height > 200, sidebarScroll.frame.height >= 80,
              NSApp.currentEvent?.type == .leftMouseDragged else { return }       // the user dragging the divider
        Settings.sidebarHeight = sidebarScroll.frame.height
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 80)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 100)
    }

    // MARK: Roots

    /// Shows only these folders as the top of the tree (the screenshots use it, so they show no real folders).
    func setRoots(_ urls: [URL]) {
        roots = urls.map { TreeNode(url: $0) }
        sections = []
        shortcuts = []
        tagRows = []
        placeRows = []
        sidebarScroll.isHidden = true           // only the tree
        sidebarOutline.reloadData()
        treeOutline.reloadData()
    }

    /// Recents and Shared, then the Favorites, the Locations and the Tags of Finder's sidebar, and the folder tree below.
    func buildRoots() {
        let sidebar = FinderSidebarMonitor.shared.current
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var treeRoots: [TreeNode] = []         // the tree: a folder that opens
        var locations: [TreeNode] = []         // Finder's Locations: the same places, as rows that only open them
        var shortcutRows: [TreeNode] = []
        func addPlace(url: URL, name: String, symbol: String? = nil, inTree: Bool) {
            if inTree { treeRoots.append(TreeNode(url: url, name: name)) }
            let node = TreeNode(url: url, name: name, kind: .shortcut)
            node.symbol = symbol
            node.acceptsDrops = true
            locations.append(node)
            shortcutRows.append(node)
        }
        func addShortcut(url: URL, name: String, symbol: String) {
            let node = TreeNode(url: url, name: name, kind: .shortcut)
            node.symbol = symbol
            locations.append(node)
            shortcutRows.append(node)
        }

        // Finder's order: iCloud Drive, the home folder, this computer, the disks, AirDrop, the Trash
        // (iCloud Drive is a row only: it is inside the home folder, so the tree reaches it there)
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if sidebar.showsICloudDrive { addPlace(url: cloud, name: tr("iCloud Drive"), symbol: "icloud", inTree: false) }
        addPlace(url: home, name: NSUserName(), symbol: "house", inTree: true)
        if sidebar.showsComputer {
            addShortcut(url: URL(fileURLWithPath: "/Volumes"), name: Self.computerName, symbol: "laptopcomputer")
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
            // the tree always has every disk; Finder's list may leave the start-up disk out
            addPlace(url: volume, name: name, inTree: true)
            if volume.path == "/", sidebar.isKnown, !sidebar.showsStartupDisk {
                locations.removeLast()
                shortcutRows.removeLast()
            }
        }
        if sidebar.showsAirDrop, fm.fileExists(atPath: Self.airDropApp.path) {
            let node = TreeNode(url: URL(string: "\(VirtualPlace.scheme)://airdrop")!, name: "AirDrop", kind: .airDrop)
            node.symbol = "airdrop"
            locations.append(node)
        }
        if sidebar.showsTrash {
            addShortcut(url: home.appendingPathComponent(".Trash", isDirectory: true), name: tr("Trash"), symbol: "trash")
        }

        var favorites: [TreeNode] = []
        for favorite in sidebar.favorites {
            let node = TreeNode(url: favorite.url, name: favorite.name, kind: .shortcut)
            node.acceptsDrops = true
            favorites.append(node)
            shortcutRows.append(node)
        }

        var tags = sidebar.favoriteTags.map { TreeNode(url: FindQuery.tagged($0).url, name: $0, kind: .tag($0)) }
        let tagRows = tags
        if !sidebar.tags.isEmpty { tags.append(TreeNode(url: URL(string: "\(VirtualPlace.scheme)://tags")!, name: tr("All Tags…"), kind: .allTags)) }

        func place(_ place: VirtualPlace, symbol: String) -> TreeNode {
            let node = TreeNode(url: place.url, name: place.title, kind: .place(place))
            node.symbol = symbol
            return node
        }
        let recents = place(.recents, symbol: "clock"), shared = place(.shared, symbol: "person.2")
        var top = [recents, shared]
        if !favorites.isEmpty { top.append(TreeNode(header: tr("Favorites"), key: "Favorites", children: favorites)) }
        top.append(TreeNode(header: tr("Locations"), key: "Locations", children: locations))
        if !tags.isEmpty { top.append(TreeNode(header: tr("Tags"), key: "Tags", children: tags)) }

        sections = top
        roots = treeRoots
        shortcuts = shortcutRows
        self.tagRows = tagRows
        placeRows = [recents, shared]
        sidebarTags = sidebar.tags
        sidebarScroll.isHidden = false
        sidebarOutline.reloadData()
        treeOutline.reloadData()
        expandSections()
    }

    // MARK: Sections (the headers)

    private var collapsedSections: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.collapsedKey) }
    }

    /// Opens the headers the user has not closed.
    private func expandSections() {
        let closed = collapsedSections
        for section in sections where section.kind == .header && !closed.contains(section.key) { sidebarOutline.expandItem(section) }
    }

    private func noteSection(_ notification: Notification, collapsed: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode, node.kind == .header else { return }
        var closed = collapsedSections
        if collapsed { closed.insert(node.key) } else { closed.remove(node.key) }
        collapsedSections = closed
    }

    func outlineViewItemDidExpand(_ notification: Notification) { noteSection(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { noteSection(notification, collapsed: true) }

    // MARK: Following the lister

    /// The deepest root that contains `url`.
    private func root(containing url: URL) -> TreeNode? {
        let path = url.standardizedFileURL.path
        return roots.filter { path == $0.url.path || path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// The row of the sidebar that stands for a list the lister shows (Recents, Shared, a tag).
    private func sidebarRow(for url: URL) -> TreeNode? {
        guard let place = VirtualPlace.place(for: url) else { return nil }
        if place == .find {
            guard let query = FindQuery(url: url), !query.tag.isEmpty, query.name.isEmpty, query.content.isEmpty else { return nil }
            return tagRows.first { $0.kind == .tag(query.tag) }
        }
        return placeRows.first { $0.kind == .place(place) }
    }

    /// The favourite (or the Trash …) that is exactly this folder.
    private func shortcut(at path: String) -> TreeNode? {
        shortcuts.first { $0.url.standardizedFileURL.path == path }
    }

    /// Opens the branches down to `url` and selects it.
    func reveal(_ url: URL) {
        lastRevealed = url
        // Opening branches and reloading rows moves the selection around: none of that is the user choosing a folder.
        let wasSuppressing = suppressSelection
        suppressSelection = true
        defer { suppressSelection = wasSuppressing }
        guard url.isFileURL else { select(sidebarRow(for: url)); return }
        let target = url.standardizedFileURL.path
        guard var node = root(containing: url) else { select(shortcut(at: target)); return }
        treeOutline.expandItem(node)
        if !node.isLoaded { node.load(showHidden: showHidden, ensuring: url); treeOutline.reloadItem(node, reloadChildren: true); treeOutline.expandItem(node) }
        while node.url.path != target {
            if !node.isLoaded { node.load(showHidden: showHidden, ensuring: url); treeOutline.reloadItem(node, reloadChildren: true) }
            func child() -> TreeNode? { node.children.first(where: { target == $0.url.path || target.hasPrefix($0.url.path + "/") }) }
            if child() == nil {                     // a hidden folder on the way (or one that was just made)
                node.load(showHidden: showHidden, ensuring: url)
                treeOutline.reloadItem(node, reloadChildren: true)
            }
            guard let next = child() else { break }
            treeOutline.expandItem(node)
            node = next
        }
        let found = node.url.path == target
        if found { treeOutline.expandItem(node) }       // its sub-folders are what you will want next
        // In a favourite's own folder Finder highlights the favourite; the tree below it stays open all the same.
        select(shortcut(at: target) ?? (found ? node : nil))
    }

    /// The outline a row belongs to: folders are in the tree, everything else in the sidebar.
    private func outline(for node: TreeNode) -> TreeOutlineView { node.kind == .folder ? treeOutline : sidebarOutline }

    private func select(_ node: TreeNode?) {
        suppressSelection = true
        defer { suppressSelection = false }
        sidebarOutline.deselectAll(nil)
        treeOutline.deselectAll(nil)
        guard let node else { return }
        let outline = outline(for: node)
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            scrollToShow(node)
        }
    }

    /// Brings the row into view once the pane has its size (a lister that has just opened is laid out a moment later).
    /// A row near the top leaves its part of the pane at the top, so Recents and the Favorites stay in sight.
    private func scrollToShow(_ node: TreeNode) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let outline = self.outline(for: node)
            let row = outline.row(forItem: node)
            guard row >= 0, let scroll = outline.enclosingScrollView else { return }
            outline.window?.layoutIfNeeded()
            if outline.rect(ofRow: row).maxY <= scroll.contentView.bounds.height {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                outline.scrollRowToVisible(row)
            }
        }
    }

    /// The folder was read again by the lister: show new or removed sub-folders.
    func refresh(_ url: URL) {
        guard url.isFileURL, let node = find(url), node.isLoaded else { return }
        let before = node.children.map(\.url.path)
        node.load(showHidden: showHidden)
        guard node.children.map(\.url.path) != before else { return }
        treeOutline.reloadItem(node, reloadChildren: true)
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
        treeOutline.reloadData()
        reveal(url)
    }

    /// The folder selected in the tree (the self-test reads it).
    var selectedURL: URL? { selectedNode?.url }

    /// The row selected in the pane, whatever kind it is (the self-test reads it).
    var selectedNode: TreeNode? {
        for outline in [sidebarOutline, treeOutline] where outline.selectedRow >= 0 {
            return outline.item(atRow: outline.selectedRow) as? TreeNode
        }
        return nil
    }

    /// Names of the sub-folders the tree knows below `url` (the self-test reads them).
    func knownChildren(of url: URL) -> [String] { find(url)?.children.map(\.name) ?? [] }

    /// Names of the rows under each header and of the rows above them (the self-test reads them).
    func sidebarRows() -> [(header: String?, names: [String])] {
        var list: [(header: String?, names: [String])] = [(nil, sections.filter { $0.kind != .header }.map(\.name))]
        for section in sections where section.kind == .header { list.append((section.name, section.children.map(\.name))) }
        return list
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return outlineView === treeOutline ? roots.count : sections.count }
        if node.kind == .folder, !node.isLoaded { node.load(showHidden: showHidden) }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return outlineView === treeOutline ? roots[index] : sections[index] }
        if node.kind == .folder, !node.isLoaded { node.load(showHidden: showHidden) }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        switch node.kind {
        case .header: return true
        case .folder: return !node.isLoaded || !node.children.isEmpty
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? TreeNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? TreeNode)?.kind != .header
    }

    /// The dot of a tag: filled with its colour, an empty ring for a tag that has none.
    static func tagImage(for tag: String) -> NSImage {
        let label = FinderTags.label(of: FinderTags.Entry(name: tag, label: 0))
        let color: NSColor? = label > 0 ? FinderTags.color(for: label) : nil
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                dot.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            return true
        }
    }

    private func icon(for node: TreeNode) -> NSImage? {
        switch node.kind {
        case .tag(let tag): return Self.tagImage(for: tag)
        case .allTags: return NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        case .airDrop:
            return NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
        default:
            if let symbol = node.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { return image }
            return NSWorkspace.shared.icon(forFile: node.url.path)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.kind == .header ? "TreeHeader" : "TreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if node.kind == .header {
                text.font = .systemFont(ofSize: 11, weight: .semibold)
                text.textColor = .secondaryLabelColor
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
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
        if node.kind != .header { cell.imageView?.image = icon(for: node) }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let outline = notification.object as? NSOutlineView, userIsChoosing(in: outline),
              let node = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
        if node.kind != .header, node.kind != .allTags, node.kind != .airDrop {      // one row is selected in the pane, not one in each part
            let other = outline === treeOutline ? sidebarOutline : treeOutline
            suppressSelection = true
            other.deselectAll(nil)
            suppressSelection = false
        }
        switch node.kind {
        case .header:
            break
        case .airDrop:
            NSWorkspace.shared.open(Self.airDropApp)    // a window of its own, as in Finder
            restoreSelection()
        case .allTags:
            showAllTags(row: outline.selectedRow)
        default:
            onSelect?(node.url)
        }
    }

    /// Puts the selection back on what the lister shows (after a row that opens something else was clicked).
    private func restoreSelection() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let url = self.lastRevealed { self.reveal(url) } else { self.select(nil) }
        }
    }

    /// "All Tags…": a menu of every tag Finder knows, the ones the sidebar does not show too.
    private func showAllTags(row: Int) {
        let menu = NSMenu()
        for tag in sidebarTags {
            let item = NSMenuItem(title: tag, action: #selector(chooseTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag
            item.image = Self.tagImage(for: tag)
            menu.addItem(item)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let rect = self.sidebarOutline.rect(ofRow: row)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 24, y: rect.maxY), in: self.sidebarOutline)
            self.restoreSelection()
        }
    }

    @objc private func chooseTag(_ item: NSMenuItem) {
        guard let tag = item.representedObject as? String else { return }
        onSelect?(FindQuery.tagged(tag).url)
    }

    /// Is the selection changing because of a click in the tree or a key typed into it? A button elsewhere in the window
    /// (Back, Up) or a change of folder also moves the selection, and must never be taken for a choice.
    private func userIsChoosing(in outline: NSOutlineView) -> Bool {
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
        guard let node = item as? TreeNode, node.isDropTarget, ArchiveBrowser.shared.location(of: node.url) == nil else { springLoader.cancel(); return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        // hold the files over a closed folder and it opens
        if node.kind == .folder, !outlineView.isItemExpanded(node) {
            springLoader.hover(node.url) { [weak self, weak node] in if let node { self?.treeOutline.expandItem(node) } }
        } else {
            springLoader.cancel()
        }
        let urls = ListerViewController.droppedURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        return ListerViewController.dragOperation(for: urls, into: node.url, modifiers: NSEvent.modifierFlags, sourceMask: info.draggingSourceOperationMask)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        guard let node = item as? TreeNode, node.isDropTarget else { return false }
        let urls = ListerViewController.droppedURLs(from: info.draggingPasteboard)
        let operation = ListerViewController.dragOperation(for: urls, into: node.url, modifiers: NSEvent.modifierFlags, sourceMask: info.draggingSourceOperationMask)
        guard !urls.isEmpty, operation != [] else { return false }
        onDrop?(urls, node.url, operation)
        return true
    }
}
