import Foundation

/// Copies and moves that write to the same place run one after another instead of fighting over the
/// disk (or the server connection). Operations for different places still run side by side.
/// Main thread only.
final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    /// What the status bar shows for an operation that is waiting its turn.
    struct Waiting: Identifiable {
        let id: UUID
        let detail: String
    }

    private struct Entry {
        let id: UUID
        let key: String
        let sources: [URL]
        let detail: String
        let onCancel: () -> Void
        let start: (@escaping () -> Void) -> Void
    }

    @Published private(set) var waiting: [Waiting] = []
    private var running: [String: Entry] = [:]
    private var pending: [Entry] = []

    /// The place an operation writes to: the volume of a local folder, or the server of a remote one.
    static func key(forDestination url: URL) -> String {
        if RemoteURL.isRemote(url) { return "server:" + (RemoteURL.sessionKey(of: url) ?? url.absoluteString) }
        let volume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        return "volume:" + (volume.map { "\($0)" } ?? url.standardizedFileURL.path)
    }

    /// Starts `start` now when nothing else writes to `key`, otherwise when the operations before it are done.
    /// `start` receives a closure it must call exactly once when the operation has ended.
    /// Returns true when it started at once. `onCancel` runs if the user removes it from the queue.
    @discardableResult
    func submit(key: String, sources: [URL], detail: String, onCancel: @escaping () -> Void = {},
                start: @escaping (@escaping () -> Void) -> Void) -> Bool {
        let entry = Entry(id: UUID(), key: key, sources: sources, detail: detail, onCancel: onCancel, start: start)
        if running[key] == nil {
            run(entry)
            return true
        }
        pending.append(entry)
        publish()
        return false
    }

    /// Removes a waiting operation (one that is running is cancelled with its own Cancel button).
    func cancelWaiting(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        publish()
        entry.onCancel()
    }

    /// True when `url` is, or lies inside, or contains something that a running or waiting operation reads.
    func isBusy(_ url: URL) -> Bool {
        let mine = ListerModel.comparisonKey(url)
        for entry in Array(running.values) + pending {
            for source in entry.sources {
                let other = ListerModel.comparisonKey(source)
                if mine == other || mine.hasPrefix(other + "/") || other.hasPrefix(mine + "/") { return true }
            }
        }
        return false
    }

    var isIdle: Bool { running.isEmpty && pending.isEmpty }

    // MARK: -

    private func run(_ entry: Entry) {
        running[entry.key] = entry
        var finished = false
        entry.start { [weak self] in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self?.finish(entry.key) }
        }
    }

    private func finish(_ key: String) {
        running[key] = nil
        if let index = pending.firstIndex(where: { $0.key == key }) {
            let next = pending.remove(at: index)
            publish()
            run(next)
        }
    }

    private func publish() { waiting = pending.map { Waiting(id: $0.id, detail: $0.detail) } }
}
