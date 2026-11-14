import AppKit

/// ~/Library/Application Support/MacLister (the self-test redirects it into a temp folder).
enum AppSupport {
    static var override: URL?

    static var directory: URL {
        if let override { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacLister", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// Magellan's "hotlist": favourite folders, kept in bookmarks.json.
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published private(set) var paths: [String] = []
    private var file: URL { AppSupport.directory.appendingPathComponent("bookmarks.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String].self, from: data) {
            paths = saved
        }
    }

    /// Local folders are stored as paths, servers as URLs.
    static func key(for url: URL) -> String { ListerModel.comparisonKey(url) }

    static func url(forKey key: String) -> URL {
        if key.contains("://"), let url = URL(string: key) { return url }
        return URL(fileURLWithPath: key)
    }

    func contains(_ url: URL) -> Bool { paths.contains(Self.key(for: url)) }

    func add(_ url: URL) {
        let path = Self.key(for: url)
        guard !paths.contains(path) else { return }
        paths.append(path)
        save()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(paths).write(to: file, options: .atomic)
    }
}

/// Recently visited folders across all listers.
final class PathHistory: ObservableObject {
    static let shared = PathHistory()
    private static let key = "recentPaths"

    @Published private(set) var recent: [String]

    private init() {
        recent = AppSupport.override == nil ? (UserDefaults.standard.stringArray(forKey: Self.key) ?? []) : []
    }

    func add(_ url: URL) {
        let path = BookmarkStore.key(for: url)
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 15 { recent.removeLast(recent.count - 15) }
        if AppSupport.override == nil { UserDefaults.standard.set(recent, forKey: Self.key) }
    }
}

// MARK: - Filetypes (what a double-click does)

struct FiletypeRule: Codable {
    enum Action: String, Codable {
        case open        // default system behaviour
        case extract     // unpack into a sub-folder
        case quicklook
        case app         // open with `app` (bundle identifier or path to an .app)
        case shell       // run `command` (the file is in $LISTER_SELECTION)
    }
    var extensions: [String]       // "zip", "tar.gz" … matched against the end of the name
    var action: Action
    var app: String?
    var command: String?
}

/// filetypes.json — Magellan's filetype definitions. Re-read whenever the file changes.
final class FiletypeStore {
    static let shared = FiletypeStore()

    static let defaults: [FiletypeRule] = [
        FiletypeRule(extensions: ["zip", "tar", "tar.gz", "tgz", "tar.bz2", "tbz2", "tar.xz", "txz", "tar.zst", "7z", "rar", "gz", "bz2"],
                     action: .extract),
    ]

    private var rules: [FiletypeRule] = FiletypeStore.defaults
    private var loadedStamp: Date?
    private var loadedPath: String?

    var configURL: URL { AppSupport.directory.appendingPathComponent("filetypes.json") }

    func ensureConfigFileExists() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(Self.defaults).write(to: configURL, options: .atomic)
    }

    func rule(for url: URL) -> FiletypeRule? {
        reloadIfNeeded()
        let name = url.lastPathComponent.lowercased()
        return rules.first { rule in
            rule.extensions.contains { name.hasSuffix("." + $0.lowercased()) && name.count > $0.count + 1 }
        }
    }

    private func reloadIfNeeded() {
        ensureConfigFileExists()
        let stamp = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        guard stamp != loadedStamp || configURL.path != loadedPath else { return }
        loadedStamp = stamp
        loadedPath = configURL.path
        guard let data = try? Data(contentsOf: configURL) else { return }
        do { rules = try JSONDecoder().decode([FiletypeRule].self, from: data) }
        catch { NSLog("[MacLister] filetypes.json not applied: %@", String(describing: error)) }
    }
}

// MARK: - Saved layouts ("snapshot")

struct ListerSnapshot: Codable {
    var path: String
    var x: Double, y: Double, width: Double, height: Double
    var role: String
    var sort: String
    var ascending: Bool
    var showHidden: Bool
    var filter: String
    var locked: Bool?
}

enum LayoutStore {
    static var url: URL { AppSupport.directory.appendingPathComponent("layout.json") }

    /// Remembers every open lister: folder, position, size, role, sort, filter.
    @discardableResult
    static func save(from manager: ListerManager) -> Int {
        let snapshots: [ListerSnapshot] = manager.allControllers.compactMap { controller in
            guard let frame = controller.window?.frame, controller.model.url.isFileURL else { return nil }   // servers are not restored
            let model = controller.model
            let role: String
            switch model.role { case .source: role = "source"; case .destination: role = "destination"; case .none: role = "none" }
            return ListerSnapshot(path: model.url.path, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                  role: role, sort: model.sortKey.rawValue, ascending: model.ascending,
                                  showHidden: model.showHidden, filter: model.filter,
                                  locked: model.roleLocked ? true : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(snapshots).write(to: url, options: .atomic)
        return snapshots.count
    }

    /// Opens the saved listers (existing ones stay). Returns how many were opened.
    @discardableResult
    static func restore(into manager: ListerManager) -> Int {
        guard let data = try? Data(contentsOf: url),
              let snapshots = try? JSONDecoder().decode([ListerSnapshot].self, from: data) else { return 0 }
        var opened = 0
        for snapshot in snapshots {
            let folder = URL(fileURLWithPath: snapshot.path)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let controller = manager.openLister(directory: folder, anchor: .origin(NSPoint(x: snapshot.x, y: snapshot.y))) { controller in
                controller.window?.setFrame(NSRect(x: snapshot.x, y: snapshot.y, width: snapshot.width, height: snapshot.height), display: false)
                controller.model.apply(sort: ListerModel.SortKey(rawValue: snapshot.sort) ?? .name,
                                       ascending: snapshot.ascending, showHidden: snapshot.showHidden, filter: snapshot.filter)
                controller.model.reload()
            }
            switch snapshot.role {
            case "source":      manager.toggleRole(.source, for: controller)
            case "destination": manager.toggleRole(.destination, for: controller)
            default:            break
            }
            if snapshot.locked == true { controller.model.roleLocked = true }
            opened += 1
        }
        return opened
    }
}
