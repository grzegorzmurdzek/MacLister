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

    /// Forgets every recent folder.
    func clear() {
        recent = []
        if AppSupport.override == nil { UserDefaults.standard.removeObject(forKey: Self.key) }
    }
}

/// "Clear …" commands that first ask the user.
enum HistoryClearing {
    enum Kind { case recentFolders, operationLog }

    /// Tests replace the question.
    static var confirm: (_ title: String, _ detail: String) -> Bool = { title, detail in
        NSApp.bringToFront()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: tr("Clear")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks, then clears. Returns whether anything was cleared.
    @discardableResult
    static func confirmAndClear(_ kind: Kind) -> Bool {
        switch kind {
        case .recentFolders:
            guard !PathHistory.shared.recent.isEmpty else { return false }
            guard confirm(tr("Clear the list of recent folders?"), tr("The Go menu forgets the folders you visited. Bookmarks and files are not affected.")) else { return false }
            PathHistory.shared.clear()
        case .operationLog:
            guard !OperationLog.shared.records.isEmpty else { return false }
            guard confirm(tr("Clear the operation log?"), tr("Files are not affected, but Undo will no longer be possible.")) else { return false }
            OperationLog.shared.clear()
        }
        return true
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
extension FiletypeStore {
    /// Opens filetypes.json in a text editor.
    static func openInEditor() {
        shared.ensureConfigFileExists()
        let file = shared.configURL
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

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
    var label: String?
    var labelColor: String?
    /// Listers with the same number were tabs of one window (in this order); `selectedTab`: the tab that was shown.
    var tabGroup: Int?
    var selectedTab: Bool?
}

enum LayoutStore {
    static var url: URL { AppSupport.directory.appendingPathComponent("layout.json") }

    /// Remembers every open lister: folder, position, size, role, sort, filter.
    @discardableResult
    static func save(from manager: ListerManager) -> Int {
        var groups: [ObjectIdentifier: Int] = [:]
        let snapshots: [ListerSnapshot] = manager.menuOrder.compactMap { controller, _ in
            guard let frame = controller.window?.frame, controller.model.url.isFileURL else { return nil }   // servers are not restored
            let model = controller.model
            var tabGroup: Int?
            if manager.tabs(of: controller).count > 1, let group = controller.window?.tabGroup {
                tabGroup = groups[ObjectIdentifier(group)] ?? groups.count
                groups[ObjectIdentifier(group)] = tabGroup
            }
            let role: String
            switch model.role { case .source: role = "source"; case .destination: role = "destination"; case .none: role = "none" }
            return ListerSnapshot(path: model.url.path, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                  role: role, sort: model.sortKey.rawValue, ascending: model.ascending,
                                  showHidden: model.showHidden, filter: model.filter,
                                  locked: model.roleLocked ? true : nil,
                                  label: model.label.isEmpty ? nil : model.label, labelColor: model.labelColor,
                                  tabGroup: tabGroup, selectedTab: tabGroup == nil ? nil : manager.isSelectedTab(controller))
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
        var opened: [(controller: ListerWindowController, snapshot: ListerSnapshot)] = []
        manager.restoringLayout = true      // the layout brings its own roles
        defer { manager.restoringLayout = false }
        var groupHosts: [Int: ListerWindowController] = [:]
        for snapshot in snapshots {
            let folder = URL(fileURLWithPath: snapshot.path)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let configure: (ListerWindowController) -> Void = { controller in
                controller.model.apply(sort: ListerModel.SortKey(rawValue: snapshot.sort) ?? .name,
                                       ascending: snapshot.ascending, showHidden: snapshot.showHidden, filter: snapshot.filter)
                controller.model.reload()
            }
            let controller: ListerWindowController
            // Tabs come back as tabs while tabs are on; otherwise each one is a window of its own.
            if let group = snapshot.tabGroup, Settings.listerTabs, let host = groupHosts[group],
               let tab = manager.openTab(directory: folder, in: host, configure: configure) {
                controller = tab
            } else {
                controller = manager.openLister(directory: folder, anchor: .origin(NSPoint(x: snapshot.x, y: snapshot.y))) { controller in
                    controller.window?.setFrame(NSRect(x: snapshot.x, y: snapshot.y, width: snapshot.width, height: snapshot.height), display: false)
                    configure(controller)
                }
                if let group = snapshot.tabGroup { groupHosts[group] = controller }
            }
            if let label = snapshot.label { controller.model.setLabel(label, color: snapshot.labelColor) }
            else if snapshot.labelColor != nil { controller.model.setLabel("", color: snapshot.labelColor) }
            opened.append((controller, snapshot))
        }
        // The tab that was shown is shown again; then the roles, which belong to the tabs you see.
        for (controller, snapshot) in opened where snapshot.selectedTab == true { manager.select(controller) }
        for (controller, snapshot) in opened {
            switch snapshot.role {
            case "source":      manager.toggleRole(.source, for: controller)
            case "destination": manager.toggleRole(.destination, for: controller)
            default:            break
            }
            if snapshot.locked == true, controller.model.role != .none { controller.model.roleLocked = true }
        }
        return opened.count
    }
}
