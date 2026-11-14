import AppKit
import CryptoKit

/// Browsing an archive like a folder: the archive is unpacked once into a cache folder, and the lister shows that
/// folder as if it were the archive (read-only). The path bar, the title and Back/Parent know the real archive.
final class ArchiveBrowser {
    static let shared = ArchiveBrowser()

    /// Where the unpacked archives live (tests use another folder).
    static var cacheDirectory: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacLister", isDirectory: true).appendingPathComponent("Archives", isDirectory: true)
    }()

    /// Where a folder shown in a lister really is: inside `archive`, `inner` components below its root.
    struct Location: Equatable {
        let archive: URL
        let root: URL
        let inner: [String]
    }

    private var mounts: [String: URL] = [:]            // path of the unpacked folder → the archive
    private let lock = NSLock()

    /// The archive a cache folder belongs to, or nil for any ordinary folder.
    func location(of url: URL) -> Location? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard let (rootPath, archive) = mounts.filter({ path == $0.key || path.hasPrefix($0.key + "/") }).max(by: { $0.key.count < $1.key.count }) else { return nil }
        let inner = path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
        return Location(archive: archive, root: URL(fileURLWithPath: rootPath, isDirectory: true), inner: inner)
    }

    func register(root: URL, archive: URL) {
        lock.lock()
        mounts[root.standardizedFileURL.path] = archive
        lock.unlock()
    }

    /// The same archive (same place, size and date) always gets the same cache folder.
    static func key(for archive: URL) -> String {
        let values = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(archive.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    struct OpenError: Error { let message: String }

    /// Unpacks the archive (unless it already is) and reports the folder that stands for it; main queue.
    func open(_ archive: URL, completion: @escaping (Result<URL, OpenError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let directory = Self.cacheDirectory
            let root = directory.appendingPathComponent(Self.key(for: archive), isDirectory: true)
            if !fm.fileExists(atPath: root.path) {
                let partial = directory.appendingPathComponent(Self.key(for: archive) + ".partial", isDirectory: true)
                try? fm.removeItem(at: partial)
                do { try fm.createDirectory(at: partial, withIntermediateDirectories: true) }
                catch {
                    DispatchQueue.main.async { completion(.failure(OpenError(message: error.localizedDescription))) }
                    return
                }
                if let problem = ArchiveExtractor.extractContents(of: archive, to: partial) {
                    try? fm.removeItem(at: partial)
                    DispatchQueue.main.async { completion(.failure(OpenError(message: problem))) }
                    return
                }
                do { try fm.moveItem(at: partial, to: root) }
                catch {
                    try? fm.removeItem(at: partial)
                    DispatchQueue.main.async { completion(.failure(OpenError(message: error.localizedDescription))) }
                    return
                }
            }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: root.path)     // in use: not old
            DispatchQueue.main.async {
                self.register(root: root, archive: archive)
                completion(.success(root))
            }
        }
    }

    /// Removes unpacked archives nobody has opened for a while (called when the app starts).
    static func cleanOldCaches(olderThan seconds: TimeInterval = 2 * 86_400) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(date) > seconds { try? fm.removeItem(at: entry) }
        }
    }
}

extension ListerModel {
    var archiveLocation: ArchiveBrowser.Location? { ArchiveBrowser.shared.location(of: url) }
    var isInArchive: Bool { archiveLocation != nil }
}

extension ListerViewController {
    /// Folder commands that would change the archive's contents are refused: it is a read-only view.
    func refuseInArchive(_ what: String) -> Bool {
        guard model.isInArchive else { return false }
        flash(tr("“%@” is not available inside an archive: it is read-only. Copy the files out first.", what))
        return true
    }

    /// Copying out of an archive is fine; moving out of it, or anything into it, is not.
    func archiveBlocksTransfer(_ kind: TransferKind, items: [URL], destination: URL) -> Bool {
        if ArchiveBrowser.shared.location(of: destination) != nil {
            flash(tr("Nothing can be copied or moved into an archive: it is read-only"))
            return true
        }
        if kind == .move, items.contains(where: { ArchiveBrowser.shared.location(of: $0) != nil }) {
            flash(tr("Files cannot be moved out of an archive: copy them instead"))
            return true
        }
        return false
    }

    /// Double-click on an archive: unpack it in the background and show it as a folder.
    func browseArchive(_ archive: URL) {
        model.statusMessage = tr("Reading “%@”…", archive.lastPathComponent)
        ArchiveBrowser.shared.open(archive) { [weak self] result in
            guard let self else { return }
            self.model.statusMessage = nil
            switch result {
            case .success(let root): self.model.navigate(to: root)
            case .failure(let error): self.model.errorMessage = "\(archive.lastPathComponent): \(error.message)"
            }
        }
    }
}
