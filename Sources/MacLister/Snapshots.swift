import AppKit

/// Snapshot (Directory Opus): what a lister looked like for one folder: window size and position, sort order.
/// Entering the folder brings the sort order back, a lister opened on it gets the size (and, when it opens
/// beside another lister, the position).
struct FolderSnapshot: Codable, Equatable {
    var width: Double
    var height: Double
    var x: Double?
    var y: Double?
    var sort: String
    var ascending: Bool
}

final class SnapshotStore {
    static let shared = SnapshotStore()

    private(set) var snapshots: [String: FolderSnapshot] = [:]
    private var file: URL { AppSupport.directory.appendingPathComponent("snapshots.json") }

    private init() { load() }

    static func key(for url: URL) -> String { ListerModel.comparisonKey(url) }

    func snapshot(for url: URL) -> FolderSnapshot? {
        guard url.isFileURL else { return nil }
        return snapshots[Self.key(for: url)]
    }

    func contains(_ url: URL) -> Bool { snapshot(for: url) != nil }

    func set(_ snapshot: FolderSnapshot, for url: URL) {
        guard url.isFileURL else { return }
        snapshots[Self.key(for: url)] = snapshot
        save()
    }

    func remove(_ url: URL) {
        snapshots[Self.key(for: url)] = nil
        save()
    }

    /// Re-reads the file (tests switch the support folder).
    func reload() { load() }

    private func load() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: FolderSnapshot].self, from: data) {
            snapshots = saved
        } else {
            snapshots = [:]
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

extension ListerViewController {
    /// Remembers this lister's window size and position and the sort order for the folder it shows.
    func snapshotFolder() {
        if remoteUnavailable(tr("Snapshot")) { return }
        if refuseInList(tr("Snapshot")) { return }
        if refuseInArchive(tr("Snapshot")) { return }
        guard let window = view.window else { return }
        let size = window.contentLayoutRect.size
        let snapshot = FolderSnapshot(width: size.width, height: size.height, x: window.frame.origin.x, y: window.frame.origin.y,
                                      sort: model.sortKey.rawValue, ascending: model.ascending)
        SnapshotStore.shared.set(snapshot, for: model.url)
        flash(tr("Snapshot saved for “%@”: window size and position, sort order", model.displayName))
    }

    func forgetSnapshot() {
        guard SnapshotStore.shared.contains(model.url) else { return }
        SnapshotStore.shared.remove(model.url)
        flash(tr("Snapshot of “%@” removed", model.displayName))
    }

    var hasSnapshot: Bool { !model.isVirtual && SnapshotStore.shared.contains(model.url) }
}
