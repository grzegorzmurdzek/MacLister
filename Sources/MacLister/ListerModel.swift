import Foundation
import Combine

struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    var size: Int64?
    var modified: Date?
    // Loaded only while the matching column is visible:
    var created: Date? = nil
    var kind: String? = nil
    var permissions: Int? = nil
    var tags: [String] = []
    var comment: String? = nil
    var isSymlink = false          // servers only: shown as a file, but may point to a folder

    /// Folders we can descend into (bundles such as .app are opened, not entered).
    var isNavigable: Bool { isDirectory && !isPackage }

    func withSize(_ newSize: Int64) -> FileItem {
        var copy = self
        copy.size = newSize
        return copy
    }
}

/// What the status line shows while a copy, move or other long job runs.
struct TransferStatus {
    var text: String
    var fraction: Double?          // nil: indeterminate
    var cancel: () -> Void
    var details: TransferMonitor? = nil     // opened when the progress bar is clicked
}

/// Magellan-style role of a lister: Copy/Move go from the source lister to the destination lister.
enum ListerRole { case none, source, destination }

/// State of one lister: current folder, its (sorted) contents, selection, history.
final class ListerModel: ObservableObject {
    enum SortKey: String { case name, size, date, created, kind, ext, permissions, tags, comment, folder }

    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?      // transient info, e.g. "Copying 3 items…"
    @Published var progress: TransferStatus?   // running copy / move: progress bar with a Cancel button
    /// Optional name and colour the user gave this lister ("NAS", "Backup" …).
    @Published var label = ""
    @Published var labelColor: String?
    @Published var role: ListerRole = .none
    /// true: the path bar shows an editable text field instead of the clickable breadcrumb.
    @Published var editingPath = false
    /// A locked role cannot be changed, cleared or swapped away until it is unlocked.
    @Published var roleLocked = false
    @Published var selectedURLs: [URL] = []
    @Published private(set) var showHidden = false
    @Published private(set) var sortKey: SortKey = .name
    @Published private(set) var ascending = true
    /// Show-pattern filter: files must match it, folders are always shown. Empty = no filter.
    @Published private(set) var filter = ""
    /// Remembered between "select by pattern" prompts.
    var lastPattern = "*"
    private var sizeGeneration = 0
    typealias Measure = FolderSize.Measure
    private var sizeCache: [URL: Int64] = [:]     // folder sizes calculated on request

    /// Item the view should select after the next load (e.g. the folder we just left via Parent).
    var revealOnLoad: URL?

    private var backStack: [URL] = []
    private var watcher: DirectoryWatcher?
    private var loadGeneration = 0          // lets a late answer from a server be ignored

    /// Sum of the known sizes of the selected items.
    var selectedBytes: Int64 {
        let selected = Set(selectedURLs)
        return items.filter { selected.contains($0.url) }.compactMap(\.size).reduce(0, +)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var isRemote: Bool { RemoteURL.isRemote(url) }
    var canGoParent: Bool { !isVirtual && (RemoteURL.isRemote(url) ? RemoteURL.path(of: url) != "/" : url.path != "/") }

    /// Two locations are the same folder when their keys are equal (symlinks in /var vs /private/var are
    /// folded for local folders).
    static func comparisonKey(_ url: URL) -> String {
        if url.scheme == VirtualPlace.scheme { return url.absoluteString }
        return RemoteURL.isRemote(url) ? RemoteURL.normalized(url).absoluteString : url.standardizedFileURL.path
    }

    /// What the path field shows: a plain path for local folders, the URL for servers.
    static func displayPath(_ url: URL) -> String {
        if let place = VirtualPlace.place(for: url) { return place.title }
        return url.isFileURL ? url.path : (RemoteURL.normalized(url).absoluteString.removingPercentEncoding ?? url.absoluteString)
    }

    /// Recents and Shared are lists, not folders.
    var virtualPlace: VirtualPlace? { VirtualPlace.place(for: url) }
    var isVirtual: Bool { virtualPlace != nil }
    private var sortBeforeVirtual: (key: SortKey, ascending: Bool)?
    private var sharedObserver: NSObjectProtocol?

    init(url: URL) {
        self.url = VirtualPlace.place(for: url) != nil ? url : (RemoteURL.isRemote(url) ? RemoteURL.normalized(url) : url.standardizedFileURL)
        reload()
        watchCurrentFolder()
        sharedObserver = NotificationCenter.default.addObserver(forName: .sharedPlacesChanged, object: nil, queue: .main) { [weak self] _ in
            if self?.virtualPlace == .shared { self?.loadVirtual() }
        }
    }

    deinit { if let sharedObserver { NotificationCenter.default.removeObserver(sharedObserver) } }

    // MARK: Recents and Shared

    private func navigateVirtual(_ place: VirtualPlace, recordHistory: Bool) -> Bool {
        if place.url != url, recordHistory { backStack.append(url) }
        if sortBeforeVirtual == nil { sortBeforeVirtual = (sortKey, ascending) }
        sortKey = place == .recents ? .date : .name
        ascending = place != .recents
        watcher?.stop()
        watcher = nil
        sizeCache = [:]
        url = place.url
        items = []
        errorMessage = nil
        loadVirtual()
        return true
    }

    /// Leaving Recents / Shared brings back the sort order the user had.
    private func restoreSortAfterVirtual() {
        guard let saved = sortBeforeVirtual else { return }
        sortKey = saved.key
        ascending = saved.ascending
        sortBeforeVirtual = nil
    }

    func loadVirtual() {
        guard let place = virtualPlace else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let patterns = NamePattern.parse(filter)
        func shown(_ list: [FileItem]) -> [FileItem] {
            let kept = filter.isEmpty ? list : list.filter { $0.isNavigable || NamePattern.matches($0.name, patterns: patterns) }
            return Self.sorted(kept, by: sortKey, ascending: ascending)
        }
        switch place {
        case .recents:
            statusMessage = tr("Searching…")
            let columns = ColumnSettings.visible
            RecentFiles.fetch { [weak self] seeds in
                guard let self, generation == self.loadGeneration, self.virtualPlace == .recents else { return }
                if self.statusMessage == tr("Searching…") { self.statusMessage = nil }
                let made: [FileItem] = seeds.map { seed in
                    var item = self.makeItem(for: seed.url, keys: Self.itemKeys(columns), columns: columns)
                    item.modified = seed.lastUsed              // the list is about when a file was last opened
                    return item
                }
                self.items = shown(made)
                if self.items.isEmpty { self.flash(tr("No recently opened files found")) }
            }
        case .shared:
            SharedPlaces.shared.start()
            items = shown(SharedPlaces.shared.rows())
            if items.isEmpty { statusMessage = tr("Searching the network…") }
            else if statusMessage == tr("Searching the network…") { statusMessage = nil }
        }
    }

    // MARK: Auto-refresh

    /// Re-reads the folder when something changes on disk (FSEvents).
    private func watchCurrentFolder() {
        watcher?.stop()
        watcher = nil
        guard url.isFileURL else { return }     // servers are refreshed on request, not watched
        watcher = DirectoryWatcher(directory: url) { [weak self] in self?.refreshFromDisk() }
    }

    /// Quiet reload: keeps messages and selection, and does nothing when the listing is unchanged.
    func refreshFromDisk() {
        guard url.isFileURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = tr("This folder no longer exists")
            return
        }
        guard let listing = try? Self.sorted(list(url), by: sortKey, ascending: ascending), listing != items else { return }
        revealOnLoad = nil
        items = listing
    }

    // MARK: Navigation

    @discardableResult
    func navigate(to target: URL, selecting: URL? = nil, recordHistory: Bool = true) -> Bool {
        if let place = VirtualPlace.place(for: target) { return navigateVirtual(place, recordHistory: recordHistory) }
        if RemoteURL.isRemote(target) { return navigateRemote(RemoteURL.normalized(target), selecting: selecting, recordHistory: recordHistory) }
        let target = target.standardizedFileURL
        if target != url { sizeCache = [:] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = tr("Not a folder: %@", target.path)
            return false
        }
        restoreSortAfterVirtual()
        do {
            let listing = Self.sorted(try list(target), by: sortKey, ascending: ascending)
            if recordHistory, target != url { backStack.append(url) }
            revealOnLoad = selecting
            url = target            // before items: observers of `items` already see the new url
            items = listing
            errorMessage = nil
            PathHistory.shared.add(target)
            watchCurrentFolder()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Servers

    /// Lists a server folder in the background; the lister keeps showing the old folder until the answer
    /// arrives, and a slower earlier answer never overwrites a newer one.
    private func navigateRemote(_ target: URL, selecting: URL?, recordHistory: Bool) -> Bool {
        guard let session = RemoteSessions.shared.session(for: target) else {
            errorMessage = tr("Not connected to %@: use Connect to Server…", RemoteURL.serverLabel(of: target))
            return false
        }
        loadGeneration += 1
        let generation = loadGeneration
        let path = RemoteURL.path(of: target)
        statusMessage = tr("Loading…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try session.fs.list(path) }
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                if self.statusMessage == tr("Loading…") { self.statusMessage = nil }
                switch result {
                case .success(let entries):
                    if recordHistory, target != self.url { self.backStack.append(self.url) }
                    self.revealOnLoad = selecting
                    self.watcher?.stop()
                    self.watcher = nil
                    self.restoreSortAfterVirtual()
                    if target != self.url { self.sizeCache = [:] }
                    self.url = target
                    self.items = Self.sorted(self.remoteItems(entries, in: target), by: self.sortKey, ascending: self.ascending)
                    self.errorMessage = nil
                    PathHistory.shared.add(target)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        return true
    }

    /// Entries of a server listing as lister rows, with the hidden-files setting and the filter applied.
    func remoteItems(_ entries: [RemoteEntry], in folder: URL) -> [FileItem] {
        let patterns = NamePattern.parse(filter)
        return entries.compactMap { entry in
            if entry.name.hasPrefix("."), !showHidden { return nil }
            if !filter.isEmpty, !entry.isDirectory, !NamePattern.matches(entry.name, patterns: patterns) { return nil }
            let child = RemoteURL.child(of: folder, named: entry.name)
            var item = FileItem(url: child, name: entry.name, isDirectory: entry.isDirectory, isPackage: false,
                                isHidden: entry.name.hasPrefix("."), size: entry.isDirectory ? sizeCache[child] : entry.size,
                                modified: entry.modified, permissions: entry.permissions)
            item.isSymlink = entry.isSymlink
            return item
        }
    }

    @discardableResult
    func navigate(toPath path: String) -> Bool {
        let typed = path.trimmingCharacters(in: .whitespaces)
        if let address = URL(string: typed), RemoteURL.isRemote(address) { return navigate(to: address) }
        if RemoteURL.isRemote(url) {
            // on a server: absolute, or relative to the folder shown
            let absolute = typed.hasPrefix("/") ? typed : RemoteURL.join(RemoteURL.path(of: url), typed)
            return navigate(to: RemoteURL.with(path: absolute, on: url))
        }
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return false }
        return navigate(to: URL(fileURLWithPath: expanded, relativeTo: url))
    }

    func goParent() {
        guard canGoParent else { return }
        navigate(to: url.deletingLastPathComponent(), selecting: url)
    }

    /// Folders Back can return to, nearest first (the list under a right-click on Back).
    var backHistory: [URL] { Array(backStack.reversed()) }

    /// Jumps back several steps at once: the folder `steps` entries back becomes current.
    func goBack(steps: Int) {
        guard steps >= 1, steps <= backStack.count else { return }
        let saved = backStack
        let target = backStack[backStack.count - steps]
        backStack.removeLast(steps)
        if !navigate(to: target, selecting: url, recordHistory: false) { backStack = saved }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if !navigate(to: previous, selecting: url, recordHistory: false) { backStack.append(previous) }
    }

    func reload(selecting: URL? = nil) {
        if isVirtual { loadVirtual(); return }
        if RemoteURL.isRemote(url) {
            _ = navigateRemote(url, selecting: selecting, recordHistory: false)
            return
        }
        do {
            let listing = Self.sorted(try list(url), by: sortKey, ascending: ascending)
            revealOnLoad = selecting
            items = listing
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleHidden() {
        showHidden.toggle()
        reload()
    }

    func setFilter(_ text: String) {
        filter = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }

    /// Shows a message in the status line for a few seconds.
    func flash(_ text: String, seconds: Double = 6) {
        statusMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.statusMessage == text { self?.statusMessage = nil }
        }
    }

    /// Used when duplicating or restoring a lister; call `reload()` afterwards.
    func apply(sort: SortKey, ascending: Bool, showHidden: Bool, filter: String) {
        sortKey = sort
        self.ascending = ascending
        self.showHidden = showHidden
        self.filter = filter
    }

    func setLabel(_ name: String, color: String?) {
        label = name
        labelColor = name.isEmpty && color == nil ? nil : color
    }

    /// How this lister is called in menus: its label, else the folder's name.
    var displayName: String {
        if !label.isEmpty { return label }
        if let place = virtualPlace { return place.title }
        return url.isFileURL ? FileManager.default.displayName(atPath: url.path) : RemoteURL.serverLabel(of: url)
    }

    func inherit(from other: ListerModel) {
        apply(sort: other.sortKey, ascending: other.ascending, showHidden: other.showHidden, filter: other.filter)
        lastPattern = other.lastPattern
    }

    /// Recursive folder sizes in the background. Each folder's size shows in the Size column as soon as it is
    /// known; the status line shows progress with a Cancel button and, at the end, the total of all folders
    /// (and what they take on disk).
    func calculateSizes(of urls: [URL]) {
        guard !urls.isEmpty, url.isFileURL else { return }
        let folder = url
        let token = CancelToken()
        sizeGeneration += 1
        let generation = sizeGeneration
        let count = urls.count
        progress = TransferStatus(text: tr("Calculating sizes…"), fraction: 0, cancel: { token.cancel() })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var total = Measure()
            var done = 0
            for item in urls {
                if token.isCancelled { break }
                DispatchQueue.main.async {
                    guard let self, self.sizeGeneration == generation else { return }
                    self.progress = TransferStatus(text: tr("Calculating sizes…") + " · \(item.lastPathComponent)",
                                                   fraction: Double(done) / Double(count), cancel: { token.cancel() })
                }
                guard let measured = FolderSize.measure(item, cancel: token) else { break }
                done += 1
                total.logical += measured.logical
                total.onDisk += measured.onDisk
                DispatchQueue.main.async {
                    guard let self, self.url == folder else { return }
                    self.sizeCache[item] = measured.logical
                    self.items = Self.sorted(self.items.map { $0.url == item ? $0.withSize(measured.logical) : $0 },
                                             by: self.sortKey, ascending: self.ascending)
                }
            }
            let cancelled = token.isCancelled
            DispatchQueue.main.async {
                guard let self, self.sizeGeneration == generation else { return }
                self.progress = nil
                guard self.url == folder else { return }
                let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
                if cancelled {
                    self.flash(tr("Cancelled after %d of %d items", done, count))
                } else {
                    self.flash(trCount("%d folders", done) + " · " + bytes(total.logical) + " · " + tr("on disk: %@", bytes(total.onDisk)), seconds: 15)
                }
            }
        }
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        guard key != sortKey || ascending != self.ascending else { return }
        sortKey = key
        self.ascending = ascending
        items = Self.sorted(items, by: key, ascending: ascending)
    }

    // MARK: Listing

    /// The resource values to read; optional ones only while their column is shown.
    static func itemKeys(_ columns: [ListerColumn]) -> Set<URLResourceKey> {
        var keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        if columns.contains(.created) { keys.insert(.creationDateKey) }
        if columns.contains(.kind) { keys.insert(.localizedTypeDescriptionKey) }
        if columns.contains(.tags) { keys.insert(.tagNamesKey) }
        return keys
    }

    private func makeItem(for u: URL, keys: Set<URLResourceKey>, columns: [ListerColumn]) -> FileItem {
        let values = try? u.resourceValues(forKeys: keys)
        var isDirectory = values?.isDirectory ?? false
        if values?.isSymbolicLink == true {   // a link to a folder behaves like a folder
            let target = u.resolvingSymlinksInPath()
            isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        var item = FileItem(
            url: u,
            name: u.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: values?.isPackage ?? false,
            isHidden: values?.isHidden ?? u.lastPathComponent.hasPrefix("."),
            size: isDirectory ? sizeCache[u] : values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate
        )
        if columns.contains(.created) { item.created = values?.creationDate }
        if columns.contains(.kind) { item.kind = values?.localizedTypeDescription }
        if columns.contains(.tags) { item.tags = values?.tagNames ?? [] }
        if columns.contains(.permissions) {
            item.permissions = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue
        }
        if columns.contains(.comment) { item.comment = FinderMetadata.comment(of: u) }
        return item
    }

    private func list(_ directory: URL) throws -> [FileItem] {
        let columns = ColumnSettings.visible          // optional data is read only when its column is shown
        let keys = Self.itemKeys(columns)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let listed: [FileItem] = urls.map { makeItem(for: $0, keys: keys, columns: columns) }
        guard !filter.isEmpty else { return listed }
        let patterns = NamePattern.parse(filter)
        return listed.filter { $0.isNavigable || NamePattern.matches($0.name, patterns: patterns) }
    }

    /// Folders come first (unless the setting is off); inside each group, or among everything, the chosen column decides.
    static func sorted(_ items: [FileItem], by key: SortKey, ascending: Bool, foldersFirst: Bool = Settings.foldersFirst) -> [FileItem] {
        items.sorted { a, b in
            if foldersFirst, a.isNavigable != b.isNavigable { return a.isNavigable }
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .size:
                order = compare(a.size ?? -1, b.size ?? -1)
            case .date:
                order = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .created:
                order = compare(a.created ?? .distantPast, b.created ?? .distantPast)
            case .kind:
                order = (a.kind ?? "").localizedStandardCompare(b.kind ?? "")
            case .ext:
                order = a.url.pathExtension.lowercased().localizedStandardCompare(b.url.pathExtension.lowercased())
            case .permissions:
                order = compare(a.permissions ?? -1, b.permissions ?? -1)
            case .tags:
                order = a.tags.joined(separator: ",").localizedStandardCompare(b.tags.joined(separator: ","))
            case .comment:
                order = (a.comment ?? "").localizedStandardCompare(b.comment ?? "")
            case .folder:
                order = a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
