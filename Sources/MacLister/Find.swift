import AppKit
import SwiftUI

/// What to look for and where. A lister that shows the results has the address
/// maclister://find?in=/Users/me&name=*.jpg …, so Back, Refresh and saved layouts work like for any folder.
struct FindQuery: Equatable {
    var scope: URL
    var name = ""                       // wildcards such as *.jpg; text without wildcards matches names containing it
    var content = ""                    // text inside the files
    var category: AttributeFilter.Category = .any
    var minBytes: Int64?
    var maxBytes: Int64?
    var withinDays: Int?
    var olderDays: Int?
    /// true: walk the folders ourselves (finds everything, slower); false: ask Spotlight, which has the index already.
    var scanFolders = false
    /// Flat view: every file below the folder as one list (no conditions); folders are left out, bundles stay.
    var flat = false
    /// A Finder tag the files must carry (what a click on a tag in Finder's sidebar searches for).
    var tag = ""

    /// Every file on this Mac that has the tag, as Finder's sidebar shows it.
    static func tagged(_ tag: String) -> FindQuery {
        var query = FindQuery(scope: URL(fileURLWithPath: "/"))
        query.tag = tag
        return query
    }

    /// The name, kind, size and date conditions, shared with Select by Attributes.
    var attributeFilter: AttributeFilter {
        var filter = AttributeFilter()
        filter.namePattern = name
        filter.category = category
        filter.minBytes = minBytes
        filter.maxBytes = maxBytes
        filter.modifiedWithinDays = withinDays
        filter.modifiedOlderThanDays = olderDays
        return filter
    }

    var isEmpty: Bool {
        name.isEmpty && content.isEmpty && tag.isEmpty && category == .any && minBytes == nil && maxBytes == nil && withinDays == nil && olderDays == nil
    }

    /// Last query of this session; the Find window starts from it.
    static var last: FindQuery?

    // MARK: Address

    var url: URL {
        var parts = URLComponents()
        parts.scheme = VirtualPlace.scheme
        parts.host = VirtualPlace.find.rawValue
        var items = [URLQueryItem(name: "in", value: scope.path)]
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { items.append(URLQueryItem(name: key, value: value)) } }
        add("name", name)
        add("text", content)
        add("kind", category == .any ? nil : category.rawValue)
        add("min", minBytes.map(String.init))
        add("max", maxBytes.map(String.init))
        add("within", withinDays.map(String.init))
        add("older", olderDays.map(String.init))
        add("scan", scanFolders ? "1" : nil)
        add("flat", flat ? "1" : nil)
        add("tag", tag)
        parts.queryItems = items
        return parts.url!
    }

    init(scope: URL) { self.scope = URL(fileURLWithPath: scope.path) }     // same spelling however the URL was made

    init?(url: URL) {
        guard VirtualPlace.place(for: url) == .find,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "in" })?.value, path.hasPrefix("/") else { return nil }
        func value(_ key: String) -> String? { items.first(where: { $0.name == key })?.value }
        scope = URL(fileURLWithPath: path)
        name = value("name") ?? ""
        content = value("text") ?? ""
        category = value("kind").flatMap(AttributeFilter.Category.init(rawValue:)) ?? .any
        minBytes = value("min").flatMap { Int64($0) }
        maxBytes = value("max").flatMap { Int64($0) }
        withinDays = value("within").flatMap { Int($0) }
        olderDays = value("older").flatMap { Int($0) }
        scanFolders = value("scan") == "1"
        flat = value("flat") == "1"
        tag = value("tag") ?? ""
    }

    /// "Find: *.jpg" for the title and the history menu; a tag search is called after the tag, as in Finder.
    var title: String {
        if flat { return tr("Flat view: %@", scope.lastPathComponent) }
        if !tag.isEmpty, name.isEmpty, content.isEmpty { return tag }
        let what = !name.isEmpty ? name : (!content.isEmpty ? "“\(content)”" : scope.lastPathComponent)
        return tr("Find: %@", what)
    }
}

// MARK: - The search

/// Finds files with Spotlight when the folder is indexed (the system already did the work), or by walking the
/// folders when it is not or when asked to. All callbacks run on the main queue.
enum FindEngine {
    static let limit = 5000

    struct Outcome {
        var usedSpotlight: Bool
        var truncated: Bool
        var cancelled: Bool
    }

    /// Tests replace the search with a fixed answer.
    static var override: ((FindQuery, @escaping ([URL]) -> Void) -> Void)?

    static func run(_ query: FindQuery, showHidden: Bool, cancel: CancelToken,
                    batch: @escaping ([URL]) -> Void, done: @escaping (Outcome) -> Void) {
        if let override {
            override(query) { urls in
                DispatchQueue.main.async {
                    batch(urls)
                    done(Outcome(usedSpotlight: true, truncated: false, cancelled: false))
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let useSpotlight = !query.scanFolders && SpotlightIndex.isIndexed(query.scope)
            DispatchQueue.main.async {
                if cancel.isCancelled { done(Outcome(usedSpotlight: useSpotlight, truncated: false, cancelled: true)); return }
                if useSpotlight {
                    SpotlightFind.start(query, showHidden: showHidden, cancel: cancel, batch: batch, done: done)
                } else {
                    DispatchQueue.global(qos: .userInitiated).async {
                        scan(query, showHidden: showHidden, cancel: cancel, batch: batch, done: done)
                    }
                }
            }
        }
    }

    // MARK: Matching

    /// A lightweight item for the attribute conditions, or nil when the file is gone.
    static func item(for url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return FileItem(url: url, name: url.lastPathComponent, isDirectory: values.isDirectory ?? false,
                        isPackage: values.isPackage ?? false, isHidden: url.lastPathComponent.hasPrefix("."),
                        size: values.fileSize.map(Int64.init), modified: values.contentModificationDate)
    }

    /// Does a file the search found satisfy the query? (`checkHidden`: Spotlight also returns hidden and bundle contents.)
    static func accepts(_ url: URL, query: FindQuery, showHidden: Bool, checkHidden: Bool) -> Bool {
        if checkHidden {
            let scopePath = query.scope.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(scopePath == "/" ? "/" : scopePath + "/") else { return false }
            let relative = path.dropFirst(scopePath == "/" ? 1 : scopePath.count + 1).split(separator: "/")
            if !showHidden, relative.contains(where: { $0.hasPrefix(".") }) { return false }
            if relative.dropLast().contains(where: { [".app", ".framework", ".bundle", ".photoslibrary"].contains(where: $0.hasSuffix) }) { return false }
        }
        guard let item = item(for: url) else { return false }
        if query.flat, item.isDirectory, !item.isPackage { return false }
        if !query.tag.isEmpty {
            let names = Set(FinderTags.entries(of: url).map { $0.name.lowercased() })
            guard FinderTags.aliases(of: query.tag).contains(where: { names.contains($0.lowercased()) }) else { return false }
        }
        return query.attributeFilter.matches(item)
    }

    /// Does the file contain `text` (case and accents ignored)? Text files up to 16 MB only.
    static func fileContains(_ url: URL, text: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 16_000_000,
              !data.prefix(4096).contains(0) else { return false }
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return false }
        return string.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: Walking the folders

    /// Runs on a background queue and reports on the main queue, in batches while it goes.
    static func scan(_ query: FindQuery, showHidden: Bool, cancel: CancelToken,
                     batch: @escaping ([URL]) -> Void, done: @escaping (Outcome) -> Void) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        var pending: [URL] = []
        var found = 0
        var truncated = false
        var lastFlush = Date()
        func flush() {
            guard !pending.isEmpty else { return }
            let urls = pending
            pending = []
            DispatchQueue.main.async { batch(urls) }
            lastFlush = Date()
        }
        // Without Spotlight a search of "/" (a tag) would walk the whole system and every mounted disk: stay in the home folder.
        let root = query.scope.standardizedFileURL.path == "/" ? FileManager.default.homeDirectoryForCurrentUser : query.scope
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: options,
                                                        errorHandler: { _, _ in true }) {
            for case let url as URL in walker {
                if cancel.isCancelled { break }
                if accepts(url, query: query, showHidden: showHidden, checkHidden: false),
                   query.content.isEmpty || (item(for: url)?.isDirectory == false && fileContains(url, text: query.content)) {
                    pending.append(url)
                    found += 1
                    if found >= limit { truncated = true; break }
                }
                if Date().timeIntervalSince(lastFlush) > 0.25 { flush() }
            }
        }
        flush()
        let cancelled = cancel.isCancelled
        DispatchQueue.main.async { done(Outcome(usedSpotlight: false, truncated: truncated, cancelled: cancelled)) }
    }
}

// MARK: - Spotlight

enum SpotlightIndex {
    /// Is Spotlight indexing the volume the folder is on? Network volumes and volumes with indexing off are not.
    static func isIndexed(_ folder: URL) -> Bool {
        // mdutil answers per volume ("unknown indexing state" for a folder), so ask about the volume's mount point
        guard folder.isFileURL,
              let values = try? folder.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLKey]),
              values.volumeIsLocal == true, let volume = values.volume else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", volume.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("indexing enabled") && !text.contains("indexing disabled")
    }
}

/// One NSMetadataQuery (what Finder's search uses). Lives until it has answered.
final class SpotlightFind: NSObject {
    private static var running: Set<SpotlightFind> = []

    private let metadata = NSMetadataQuery()
    private var query: FindQuery
    private var showHidden: Bool
    private var cancel: CancelToken
    private var batch: ([URL]) -> Void
    private var done: (FindEngine.Outcome) -> Void
    private var finished = false
    private var poll: Timer?

    static func start(_ query: FindQuery, showHidden: Bool, cancel: CancelToken,
                      batch: @escaping ([URL]) -> Void, done: @escaping (FindEngine.Outcome) -> Void) {
        let job = SpotlightFind(query, showHidden: showHidden, cancel: cancel, batch: batch, done: done)
        running.insert(job)
        job.begin()
    }

    private init(_ query: FindQuery, showHidden: Bool, cancel: CancelToken,
                 batch: @escaping ([URL]) -> Void, done: @escaping (FindEngine.Outcome) -> Void) {
        self.query = query
        self.showHidden = showHidden
        self.cancel = cancel
        self.batch = batch
        self.done = done
    }

    /// Spotlight does the coarse filtering (name, text inside, size, date); `FindEngine.accepts` makes sure of the rest.
    static func predicate(for query: FindQuery) -> NSPredicate {
        var parts: [NSPredicate] = []
        let patterns = NamePattern.parse(query.name)
        if !patterns.isEmpty, !patterns.contains(where: { $0.contains("[") }) {     // LIKE has no [a-z] classes
            let names = patterns.map { pattern -> NSPredicate in
                let glob = pattern.contains(where: { "*?".contains($0) }) ? pattern : "*\(pattern)*"
                return NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, glob)
            }
            parts.append(names.count == 1 ? names[0] : NSCompoundPredicate(orPredicateWithSubpredicates: names))
        }
        if !query.content.isEmpty {
            parts.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", query.content))
        }
        if let bytes = query.minBytes { parts.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSSizeKey, NSNumber(value: bytes))) }
        if let bytes = query.maxBytes { parts.append(NSPredicate(format: "%K <= %@", NSMetadataItemFSSizeKey, NSNumber(value: bytes))) }
        let now = Date()
        if let days = query.withinDays {
            parts.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, now.addingTimeInterval(-Double(days) * 86_400) as NSDate))
        }
        if let days = query.olderDays {
            parts.append(NSPredicate(format: "%K < %@", NSMetadataItemFSContentChangeDateKey, now.addingTimeInterval(-Double(days) * 86_400) as NSDate))
        }
        if !query.tag.isEmpty {         // a colour tag is stored under its English or its local name, depending on when it was set
            let tags = FinderTags.aliases(of: query.tag).map { NSPredicate(format: "%K ==[cd] %@", "kMDItemUserTags", $0) }
            parts.append(tags.count == 1 ? tags[0] : NSCompoundPredicate(orPredicateWithSubpredicates: tags))
        }
        if parts.isEmpty { parts.append(NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")) }
        // NSMetadataQuery refuses a compound predicate with a single part
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private func begin() {
        metadata.predicate = Self.predicate(for: query)
        // "/" is every local disk, not just the startup volume: tagged files may be on an external one
        metadata.searchScopes = query.scope.standardizedFileURL.path == "/" ? [NSMetadataQueryIndexedLocalComputerScope] : [query.scope]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: metadata)
        metadata.start()
        let started = Date()
        poll = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.cancel.isCancelled || Date().timeIntervalSince(started) > 90 { self.finish(cancelled: self.cancel.isCancelled) }
        }
    }

    @objc private func gathered() { finish(cancelled: false) }

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        metadata.disableUpdates()
        var paths: [String] = []
        if !cancelled {
            for index in 0..<metadata.resultCount {
                if let item = metadata.result(at: index) as? NSMetadataItem,
                   let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { paths.append(path) }
            }
        }
        metadata.stop()
        NotificationCenter.default.removeObserver(self)
        let query = query, showHidden = showHidden, batch = batch, done = done
        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [URL] = []
            var truncated = false
            for path in paths {
                let url = URL(fileURLWithPath: path)
                if FindEngine.accepts(url, query: query, showHidden: showHidden, checkHidden: true) {
                    urls.append(url)
                    if urls.count >= FindEngine.limit { truncated = true; break }
                }
            }
            DispatchQueue.main.async {
                if !urls.isEmpty { batch(urls) }
                done(FindEngine.Outcome(usedSpotlight: true, truncated: truncated, cancelled: cancelled))
                SpotlightFind.running.remove(self)
            }
        }
    }
}

// MARK: - The Find window

struct FindView: View {
    var initial: FindQuery
    var onFind: (FindQuery) -> Void
    var close: () -> Void

    @State private var name: String
    @State private var content: String
    @State private var scope: String
    @State private var category: AttributeFilter.Category
    @State private var useMin: Bool
    @State private var minValue: String
    @State private var minUnit = 1
    @State private var useMax: Bool
    @State private var maxValue: String
    @State private var maxUnit = 1
    @State private var dateMode: Int            // 0 any, 1 within last, 2 older than
    @State private var days: String
    @State private var scanFolders: Bool

    init(initial: FindQuery, onFind: @escaping (FindQuery) -> Void, close: @escaping () -> Void) {
        self.initial = initial
        self.onFind = onFind
        self.close = close
        _name = State(initialValue: initial.name)
        _content = State(initialValue: initial.content)
        _scope = State(initialValue: initial.scope.path)
        _category = State(initialValue: initial.category)
        _useMin = State(initialValue: initial.minBytes != nil)
        _minValue = State(initialValue: initial.minBytes.map { String($0 / 1_000_000) } ?? "1")
        _useMax = State(initialValue: initial.maxBytes != nil)
        _maxValue = State(initialValue: initial.maxBytes.map { String($0 / 1_000_000) } ?? "100")
        _dateMode = State(initialValue: initial.withinDays != nil ? 1 : (initial.olderDays != nil ? 2 : 0))
        _days = State(initialValue: String(initial.withinDays ?? initial.olderDays ?? 7))
        _scanFolders = State(initialValue: initial.scanFolders)
    }

    private var query: FindQuery {
        var q = FindQuery(scope: URL(fileURLWithPath: (scope as NSString).expandingTildeInPath))
        q.name = name.trimmingCharacters(in: .whitespaces)
        q.content = content.trimmingCharacters(in: .whitespaces)
        q.category = category
        if useMin, let v = Double(minValue.replacingOccurrences(of: ",", with: ".")) { q.minBytes = SelectByAttributesView.bytes(v, unit: minUnit) }
        if useMax, let v = Double(maxValue.replacingOccurrences(of: ",", with: ".")) { q.maxBytes = SelectByAttributesView.bytes(v, unit: maxUnit) }
        if let d = Int(days) {
            if dateMode == 1 { q.withinDays = d }
            if dateMode == 2 { q.olderDays = d }
        }
        q.scanFolders = scanFolders
        return q
    }

    private var scopeExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: query.scope.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find").font(.headline)
            Text("Looks in the folder and everything below it. The results appear in this lister like a folder, so you can copy, move or delete them.")
                .font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("e.g. *.jpg IMG_*", text: $name).textFieldStyle(.roundedBorder).gridCellColumns(3)
                }
                GridRow {
                    Text("Contains")
                    TextField("text inside the files", text: $content).textFieldStyle(.roundedBorder).gridCellColumns(3)
                }
                GridRow {
                    Text("Look in")
                    TextField("", text: $scope).textFieldStyle(.roundedBorder).gridCellColumns(2)
                    Button("Choose…") { chooseFolder() }
                }
                GridRow {
                    Text("Kind")
                    Picker("", selection: $category) {
                        ForEach(AttributeFilter.Category.allCases) { Text(tr($0.rawValue)).tag($0) }
                    }.labelsHidden().gridCellColumns(3)
                }
                GridRow {
                    Toggle("Larger than", isOn: $useMin)
                    TextField("", text: $minValue).textFieldStyle(.roundedBorder).frame(width: 70).disabled(!useMin)
                    Picker("", selection: $minUnit) { ForEach(0..<3) { Text(SelectByAttributesView.units[$0].name).tag($0) } }
                        .labelsHidden().frame(width: 70).disabled(!useMin)
                    Spacer()
                }
                GridRow {
                    Toggle("Smaller than", isOn: $useMax)
                    TextField("", text: $maxValue).textFieldStyle(.roundedBorder).frame(width: 70).disabled(!useMax)
                    Picker("", selection: $maxUnit) { ForEach(0..<3) { Text(SelectByAttributesView.units[$0].name).tag($0) } }
                        .labelsHidden().frame(width: 70).disabled(!useMax)
                    Spacer()
                }
                GridRow {
                    Text("Modified")
                    Picker("", selection: $dateMode) {
                        Text("Any time").tag(0)
                        Text("Within the last").tag(1)
                        Text("Older than").tag(2)
                    }.labelsHidden().frame(width: 150)
                    TextField("", text: $days).textFieldStyle(.roundedBorder).frame(width: 60).disabled(dateMode == 0)
                    Text("days").foregroundStyle(.secondary)
                }
            }

            Toggle("Search the folders directly (slower, finds files Spotlight does not index)", isOn: $scanFolders)
            Text("By default Spotlight does the search, using the index macOS keeps already. Folders it does not index, such as network volumes, are always searched directly.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Find") { onFind(query); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.isEmpty || !scopeExists)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (scope as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { scope = url.path }
    }
}

// MARK: - Lister commands

extension ListerViewController {
    /// Opens the Find window. It starts in the folder shown here (or the one of the last search).
    func promptFind() {
        if remoteUnavailable(tr("Find")) { return }
        if refuseInArchive(tr("Find")) { return }
        guard let window = view.window else { return }
        var start = FindQuery.last ?? FindQuery(scope: FileManager.default.homeDirectoryForCurrentUser)
        if let current = FindQuery(url: model.url) { start = current }
        else if !model.isVirtual { start.scope = model.url }
        else if FindQuery.last == nil { start.scope = FileManager.default.homeDirectoryForCurrentUser }
        let initial = start
        SheetPresenter().present(on: window, size: NSSize(width: 500, height: 440)) { close in
            FindView(initial: initial, onFind: { [weak self] query in self?.startFind(query) }, close: close)
        }
    }

    /// Flat view: all files of this folder and its sub-folders in one list; the same command leaves it again.
    func toggleFlatView() {
        if remoteUnavailable(tr("Flat view")) { return }
        if refuseInArchive(tr("Flat view")) { return }
        if let current = FindQuery(url: model.url), current.flat {
            model.navigate(to: current.scope)
            return
        }
        if refuseInList(tr("Flat view")) { return }
        var query = FindQuery(scope: model.url)
        query.flat = true
        query.scanFolders = true            // a plain walk: no index needed, and nothing is left out
        model.navigate(to: query.url)
    }

    var flatViewMenuTitle: String {
        FindQuery(url: model.url)?.flat == true ? tr("Leave Flat View") : tr("Flat View")
    }

    func startFind(_ query: FindQuery) {
        FindQuery.last = query
        model.navigate(to: query.url)
    }
}
