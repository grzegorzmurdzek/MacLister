import Foundation

/// Which way a folder is shown, icons or list, remembered for each folder the user chose it in (as Finder does).
/// Folders without an entry use the way the user last chose (Settings.showAsIcons). Only real, local folders take
/// part: lists (Recents, Shared, Devices), servers and archives keep the view that is on.
final class ViewModeStore {
    static let shared = ViewModeStore()

    struct Entry: Codable, Equatable {
        var icons: Bool
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

    func contains(_ url: URL) -> Bool { mode(for: url) != nil }

    func set(_ icons: Bool, for url: URL) {
        guard Self.isRemembered(url) else { return }
        entries[Self.key(for: url)] = Entry(icons: icons, chosen: Date().timeIntervalSince1970)
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
