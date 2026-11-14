import Foundation
import Combine

struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?

    /// Folders we can descend into (bundles such as .app are opened, not entered).
    var isNavigable: Bool { isDirectory && !isPackage }

    func withSize(_ newSize: Int64) -> FileItem {
        FileItem(url: url, name: name, isDirectory: isDirectory, isPackage: isPackage, isHidden: isHidden,
                 size: newSize, modified: modified)
    }
}

/// Magellan-style role of a lister: Copy/Move go from the source lister to the destination lister.
enum ListerRole { case none, source, destination }

/// State of one lister: current folder, its (sorted) contents, selection, history.
final class ListerModel: ObservableObject {
    enum SortKey: String { case name, size, date }

    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?      // transient info, e.g. "Copying 3 items…"
    @Published var role: ListerRole = .none
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

    /// Sum of the known sizes of the selected items.
    var selectedBytes: Int64 {
        let selected = Set(selectedURLs)
        return items.filter { selected.contains($0.url) }.compactMap(\.size).reduce(0, +)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoParent: Bool { url.path != "/" }

    init(url: URL) {
        self.url = url.standardizedFileURL
        reload()
    }

    // MARK: Navigation

    @discardableResult
    func navigate(to target: URL, selecting: URL? = nil, recordHistory: Bool = true) -> Bool {
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func navigate(toPath path: String) -> Bool {
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
        guard !urls.isEmpty else { return }
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
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
            return FileItem(
                url: u,
                name: u.lastPathComponent,
                isDirectory: isDirectory,
                isPackage: values?.isPackage ?? false,
                isHidden: values?.isHidden ?? u.lastPathComponent.hasPrefix("."),
                size: isDirectory ? sizeCache[u] : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate
            )
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
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
