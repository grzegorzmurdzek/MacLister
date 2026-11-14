import Foundation
import Combine

struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    var size: Int64?
    let modified: Date?
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
}

/// Magellan-style role of a lister: Copy/Move go from the source lister to the destination lister.
enum ListerRole { case none, source, destination }

/// State of one lister: current folder, its (sorted) contents, selection, history.
final class ListerModel: ObservableObject {
    enum SortKey: String { case name, size, date, created, kind, ext, permissions, tags, comment }

    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?      // transient info, e.g. "Copying 3 items…"
    @Published var progress: TransferStatus?   // running copy / move: progress bar with a Cancel button
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
    var canGoParent: Bool { RemoteURL.isRemote(url) ? RemoteURL.path(of: url) != "/" : url.path != "/" }

    /// Two locations are the same folder when their keys are equal (symlinks in /var vs /private/var are
    /// folded for local folders).
    static func comparisonKey(_ url: URL) -> String {
        RemoteURL.isRemote(url) ? RemoteURL.normalized(url).absoluteString : url.standardizedFileURL.path
    }

    /// What the path field shows: a plain path for local folders, the URL for servers.
    static func displayPath(_ url: URL) -> String {
        url.isFileURL ? url.path : (RemoteURL.normalized(url).absoluteString.removingPercentEncoding ?? url.absoluteString)
    }

    init(url: URL) {
        self.url = RemoteURL.isRemote(url) ? RemoteURL.normalized(url) : url.standardizedFileURL
        reload()
        watchCurrentFolder()
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
            errorMessage = "This folder no longer exists"
            return
        }
        guard let listing = try? Self.sorted(list(url), by: sortKey, ascending: ascending), listing != items else { return }
        revealOnLoad = nil
        items = listing
    }

    // MARK: Navigation

    @discardableResult
    func navigate(to target: URL, selecting: URL? = nil, recordHistory: Bool = true) -> Bool {
        if RemoteURL.isRemote(target) { return navigateRemote(RemoteURL.normalized(target), selecting: selecting, recordHistory: recordHistory) }
        let target = target.standardizedFileURL
        if target != url { sizeCache = [:] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Not a folder: \(target.path)"
            return false
        }
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
            errorMessage = "Not connected to \(RemoteURL.serverLabel(of: target)): use Connect to Server…"
            return false
        }
        loadGeneration += 1
        let generation = loadGeneration
        let path = RemoteURL.path(of: target)
        statusMessage = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try session.fs.list(path) }
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                if self.statusMessage == "Loading…" { self.statusMessage = nil }
                switch result {
                case .success(let entries):
                    if recordHistory, target != self.url { self.backStack.append(self.url) }
                    self.revealOnLoad = selecting
                    self.watcher?.stop()
                    self.watcher = nil
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

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if !navigate(to: previous, selecting: url, recordHistory: false) { backStack.append(previous) }
    }

    func reload(selecting: URL? = nil) {
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

    func inherit(from other: ListerModel) {
        apply(sort: other.sortKey, ascending: other.ascending, showHidden: other.showHidden, filter: other.filter)
        lastPattern = other.lastPattern
    }

    /// Recursive folder sizes in the background; the Size column fills in when ready.
    func calculateSizes(of urls: [URL]) {
        guard !urls.isEmpty, url.isFileURL else { return }
        let folder = url
        statusMessage = "Calculating sizes…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [URL: Int64] = [:]
            for item in urls { results[item] = FolderSize.total(of: item) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = nil
                guard self.url == folder else { return }
                for (key, value) in results { self.sizeCache[key] = value }
                let updated = self.items.map { results[$0.url].map($0.withSize) ?? $0 }
                self.items = Self.sorted(updated, by: self.sortKey, ascending: self.ascending)
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

    private func list(_ directory: URL) throws -> [FileItem] {
        var keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let columns = ColumnSettings.visible          // optional data is read only when its column is shown
        if columns.contains(.created) { keys.append(.creationDateKey) }
        if columns.contains(.kind) { keys.append(.localizedTypeDescriptionKey) }
        if columns.contains(.tags) { keys.append(.tagNamesKey) }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let listed: [FileItem] = urls.map { u in
            let values = try? u.resourceValues(forKeys: Set(keys))
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
        guard !filter.isEmpty else { return listed }
        let patterns = NamePattern.parse(filter)
        return listed.filter { $0.isNavigable || NamePattern.matches($0.name, patterns: patterns) }
    }

    /// Folders always come first; inside each group the chosen column decides.
    static func sorted(_ items: [FileItem], by key: SortKey, ascending: Bool) -> [FileItem] {
        items.sorted { a, b in
            if a.isNavigable != b.isNavigable { return a.isNavigable }
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
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
