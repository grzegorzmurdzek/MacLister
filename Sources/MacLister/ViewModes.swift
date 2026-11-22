import Foundation

/// Which way a folder is shown, icons or list, and what its files are grouped by, remembered for each folder the user
/// chose it in (as Finder does). Folders without an entry use the way the user last chose (Settings.showAsIcons) and
/// are not grouped. Only real, local folders take part: lists (Recents, Shared, Devices), servers and archives keep
/// the view that is on.
final class ViewModeStore {
    static let shared = ViewModeStore()

    struct Entry: Codable, Equatable {
        /// nil: the folder has a grouping only.
        var icons: Bool?
        /// A GroupKey's raw value; nil: not grouped.
        var group: String?
        /// When it was chosen, so the oldest entries go first once there are too many.
        var chosen: Double
    }

    /// The most folders remembered.
    static let limit = 2000

    private(set) var entries: [String: Entry] = [:]
    private var file: URL { AppSupport.directory.appendingPathComponent("viewmodes.json") }

    private init() { load() }

    static func key(for url: URL) -> String { ListerModel.comparisonKey(url) }

    /// Can the view of this location be remembered?
    static func isRemembered(_ url: URL) -> Bool {
        url.isFileURL && VirtualPlace.place(for: url) == nil && ArchiveBrowser.shared.location(of: url) == nil
    }

    func mode(for url: URL) -> Bool? {
        guard Self.isRemembered(url) else { return nil }
        return entries[Self.key(for: url)]?.icons
    }

    /// What the folder's files are grouped by, nil when the user did not group them.
    func group(for url: URL) -> GroupKey? {
        guard Self.isRemembered(url), let raw = entries[Self.key(for: url)]?.group else { return nil }
        return GroupKey(rawValue: raw).flatMap { $0 == .none ? nil : $0 }
    }

    func contains(_ url: URL) -> Bool { Self.isRemembered(url) && entries[Self.key(for: url)] != nil }

    func set(_ icons: Bool, for url: URL) {
        guard Self.isRemembered(url) else { return }
        update(url) { $0.icons = icons }
    }

    /// Remembers how the folder is grouped (`.none` forgets the grouping).
    func setGroup(_ key: GroupKey, for url: URL) {
        guard Self.isRemembered(url) else { return }
        update(url) { $0.group = key == .none ? nil : key.rawValue }
    }

    private func update(_ url: URL, _ change: (inout Entry) -> Void) {
        let key = Self.key(for: url)
        var entry = entries[key] ?? Entry(icons: nil, group: nil, chosen: 0)
        change(&entry)
        entry.chosen = Date().timeIntervalSince1970
        entries[key] = entry.icons == nil && entry.group == nil ? nil : entry
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.chosen < $1.value.chosen }.prefix(entries.count - Self.limit)
            for (key, _) in oldest { entries[key] = nil }
        }
        save()
    }

    func remove(_ url: URL) {
        guard entries[Self.key(for: url)] != nil else { return }
        entries[Self.key(for: url)] = nil
        save()
    }

    /// Re-reads the file (tests switch the support folder).
    func reload() { load() }

    private func load() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
