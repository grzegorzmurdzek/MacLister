import AppKit
import CoreServices

/// What Finder's sidebar holds: the Favorites, the Locations it shows and its Tags. It is read from the system's
/// shared file lists, the very lists Finder keeps them in, so a change made in Finder shows up here too.
/// (The lists are read through the old LSSharedFileList calls: they are deprecated, but they are the only way to ask
/// for the lists without Full Disk Access, because the .sfl3 files themselves are protected.)
struct FinderSidebar: Equatable {
    struct Favorite: Equatable {
        let name: String
        let url: URL
    }

    var favorites: [Favorite] = []
    /// Every tag Finder knows, its favourite tags first.
    var tags: [String] = []
    /// False when the lists could not be read: the sidebar then shows its defaults.
    var isKnown = false
    var showsStartupDisk = true
    var showsICloudDrive = true
    var showsComputer = true
    var showsAirDrop = true
    var showsTrash = true

    /// Finder keeps seven favourite tags (the ones in its sidebar); the others are under "All Tags…".
    static let favoriteTagCount = 7

    var favoriteTags: [String] { Array(tags.prefix(Self.favoriteTagCount)) }

    static let favoritesKey = "com.apple.LSSharedFileList.FavoriteItems"
    static let locationsKey = "com.apple.LSSharedFileList.FavoriteVolumes"
    static let tagsKey = "com.apple.LSSharedFileList.ProjectsItems"

    // MARK: Reading

    private struct Entry {
        let name: String
        let url: URL?
    }

    private static func entries(of key: String) -> [Entry]? {
        guard let list = LSSharedFileListCreate(nil, key as CFString, nil)?.takeRetainedValue() else { return nil }
        var seed: UInt32 = 0
        guard let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] else { return nil }
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return items.map { item in
            Entry(name: String(LSSharedFileListItemCopyDisplayName(item).takeRetainedValue()),
                  url: LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL?)
        }
    }

    static func read() -> FinderSidebar {
        var sidebar = FinderSidebar()
        let fm = FileManager.default
        if let list = entries(of: favoritesKey) {
            for entry in list {
                guard let url = entry.url, url.isFileURL else { continue }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let name = fm.displayName(atPath: url.path)
                sidebar.favorites.append(Favorite(name: name.isEmpty ? entry.name : name, url: url.standardizedFileURL))
            }
        }
        if let list = entries(of: tagsKey) {
            sidebar.tags = list.map(\.name).filter { !$0.isEmpty }
        }
        if let list = entries(of: locationsKey), !list.isEmpty {
            sidebar.isKnown = true
            sidebar.showsStartupDisk = false
            sidebar.showsICloudDrive = false
            sidebar.showsComputer = false
            sidebar.showsAirDrop = false
            sidebar.showsTrash = false
            for entry in list {
                guard let text = entry.url?.absoluteString else { continue }
                if text.contains("IsComputer") { sidebar.showsComputer = true }
                else if text.contains("icloud") { sidebar.showsICloudDrive = true }
                else if text.contains("AirDrop") { sidebar.showsAirDrop = true }
                else if text.hasSuffix("Trash") { sidebar.showsTrash = true }
                else if entry.url?.isFileURL == true, entry.url?.standardizedFileURL.path == "/" { sidebar.showsStartupDisk = true }
            }
        }
        return sidebar
    }
}

extension Notification.Name {
    static let finderSidebarChanged = Notification.Name("MacListerFinderSidebarChanged")
}

/// Keeps one copy of Finder's sidebar for all listers and tells them when Finder changes it: the system says so, and
/// whenever MacLister comes to the front again (in case the system does not).
final class FinderSidebarMonitor {
    static let shared = FinderSidebarMonitor()

    /// Tests put a fixed sidebar here.
    static var override: FinderSidebar?

    private(set) var current: FinderSidebar
    private var lists: [LSSharedFileList] = []
    private var activeObserver: NSObjectProtocol?

    private static let callback: LSSharedFileListChangedProcPtr = { _, context in
        let monitor = Unmanaged<FinderSidebarMonitor>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { monitor.refresh() }
    }

    private init() {
        current = FinderSidebarMonitor.override ?? FinderSidebar.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        for key in [FinderSidebar.favoritesKey, FinderSidebar.locationsKey, FinderSidebar.tagsKey] {
            guard let list = LSSharedFileListCreate(nil, key as CFString, nil)?.takeRetainedValue() else { continue }
            LSSharedFileListAddObserver(list, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, Self.callback, context)
            lists.append(list)
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Reads the lists again; listers hear about it only when something is different.
    func refresh() {
        let latest = Self.override ?? FinderSidebar.read()
        guard latest != current else { return }
        current = latest
        NotificationCenter.default.post(name: .finderSidebarChanged, object: nil)
    }
}
