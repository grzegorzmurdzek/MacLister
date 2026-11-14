import Foundation

// MARK: - Conflicts

enum ConflictAction: Equatable {
    case replace          // the existing item goes to the Trash first
    case replaceIfNewer   // replace only when the source is newer; otherwise skip
    case keepBoth         // the new item gets "name 2.ext"
    case skip
    case merge            // folder onto folder: go inside and resolve the items one by one
    case cancel           // stop the whole operation
}

struct ConflictDecision {
    var action: ConflictAction
    var applyToAll = false
}

struct TransferConflict {
    let source: URL
    let target: URL
    let sourceIsDirectory: Bool
    let targetIsDirectory: Bool
    let sourceModified: Date?
    let targetModified: Date?
    let sourceSize: Int64?
    let targetSize: Int64?

    var bothDirectories: Bool { sourceIsDirectory && targetIsDirectory }
    var bothFiles: Bool { !sourceIsDirectory && !targetIsDirectory }
}

enum ConflictRules {
    /// Can an "apply to all" answer given earlier also answer this conflict?
    static func canReuse(_ action: ConflictAction, for conflict: TransferConflict) -> Bool {
        switch action {
        case .merge: return conflict.bothDirectories
        case .replaceIfNewer: return conflict.bothDirectories || conflict.bothFiles
        default: return true
        }
    }
}

/// Remembers an "apply to all remaining conflicts" answer for the duration of one operation.
final class ConflictMemory {
    var action: ConflictAction?
}

// MARK: - Progress

struct TransferProgress {
    var itemsDone = 0
    var itemsTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var current = ""
    /// Bytes of the file being copied right now that are already written (finished files are in bytesDone).
    var inFlight: Int64 = 0

    var effectiveBytes: Int64 { bytesDone + inFlight }

    var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(effectiveBytes) / Double(bytesTotal)) }
        return itemsTotal > 0 ? Double(itemsDone) / Double(itemsTotal) : 0
    }
}

// MARK: - Job

/// One copy or move. Folders are processed file by file, so progress is smooth and Cancel takes effect
/// between files. A move on the same volume is a plain rename. Conflicts are resolved one at a time by
/// `resolver` (called on the worker thread; it may block while the user decides).
final class TransferJob {
    let kind: TransferKind
    let items: [URL]
    let destination: URL

    var resolver: (TransferConflict) -> ConflictDecision = { _ in ConflictDecision(action: .keepBoth) }
    /// Delivered on the main queue, at most about ten times a second.
    var onProgress: ((TransferProgress) -> Void)?

    private let lock = NSLock()
    private var cancelFlag = false
    private let fm = FileManager.default
    private var result = TransferResult()
    private var progress = TransferProgress()
    private var lastReport = Date.distantPast
    let gate = PauseGate()
    private let live = LiveBytes()
    private let snapshotLock = NSLock()
    private var lastSnapshot = TransferProgress()

    init(kind: TransferKind, items: [URL], destination: URL) {
        self.kind = kind
        self.items = items
        self.destination = destination
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }
    func cancel() { lock.lock(); cancelFlag = true; lock.unlock(); gate.resume() }

    /// Runs on a background queue; `completion` is called on the main queue.
    func start(completion: @escaping (TransferResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finished = self.runSync()
            DispatchQueue.main.async { completion(finished) }
        }
    }

    func runSync() -> TransferResult {
        result = TransferResult()
        progress = TransferProgress(itemsTotal: items.count)
        progress.current = tr("Preparing…")
        report(force: true)

        var sizes: [URL: Int64] = [:]
        for item in items {
            sizes[item] = FolderSize.total(of: item)
            progress.bytesTotal += sizes[item] ?? 0
        }

        for (index, item) in items.enumerated() {
            if isCancelled { break }
            progress.current = item.lastPathComponent
            transferNode(item, into: destination, topLevel: true, knownSize: sizes[item])
            progress.itemsDone = index + 1
            report(force: true)
        }
        result.cancelled = isCancelled
        return result
    }

    // MARK: Core

    /// Transfers one file or folder into `directory`. Returns true when everything arrived.
    @discardableResult
    private func transferNode(_ source: URL, into directory: URL, topLevel: Bool, knownSize: Int64? = nil) -> Bool {
        gate.waitWhilePaused { isCancelled }
        if isCancelled { return false }
        var target = directory.appendingPathComponent(source.lastPathComponent)
        let sourceInfo = Self.info(of: source)
        let size = knownSize ?? (sourceInfo.isDirectory ? FolderSize.total(of: source) : sourceInfo.size)

        if Self.samePath(source, target) {
            result.skipped += 1
            advance(size)
            return false
        }
        if Self.isInside(directory, of: source) {
            result.failures.append("\(source.lastPathComponent): " + (kind == .copy ? tr("cannot copy a folder into itself") : tr("cannot move a folder into itself")))
            return false
        }

        var merging = false
        var replaced: URL?
        if Self.exists(target) {
            let existing = Self.info(of: target)
            let conflict = TransferConflict(
                source: source, target: target,
                sourceIsDirectory: sourceInfo.isDirectory, targetIsDirectory: existing.isDirectory,
                sourceModified: sourceInfo.modified, targetModified: existing.modified,
                sourceSize: sourceInfo.isDirectory ? nil : sourceInfo.size,
                targetSize: existing.isDirectory ? nil : existing.size
            )
            let decision = resolver(conflict)
            switch decision.action {
            case .cancel:
                cancel()
                return false
            case .skip:
                result.skipped += 1
                advance(size)
                return false
            case .keepBoth:
                target = FileTransfer.uniqueURL(for: target)
            case .replace:
                guard let gone = trash(target, named: source.lastPathComponent) else { return false }
                replaced = gone.url
            case .replaceIfNewer:
                if conflict.bothDirectories {
                    merging = true
                } else if Self.isNewer(sourceInfo.modified, than: existing.modified) {
                    guard let gone = trash(target, named: source.lastPathComponent) else { return false }
                    replaced = gone.url
                } else {
                    result.skipped += 1
                    advance(size)
                    return false
                }
            case .merge:
                if conflict.bothDirectories {
                    merging = true
                } else {
                    result.skipped += 1
                    advance(size)
                    return false
                }
            }
        }

        if sourceInfo.isDirectory {
            let complete = transferFolder(source, to: target, into: directory, merging: merging, topLevel: topLevel, size: size)
            if topLevel, Self.exists(target) {
                result.pairs.append(TransferPair(source: source, target: target, replaced: replaced, undoable: complete && !merging))
            }
            return complete
        }
        do {
            progress.current = source.lastPathComponent
            if kind == .move {
                if Self.sameVolume(source, directory) {
                    try fm.moveItem(at: source, to: target)
                } else {
                    try copyWatched(source, to: target, size: size)
                    try fm.removeItem(at: source)
                }
            } else {
                try copyWatched(source, to: target, size: size)
            }
            if topLevel {
                result.done.append(target)
                result.pairs.append(TransferPair(source: source, target: target, replaced: replaced))
            }
            advance(size)
            return true
        } catch {
            result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func transferFolder(_ source: URL, to target: URL, into directory: URL, merging: Bool,
                                topLevel: Bool, size: Int64) -> Bool {
        // Same volume, nothing in the way: one atomic rename.
        if kind == .move, !merging, !Self.exists(target), Self.sameVolume(source, directory) {
            do {
                try fm.moveItem(at: source, to: target)
                if topLevel { result.done.append(target) }
                advance(size)
                return true
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }

        do {
            if !merging { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        } catch {
            result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        var complete = true
        var children: [URL] = []
        do {
            children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
        } catch {
            // An unreadable folder is not an empty one: never report it as moved, never remove it.
            result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            complete = false
        }
        for child in children {
            if isCancelled { complete = false; break }
            if !transferNode(child, into: target, topLevel: false) { complete = false }
        }
        if !merging {   // keep the folder's own dates and permissions
            let attributes = (try? fm.attributesOfItem(atPath: source.path)) ?? [:]
            var wanted: [FileAttributeKey: Any] = [:]
            if let date = attributes[.modificationDate] { wanted[.modificationDate] = date }
            if let mode = attributes[.posixPermissions] { wanted[.posixPermissions] = mode }
            try? fm.setAttributes(wanted, ofItemAtPath: target.path)
        }
        if complete, kind == .move { try? fm.removeItem(at: source) }   // only when nothing was left behind
        if topLevel { result.done.append(target) }
        return complete
    }

    // MARK: Helpers

    struct Trashed { let url: URL? }

    /// Moves an existing item to the Trash; the result holds where it landed (nil: the job failed).
    private func trash(_ url: URL, named name: String) -> Trashed? {
        do {
            var landed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &landed)
            return Trashed(url: landed as URL?)
        } catch {
            result.failures.append("\(name): \(error.localizedDescription)")
            return nil
        }
    }

    private func advance(_ bytes: Int64) {
        progress.bytesDone += bytes
        report(force: false)
    }

    /// Copies one file; a big one is watched while it grows so progress and speed move smoothly.
    private func copyWatched(_ source: URL, to target: URL, size: Int64) throws {
        guard size >= 4_000_000, onProgress != nil else { try fm.copyItem(at: source, to: target); return }
        let watcher = GrowthWatcher(url: target) { [weak self] written in self?.reportLive(min(written, size)) }
        defer {
            watcher.stop()
            live.set(0)
        }
        try fm.copyItem(at: source, to: target)
    }

    /// Called from the poller's queue: the last snapshot, with the bytes written so far.
    private func reportLive(_ written: Int64) {
        live.set(written)
        guard let onProgress else { return }
        snapshotLock.lock()
        var snapshot = lastSnapshot
        snapshotLock.unlock()
        snapshot.inFlight = written
        DispatchQueue.main.async { onProgress(snapshot) }
    }

    private func report(force: Bool) {
        guard let onProgress else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return }
        lastReport = now
        var snapshot = progress
        snapshot.inFlight = live.current
        snapshotLock.lock()
        lastSnapshot = snapshot
        snapshotLock.unlock()
        DispatchQueue.main.async { onProgress(snapshot) }
    }

    private struct Info {
        var isDirectory = false
        var size: Int64 = 0
        var modified: Date?
    }

    private static func info(of url: URL) -> Info {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        var info = Info()
        // a symbolic link is copied as a link, never followed
        info.isDirectory = (values?.isDirectory ?? false) && values?.isSymbolicLink != true
        info.size = Int64(values?.fileSize ?? 0)
        info.modified = values?.contentModificationDate
        return info
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil   // also true for a dangling link
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    private static func isInside(_ directory: URL, of folder: URL) -> Bool {
        let d = directory.standardizedFileURL.path
        let f = folder.standardizedFileURL.path
        return d == f || d.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    private static func isNewer(_ a: Date?, than b: Date?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        return a > b.addingTimeInterval(2)      // 2 s tolerance for coarse file system clocks
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func id(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x.isEqual(y)
    }
}
