import SwiftUI
import AppKit

/// Finds files with the same content below a folder: first by size (free), then by the first 64 KB, then by a full
/// SHA-256, so only files that really might be equal are read completely. Hard links to one file count once.
enum DuplicateFinder {
    struct Group: Identifiable, Equatable {
        let id: Int
        let size: Int64
        var files: [URL]                // oldest first
        var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
    }

    struct Options: Equatable {
        var scope: URL
        var minBytes: Int64 = 1
        var includeHidden = false
    }

    static let prefixBytes = 64 * 1024

    /// Groups of two or more equal files, the ones that waste the most space first. nil when `cancel` fired.
    /// `progress` is called from the calling thread with a short status text.
    static func find(_ options: Options, cancel: CancelToken, progress: @escaping (String) -> Void) -> [Group]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey, .contentModificationDateKey]
        var walkOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeHidden { walkOptions.insert(.skipsHiddenFiles) }
        guard let walker = FileManager.default.enumerator(at: options.scope, includingPropertiesForKeys: keys, options: walkOptions,
                                                          errorHandler: { _, _ in true }) else { return [] }
        var bySize: [Int64: [URL]] = [:]
        var seen = Set<NSObject>()
        var listed = 0
        for case let url as URL in walker {
            if cancel.isCancelled { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize.map(Int64.init), size >= max(1, options.minBytes) else { continue }
            if let identifier = values.fileResourceIdentifier as? NSObject, !seen.insert(identifier).inserted { continue }
            bySize[size, default: []].append(url)
            listed += 1
            if listed % 500 == 0 { progress(tr("Listing files… %d", listed)) }
        }

        let candidates = bySize.filter { $0.value.count > 1 }
        let total = candidates.values.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [Group] = []
        var nextID = 0
        for (size, urls) in candidates.sorted(by: { $0.key > $1.key }) {
            // 1. the first 64 KB
            var byPrefix: [String: [URL]] = [:]
            for url in urls {
                if cancel.isCancelled { return nil }
                if let hash = FileHash.sha256Prefix(of: url, bytes: prefixBytes) { byPrefix[hash, default: []].append(url) }
                done += 1
                if done % 20 == 0 { progress(tr("Comparing… %d of %d", done, total)) }
            }
            for (_, sameStart) in byPrefix where sameStart.count > 1 {
                // 2. the whole file, unless the first 64 KB were all of it
                var sets: [[URL]] = []
                if size <= Int64(prefixBytes) {
                    sets = [sameStart]
                } else {
                    var byHash: [String: [URL]] = [:]
                    for url in sameStart {
                        if cancel.isCancelled { return nil }
                        progress(tr("Reading %@", url.lastPathComponent))
                        if let hash = FileHash.sha256(of: url, cancel: cancel) { byHash[hash, default: []].append(url) }
                    }
                    if cancel.isCancelled { return nil }
                    sets = byHash.values.filter { $0.count > 1 }
                }
                for set in sets {
                    let ordered = set.sorted {
                        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return a == b ? $0.path < $1.path : a < b
                    }
                    groups.append(Group(id: nextID, size: size, files: ordered))
                    nextID += 1
                }
            }
        }
        return groups.sorted { $0.wasted == $1.wasted ? $0.id < $1.id : $0.wasted > $1.wasted }
    }
}

// MARK: - The window

struct DuplicatesView: View {
    var initial: DuplicateFinder.Options
    /// Moves the files to the Trash (the lister logs it for Undo) and reports which ones went.
    var onTrash: ([URL], @escaping ([URL]) -> Void) -> Void
    var close: () -> Void

    @State private var scope: String
    @State private var minimum = 0                    // index into `Self.minimums`
    @State private var includeHidden: Bool
    @State private var groups: [DuplicateFinder.Group] = []
    @State private var marked: Set<URL> = []
    @State private var phase = Phase.idle
    @State private var status = ""
    @State private var token = CancelToken()

    enum Phase { case idle, searching, done }

    private static let minimums: [(title: String, bytes: Int64)] = [("Any size", 1), ("1 KB or more", 1_000), ("100 KB or more", 100_000), ("1 MB or more", 1_000_000), ("10 MB or more", 10_000_000)]

    init(initial: DuplicateFinder.Options, onTrash: @escaping ([URL], @escaping ([URL]) -> Void) -> Void, close: @escaping () -> Void) {
        self.initial = initial
        self.onTrash = onTrash
        self.close = close
        _scope = State(initialValue: initial.scope.path)
        _includeHidden = State(initialValue: initial.includeHidden)
    }

    private var scopeURL: URL { URL(fileURLWithPath: (scope as NSString).expandingTildeInPath) }
    private var scopeExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: scopeURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private var markedSize: Int64 {
        groups.reduce(0) { total, group in total + group.size * Int64(group.files.filter(marked.contains).count) }
    }

    private func isMarkable(_ url: URL, in group: DuplicateFinder.Group) -> Bool {
        // a group always keeps at least one file
        marked.contains(url) || group.files.contains { $0 != url && !marked.contains($0) }
    }

    private func toggle(_ url: URL, in group: DuplicateFinder.Group) {
        if marked.contains(url) { marked.remove(url) }
        else if isMarkable(url, in: group) { marked.insert(url) }
        else { NSSound.beep() }
    }

    /// Marks every copy except the oldest (`keepOldest`) or the newest one in each group.
    private func markAllExceptOne(keepOldest: Bool) {
        marked = []
        for group in groups {
            let keep = keepOldest ? group.files.first : group.files.last
            for file in group.files where file != keep { marked.insert(file) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Duplicates").font(.headline)
            Text("Finds files with exactly the same content below a folder. Nothing is deleted until you mark copies and press the Trash button; at least one copy of each file always stays.")
                .font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Look in")
                    TextField("", text: $scope).textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
                GridRow {
                    Text("Files")
                    Picker("", selection: $minimum) {
                        ForEach(Self.minimums.indices, id: \.self) { Text(tr(Self.minimums[$0].title)).tag($0) }
                    }.labelsHidden().frame(width: 160)
                    Toggle("Include hidden files", isOn: $includeHidden)
                }
            }

            HStack {
                if phase == .searching {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Stop") { token.cancel() }
                } else {
                    Button(phase == .done ? "Search Again" : "Search") { search() }
                        .keyboardShortcut(.defaultAction).disabled(!scopeExists)
                    Spacer()
                    if phase == .done, !groups.isEmpty {
                        Menu("Mark") {
                            Button("All except the oldest in each group") { markAllExceptOne(keepOldest: true) }
                            Button("All except the newest in each group") { markAllExceptOne(keepOldest: false) }
                            Divider()
                            Button("Unmark all") { marked = [] }
                        }.fixedSize()
                    }
                }
            }

            if phase == .done {
                if groups.isEmpty {
                    Text("No duplicates found").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.files, id: \.self) { url in
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: Binding(get: { marked.contains(url) }, set: { _ in toggle(url, in: group) }))
                                            .labelsHidden()
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Text(PathText.short(url.deletingLastPathComponent().path)).font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 8)
                                        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle") }
                                            .buttonStyle(.borderless).help("Reveal in Finder")
                                    }
                                }
                            } header: {
                                Text(tr("%d copies · %@ each · %@ wasted", group.files.count, bytes(group.size), bytes(group.wasted)))
                            }
                        }
                    }
                    .frame(minHeight: 220)
                }
            } else if phase == .idle {
                Spacer(minLength: 0)
            }

            HStack {
                if phase == .done, !groups.isEmpty {
                    let wasted = groups.reduce(0) { $0 + $1.wasted }
                    Text(marked.isEmpty ? tr("%d groups · %@ could be freed", groups.count, bytes(wasted))
                                        : tr("%d marked · %@ will be freed", marked.count, bytes(markedSize)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { token.cancel(); close() }.keyboardShortcut(.cancelAction)
                Button(tr("Move %d to the Trash", marked.count)) { trashMarked() }
                    .disabled(marked.isEmpty || phase == .searching)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = scopeURL
        if panel.runModal() == .OK, let url = panel.url { scope = url.path }
    }

    private func search() {
        token.cancel()
        let fresh = CancelToken()
        token = fresh
        phase = .searching
        status = tr("Listing files… %d", 0)
        groups = []
        marked = []
        let options = DuplicateFinder.Options(scope: scopeURL, minBytes: Self.minimums[minimum].bytes, includeHidden: includeHidden)
        DispatchQueue.global(qos: .userInitiated).async {
            var lastReport = Date.distantPast
            let found = DuplicateFinder.find(options, cancel: fresh) { text in
                guard Date().timeIntervalSince(lastReport) > 0.15 else { return }
                lastReport = Date()
                DispatchQueue.main.async { if token === fresh { status = text } }
            }
            DispatchQueue.main.async {
                guard token === fresh else { return }
                if let found { groups = found; phase = .done } else { phase = groups.isEmpty ? .idle : .done }
            }
        }
    }

    private func trashMarked() {
        let urls = Array(marked)
        phase = .searching
        status = tr("Moving to the Trash…")
        onTrash(urls) { trashed in
            let gone = Set(trashed)
            groups = groups.compactMap { group in
                var rest = group
                rest.files.removeAll { gone.contains($0) }
                return rest.files.count > 1 ? rest : nil
            }
            marked.subtract(gone)
            phase = .done
        }
    }
}

extension ListerViewController {
    /// Opens the Find Duplicates window, starting in the folder shown here.
    func promptDuplicates() {
        if remoteUnavailable(tr("Find Duplicates")) { return }
        guard let window = view.window else { return }
        let start = model.isVirtual ? (FindQuery(url: model.url)?.scope ?? FileManager.default.homeDirectoryForCurrentUser) : model.url
        let options = DuplicateFinder.Options(scope: start, includeHidden: model.showHidden)
        SheetPresenter().present(on: window, size: NSSize(width: 720, height: 600)) { close in
            DuplicatesView(initial: options, onTrash: { [weak self] urls, completion in
                self?.trashDuplicates(urls, completion: completion)
            }, close: close)
        }
    }

    /// Moves the files to the Trash and logs it, so ⌘Z brings them back.
    func trashDuplicates(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = TransferResult()
            for url in urls {
                do {
                    var landed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                    result.done.append(url)
                    if let landed { result.pairs.append(TransferPair(source: url, target: landed as URL)) }
                } catch { result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                OperationLog.shared.record(kind: .trash, items: urls, result: result,
                                           from: Self.placeName(urls.first?.deletingLastPathComponent()), to: tr("Trash"))
                ListerManager.shared.reloadListers(showing: urls.map { $0.deletingLastPathComponent() })
                if !result.failures.isEmpty { self?.model.errorMessage = result.failures.prefix(3).joined(separator: "; ") }
                completion(result.done)
            }
        }
    }
}
