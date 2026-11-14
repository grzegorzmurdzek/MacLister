import Foundation

/// Operations that need a walk through a server folder.
enum RemoteOps {
    /// Does `path` (a symbolic link, say) lead to a folder? Listing a plain file succeeds on SFTP, so the
    /// path is listed with a trailing slash, which only a folder accepts.
    static func isFolder(_ fs: RemoteFileSystem, path: String) -> Bool {
        (try? fs.list(path.hasSuffix("/") ? path : path + "/")) != nil
    }

    /// Deletes a file, or a folder with everything inside (servers have no Trash).
    static func deleteRecursively(_ fs: RemoteFileSystem, path: String, isDirectory: Bool, cancel: CancelToken?) throws {
        if cancel?.isCancelled == true { throw RemoteError.cancelled }
        if isDirectory {
            for entry in try fs.list(path) {
                // a symbolic link is removed as a file, never followed
                try deleteRecursively(fs, path: RemoteURL.join(path, entry.name), isDirectory: entry.isDirectory && !entry.isSymlink, cancel: cancel)
            }
        }
        try fs.remove(path, isDirectory: isDirectory)
    }

    /// "report.txt" → "report 2.txt" when "report.txt" is taken.
    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}

/// Copy or move between a local folder and a server (upload / download), or a move inside one server.
/// Like the local engine, folders are handled item by item, conflicts are answered one at a time by
/// `resolver`, and Cancel works between files and, through the process, inside a running transfer.
final class RemoteTransferJob {
    enum Direction { case upload, download, moveOnServer }

    let kind: TransferKind
    let direction: Direction
    let items: [URL]                  // local URLs (upload) or server URLs (download, move on server)
    let destination: URL              // server folder (upload, move on server) or local folder (download)
    let knownSizes: [URL: Int64]      // sizes of server items, from the listing the user sees

    var resolver: (TransferConflict) -> ConflictDecision = { _ in ConflictDecision(action: .keepBoth) }
    var onProgress: ((TransferProgress) -> Void)?
    let cancelToken = CancelToken()
    /// A move removes the local original, and Replace removes a local file, through the Trash. Tests turn it off.
    var trashesLocalFiles = true

    private let fm = FileManager.default
    private var result = TransferResult()
    private var progress = TransferProgress()
    private var lastReport = Date.distantPast
    let gate = PauseGate()
    private let live = LiveBytes()
    private let snapshotLock = NSLock()
    private var lastSnapshot = TransferProgress()
    private var listings: [String: [String: RemoteEntry]] = [:]   // server folder → entries by name

    init(kind: TransferKind, direction: Direction, items: [URL], destination: URL, knownSizes: [URL: Int64] = [:]) {
        self.kind = kind
        self.direction = direction
        self.items = items
        self.destination = destination
        self.knownSizes = knownSizes
    }

    func cancel() { cancelToken.cancel(); gate.resume() }
    private var isCancelled: Bool { cancelToken.isCancelled }

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

        guard let session = RemoteSessions.shared.session(for: direction == .download ? items.first ?? destination : destination) else {
            result.failures.append(tr("Not connected to the server"))
            return result
        }
        let fs = session.fs

        switch direction {
        case .upload:
            progress.bytesTotal = items.reduce(0) { $0 + FolderSize.total(of: $1) }
        case .download:
            progress.bytesTotal = items.allSatisfy({ knownSizes[$0] != nil }) ? items.reduce(0) { $0 + (knownSizes[$1] ?? 0) } : 0
        case .moveOnServer:
            progress.bytesTotal = 0
        }

        for (index, item) in items.enumerated() {
            if isCancelled { break }
            progress.current = item.lastPathComponent
            switch direction {
            case .upload:
                uploadNode(item, fs: fs, intoDirectory: RemoteURL.path(of: destination), topLevel: true)
            case .download:
                downloadNode(item, fs: fs, intoDirectory: destination, topLevel: true)
            case .moveOnServer:
                moveNode(item, fs: fs, intoDirectory: RemoteURL.path(of: destination), topLevel: true)
            }
            progress.itemsDone = index + 1
            report(force: true)
        }
        result.cancelled = isCancelled
        return result
    }

    // MARK: Server listings

    private func entries(_ path: String, _ fs: RemoteFileSystem) -> [String: RemoteEntry] {
        if let cached = listings[path] { return cached }
        let found = (try? fs.list(path)) ?? []
        let table = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        listings[path] = table
        return table
    }

    private func forget(_ path: String) { listings[path] = nil }

    private func fail(_ name: String, _ error: Error) {
        if (error as? RemoteError)?.message == RemoteError.cancelled.message { return }
        result.failures.append("\(name): \(error.localizedDescription)")
    }

    // MARK: Upload

    @discardableResult
    private func uploadNode(_ source: URL, fs: RemoteFileSystem, intoDirectory directory: String, topLevel: Bool) -> Bool {
        gate.waitWhilePaused { isCancelled }
        if isCancelled { return false }
        var name = source.lastPathComponent
        let info = LocalInfo(source)
        let size = info.isDirectory ? FolderSize.total(of: source) : info.size
        var merging = false

        let existing = entries(directory, fs)
        if let current = existing[name] {
            let conflict = TransferConflict(
                source: source, target: RemoteURL.child(of: RemoteURL.with(path: directory, on: destination), named: name),
                sourceIsDirectory: info.isDirectory, targetIsDirectory: current.isDirectory,
                sourceModified: info.modified, targetModified: current.modified,
                sourceSize: info.isDirectory ? nil : info.size, targetSize: current.size)
            switch resolver(conflict).action {
            case .cancel:
                cancelToken.cancel()
                return false
            case .skip:
                result.skipped += 1; advance(size)
                return false
            case .keepBoth:
                name = RemoteOps.uniqueName(name, existing: Set(existing.keys))
            case .replace:
                if !removeExisting(current, at: RemoteURL.join(directory, name), fs: fs, sourceIsDirectory: info.isDirectory) { return false }
            case .replaceIfNewer:
                if conflict.bothDirectories { merging = true }
                else if Self.isNewer(info.modified, than: current.modified) {
                    if !removeExisting(current, at: RemoteURL.join(directory, name), fs: fs, sourceIsDirectory: info.isDirectory) { return false }
                } else {
                    result.skipped += 1; advance(size)
                    return false
                }
            case .merge:
                if conflict.bothDirectories { merging = true } else { result.skipped += 1; advance(size); return false }
            }
        }

        let target = RemoteURL.join(directory, name)
        do {
            if info.isDirectory {
                if !merging { try fs.makeDirectory(target); forget(directory) }
                var complete = true
                var children: [URL] = []
                do {
                    children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
                } catch {
                    // An unreadable folder is not an empty one: never report it as moved, never remove it.
                    fail(source.lastPathComponent, error)
                    complete = false
                }
                for child in children {
                    if isCancelled { complete = false; break }
                    if !uploadNode(child, fs: fs, intoDirectory: target, topLevel: false) { complete = false }
                }
                if complete, kind == .move { removeLocal(source) }
                if topLevel { result.done.append(RemoteURL.child(of: destination, named: name)) }
                return complete
            }
            progress.current = name
            report(force: false)
            try fs.upload(source, to: target, cancel: cancelToken)
            forget(directory)
            advance(size)
            if kind == .move { removeLocal(source) }
            if topLevel { result.done.append(RemoteURL.child(of: destination, named: name)) }
            return true
        } catch {
            fail(source.lastPathComponent, error)
            return false
        }
    }

    /// Replace: a file is simply overwritten by the upload; a folder, or a type mismatch, is removed first.
    private func removeExisting(_ entry: RemoteEntry, at path: String, fs: RemoteFileSystem, sourceIsDirectory: Bool) -> Bool {
        if !entry.isDirectory, !sourceIsDirectory { return true }
        do {
            try RemoteOps.deleteRecursively(fs, path: path, isDirectory: entry.isDirectory && !entry.isSymlink, cancel: cancelToken)
            forget(RemoteURL.parentPath(of: path))
            return true
        } catch {
            fail(entry.name, error)
            return false
        }
    }

    // MARK: Download

    @discardableResult
    private func downloadNode(_ source: URL, fs: RemoteFileSystem, intoDirectory directory: URL, topLevel: Bool) -> Bool {
        gate.waitWhilePaused { isCancelled }
        if isCancelled { return false }
        let path = RemoteURL.path(of: source)
        let name = (path as NSString).lastPathComponent
        let parent = RemoteURL.parentPath(of: path)
        guard let entry = entries(parent, fs)[name] else {
            result.failures.append("\(name): " + tr("not found on the server"))
            return false
        }
        let size = entry.size ?? 0
        var target = directory.appendingPathComponent(name)
        var merging = false

        if fm.fileExists(atPath: target.path) || (try? fm.attributesOfItem(atPath: target.path)) != nil {
            let info = LocalInfo(target)
            let conflict = TransferConflict(
                source: source, target: target,
                sourceIsDirectory: entry.isDirectory, targetIsDirectory: info.isDirectory,
                sourceModified: entry.modified, targetModified: info.modified,
                sourceSize: entry.isDirectory ? nil : entry.size, targetSize: info.isDirectory ? nil : info.size)
            switch resolver(conflict).action {
            case .cancel:
                cancelToken.cancel()
                return false
            case .skip:
                result.skipped += 1; advance(size)
                return false
            case .keepBoth:
                target = FileTransfer.uniqueURL(for: target)
            case .replace:
                guard trash(target, name) else { return false }
            case .replaceIfNewer:
                if conflict.bothDirectories { merging = true }
                else if Self.isNewer(entry.modified, than: info.modified) { guard trash(target, name) else { return false } }
                else { result.skipped += 1; advance(size); return false }
            case .merge:
                if conflict.bothDirectories { merging = true } else { result.skipped += 1; advance(size); return false }
            }
        }

        do {
            if entry.isDirectory && !entry.isSymlink {
                if !merging { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
                var complete = true
                for child in try fs.list(path) {
                    if isCancelled { complete = false; break }
                    let childURL = RemoteURL.child(of: source, named: child.name)
                    if !downloadNode(childURL, fs: fs, intoDirectory: target, topLevel: false) { complete = false }
                }
                if complete, kind == .move { try? fs.remove(path, isDirectory: true); forget(parent) }
                if topLevel { result.done.append(target) }
                return complete
            }
            progress.current = name
            report(force: false)
            try downloadWatched(fs, path: path, to: target, size: size)
            advance(size)
            if let modified = entry.modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
            if kind == .move { try fs.remove(path, isDirectory: false); forget(parent) }
            if topLevel { result.done.append(target) }
            return true
        } catch {
            fail(name, error)
            return false
        }
    }

    private func trash(_ url: URL, _ name: String) -> Bool {
        do {
            if trashesLocalFiles { try fm.trashItem(at: url, resultingItemURL: nil) } else { try fm.removeItem(at: url) }
            return true
        } catch { fail(name, error); return false }
    }

    private func removeLocal(_ url: URL) {
        if trashesLocalFiles { try? fm.trashItem(at: url, resultingItemURL: nil) } else { try? fm.removeItem(at: url) }
    }

    // MARK: Move inside one server

    @discardableResult
    private func moveNode(_ source: URL, fs: RemoteFileSystem, intoDirectory directory: String, topLevel: Bool) -> Bool {
        gate.waitWhilePaused { isCancelled }
        if isCancelled { return false }
        let path = RemoteURL.path(of: source)
        let name = (path as NSString).lastPathComponent
        let parent = RemoteURL.parentPath(of: path)
        var newName = name

        if parent == directory { result.skipped += 1; return false }
        if directory == path || directory.hasPrefix(path + "/") {
            result.failures.append("\(name): " + tr("cannot move a folder into itself"))
            return false
        }
        let sourceEntry = entries(parent, fs)[name]
        let existing = entries(directory, fs)
        var merging = false
        if let current = existing[name] {
            let conflict = TransferConflict(
                source: source, target: RemoteURL.child(of: RemoteURL.with(path: directory, on: destination), named: name),
                sourceIsDirectory: sourceEntry?.isDirectory ?? false, targetIsDirectory: current.isDirectory,
                sourceModified: sourceEntry?.modified, targetModified: current.modified,
                sourceSize: sourceEntry?.size, targetSize: current.size)
            switch resolver(conflict).action {
            case .cancel: cancelToken.cancel(); return false
            case .skip: result.skipped += 1; return false
            case .keepBoth: newName = RemoteOps.uniqueName(name, existing: Set(existing.keys))
            case .replace:
                do {
                    try RemoteOps.deleteRecursively(fs, path: RemoteURL.join(directory, name), isDirectory: current.isDirectory && !current.isSymlink, cancel: cancelToken)
                    forget(directory)
                } catch { fail(name, error); return false }
            case .replaceIfNewer:
                if conflict.bothDirectories { merging = true }
                else if Self.isNewer(sourceEntry?.modified, than: current.modified) {
                    do { try fs.remove(RemoteURL.join(directory, name), isDirectory: false); forget(directory) } catch { fail(name, error); return false }
                } else { result.skipped += 1; return false }
            case .merge:
                if conflict.bothDirectories { merging = true } else { result.skipped += 1; return false }
            }
        }

        let target = RemoteURL.join(directory, newName)
        do {
            if merging {
                var complete = true
                for child in try fs.list(path) {
                    if isCancelled { complete = false; break }
                    if !moveNode(RemoteURL.child(of: source, named: child.name), fs: fs, intoDirectory: target, topLevel: false) { complete = false }
                }
                if complete { try? fs.remove(path, isDirectory: true) }
                forget(parent)
                if topLevel { result.done.append(RemoteURL.child(of: destination, named: newName)) }
                return complete
            }
            try fs.rename(path, to: target)
            forget(parent); forget(directory)
            if topLevel { result.done.append(RemoteURL.child(of: destination, named: newName)) }
            return true
        } catch {
            fail(name, error)
            return false
        }
    }

    // MARK: Progress

    private func advance(_ bytes: Int64) {
        progress.bytesDone += bytes
        report(force: false)
    }

    /// A download writes the local file as it goes, so its growth shows the speed (uploads cannot be watched).
    private func downloadWatched(_ fs: RemoteFileSystem, path: String, to target: URL, size: Int64) throws {
        guard size >= 1_000_000, onProgress != nil else { try fs.download(path, to: target, cancel: cancelToken); return }
        let watcher = GrowthWatcher(url: target) { [weak self] written in self?.reportLive(min(written, size)) }
        defer {
            watcher.stop()
            live.set(0)
        }
        try fs.download(path, to: target, cancel: cancelToken)
    }

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

    private static func isNewer(_ a: Date?, than b: Date?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        return a > b.addingTimeInterval(2)
    }

    private struct LocalInfo {
        var isDirectory = false
        var size: Int64 = 0
        var modified: Date?

        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            isDirectory = (values?.isDirectory ?? false) && values?.isSymbolicLink != true
            size = Int64(values?.fileSize ?? 0)
            modified = values?.contentModificationDate
        }
    }
}
