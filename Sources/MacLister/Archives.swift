import AppKit
import CryptoKit

/// What is inside an archive: every file and folder with its size and date, and who is whose child.
struct ArchiveIndex {
    private(set) var entries: [String: ArchiveReader.Entry] = [:]
    private(set) var children: [String: [String]] = [:]          // parent path ("" is the top) → paths of its children

    init(_ list: [ArchiveReader.Entry]) {
        for item in list { entries[item.path] = item }
        for path in Array(entries.keys) {                           // a folder that has no entry of its own is made up
            var parent = Self.parent(of: path)
            while !parent.isEmpty, entries[parent] == nil {
                entries[parent] = ArchiveReader.Entry(path: parent, size: 0, modified: nil, isDirectory: true, mode: 0o755, encrypted: false)
                parent = Self.parent(of: parent)
            }
        }
        for path in entries.keys { children[Self.parent(of: path), default: []].append(path) }
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The files at and below `path`, folders left out.
    func files(under path: String) -> [ArchiveReader.Entry] {
        if path.isEmpty { return (children[""] ?? []).flatMap { files(under: $0) } }          // the top of the archive
        guard let entry = entries[path] else { return [] }
        if !entry.isDirectory { return [entry] }
        return (children[path] ?? []).flatMap { files(under: $0) }
    }

    var hasEncryptedFiles: Bool { entries.values.contains { $0.encrypted } }
}

/// Browsing an archive like a folder, without unpacking it (like XAD on the Amiga). The list of what is inside is read
/// once; the lister shows it through a cache folder in which every file is first only a placeholder of the right size and
/// date. A file is taken out of the archive when it is really needed (opened, previewed, copied). Archives
/// libarchive cannot read are still unpacked completely, as before.
final class ArchiveBrowser {
    static let shared = ArchiveBrowser()

    /// Where the archives are shown (tests use another folder).
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

    final class Mount {
        let archive: URL
        let root: URL
        let index: ArchiveIndex?                    // nil: the archive was unpacked completely
        var passphrase: String?
        let queue = DispatchQueue(label: "maclister.archive", qos: .userInitiated)
        init(archive: URL, root: URL, index: ArchiveIndex?, passphrase: String?) {
            self.archive = archive; self.root = root; self.index = index; self.passphrase = passphrase
        }
    }

    private var mounts: [String: Mount] = [:]           // path of the folder that stands for the archive → the mount
    private let lock = NSLock()
    private static let placeholderMark = "com.maclister.placeholder"

    // MARK: Where is this?

    private func mount(for url: URL) -> (mount: Mount, inner: [String])? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard let best = mounts.filter({ path == $0.key || path.hasPrefix($0.key + "/") }).max(by: { $0.key.count < $1.key.count }) else { return nil }
        return (best.value, path.dropFirst(best.key.count).split(separator: "/").map(String.init))
    }

    /// The archive a cache folder belongs to, or nil for any ordinary folder.
    func location(of url: URL) -> Location? {
        guard let (mount, inner) = mount(for: url) else { return nil }
        return Location(archive: mount.archive, root: mount.root, inner: inner)
    }

    func register(root: URL, archive: URL, index: ArchiveIndex? = nil, passphrase: String? = nil) {
        lock.lock()
        mounts[root.standardizedFileURL.path] = Mount(archive: archive, root: root, index: index, passphrase: passphrase)
        lock.unlock()
    }

    /// The same archive (same place, size and date) always gets the same cache folder.
    static func key(for archive: URL) -> String {
        let values = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(archive.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Opening

    struct OpenError: Error {
        let message: String
        var needsPassphrase = false
        var wrongPassphrase = false
    }

    /// Reads the archive's list of contents (or unpacks it, when libarchive cannot) and reports the folder that
    /// stands for it; main queue.
    func open(_ archive: URL, passphrase: String? = nil, completion: @escaping (Result<URL, OpenError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let directory = Self.cacheDirectory
            let root = directory.appendingPathComponent(Self.key(for: archive), isDirectory: true)
            self.lock.lock()
            let existing = self.mounts[root.standardizedFileURL.path]
            self.lock.unlock()
            if let existing, existing.index != nil || ArchiveReader.isAvailable == false {
                if let passphrase { existing.passphrase = passphrase }
                DispatchQueue.main.async { completion(.success(root)) }
                return
            }
            guard ArchiveReader.isAvailable else { self.openByUnpacking(archive, root: root, completion: completion); return }
            switch ArchiveReader.list(archive, passphrase: passphrase) {
            case .failure(let failure):
                // a format libarchive does not know: let bsdtar try, the way it always did
                if case .failed = failure, !ArchiveExtractor.isBrowsable(archive) {
                    DispatchQueue.main.async { completion(.failure(OpenError(message: failure.message))) }
                } else if case .failed = failure {
                    self.openByUnpacking(archive, root: root, completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(OpenError(message: failure.message, needsPassphrase: failure == .passphraseRequired || failure == .wrongPassphrase,
                                                      wrongPassphrase: failure == .wrongPassphrase)))
                    }
                }
            case .success(let entries):
                try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: root.path)
                let index = ArchiveIndex(entries)
                DispatchQueue.main.async {
                    self.register(root: root, archive: archive, index: index, passphrase: passphrase)
                    completion(.success(root))
                }
            }
        }
    }

    /// The old way: everything is unpacked into the cache folder first.
    private func openByUnpacking(_ archive: URL, root: URL, completion: @escaping (Result<URL, OpenError>) -> Void) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            let partial = Self.cacheDirectory.appendingPathComponent(Self.key(for: archive) + "." + UUID().uuidString + ".partial", isDirectory: true)
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
                Self.makeWritable(partial)
                try? fm.removeItem(at: partial)
                if !fm.fileExists(atPath: root.path) {      // the other attempt got there first: its copy is just as good
                    DispatchQueue.main.async { completion(.failure(OpenError(message: error.localizedDescription))) }
                    return
                }
            }
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: root.path)
        DispatchQueue.main.async {
            self.register(root: root, archive: archive)
            completion(.success(root))
        }
    }

    // MARK: Placeholders

    private static func hasPlaceholderMark(_ path: String) -> Bool {
        getxattr(path, placeholderMark, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Makes the children of a folder of the archive appear in the cache: folders, and files of the right size and date
    /// that are only placeholders until they are needed. Cheap; called whenever the lister reads the folder.
    func populate(_ directory: URL) {
        guard let (mount, inner) = mount(for: directory), let index = mount.index else { return }
        let fm = FileManager.default
        for childPath in index.children[inner.joined(separator: "/")] ?? [] {
            guard let child = index.entries[childPath] else { continue }
            let url = mount.root.appendingPathComponent(childPath, isDirectory: child.isDirectory)
            if child.isDirectory {
                if !fm.fileExists(atPath: url.path) {
                    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                    if let date = child.modified { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
                }
                continue
            }
            if fm.fileExists(atPath: url.path) { continue }
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
            if child.size > 0, let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: UInt64(child.size))
                try? handle.close()
                setxattr(url.path, Self.placeholderMark, "1", 1, 0, XATTR_NOFOLLOW)
            }
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o444]      // nothing to write into a placeholder
            if let date = child.modified { attributes[.modificationDate] = date }
            try? fm.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }

    /// Paths (inside the archive) of the files below these URLs that still have to be taken out of the archive.
    private func pendingFiles(_ urls: [URL]) -> [(mount: Mount, paths: [String])] {
        var byMount: [String: (Mount, Set<String>)] = [:]
        for url in urls {
            guard let (mount, inner) = mount(for: url), let index = mount.index else { continue }
            for file in index.files(under: inner.joined(separator: "/")) where file.size > 0 {
                let path = mount.root.appendingPathComponent(file.path).path
                if !FileManager.default.fileExists(atPath: path) || Self.hasPlaceholderMark(path) {
                    byMount[mount.root.path, default: (mount, [])].1.insert(file.path)
                }
            }
        }
        return byMount.values.map { ($0.0, Array($0.1)) }
    }

    /// Is any of these files (or a file in these folders) still only a placeholder?
    func needsMaterialization(_ urls: [URL]) -> Bool { !pendingFiles(urls).isEmpty }

    /// Total size of what still has to be taken out of the archive for these URLs.
    func pendingBytes(_ urls: [URL]) -> Int64 {
        pendingFiles(urls).reduce(0) { total, group in
            total + group.paths.reduce(0) { $0 + (group.mount.index?.entries[$1]?.size ?? 0) }
        }
    }

    /// Takes the files out of the archive into the cache folder (replacing the placeholders); main queue.
    func materialize(_ urls: [URL], cancel: CancelToken? = nil, progress: ((Int64) -> Void)? = nil,
                     completion: @escaping (Result<Void, ArchiveReader.Failure>) -> Void) {
        let work = pendingFiles(urls)
        guard !work.isEmpty else { completion(.success(())); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var finished: Int64 = 0
            for (mount, paths) in work {
                var outcome: Result<Void, ArchiveReader.Failure> = .success(())
                mount.queue.sync {
                    let base = finished
                    switch ArchiveReader.extract(mount.archive, wanting: Set(paths), to: mount.root, passphrase: mount.passphrase,
                                                 cancel: cancel, progress: { done in
                        DispatchQueue.main.async { progress?(base + done) }
                    }) {
                    case .success: break
                    case .failure(let failure): outcome = .failure(failure)
                    }
                }
                if case .failure = outcome { DispatchQueue.main.async { completion(outcome) }; return }
                finished += paths.reduce(0) { $0 + (mount.index?.entries[$1]?.size ?? 0) }
            }
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    /// Synchronous variant (a drag out of the list cannot wait).
    func materializeNow(_ urls: [URL]) -> Bool {
        let work = pendingFiles(urls)
        for (mount, paths) in work {
            var ok = false
            mount.queue.sync {
                if case .success = ArchiveReader.extract(mount.archive, wanting: Set(paths), to: mount.root, passphrase: mount.passphrase) { ok = true }
            }
            if !ok { return false }
        }
        return true
    }

    func setPassphrase(_ passphrase: String, for url: URL) {
        mount(for: url)?.mount.passphrase = passphrase
    }

    func hasEncryptedFiles(_ url: URL) -> Bool { mount(for: url)?.mount.index?.hasEncryptedFiles ?? false }

    /// The size of a file or of everything in a folder of the archive, from the list (nothing has to be unpacked).
    func indexedSize(of url: URL) -> Int64? {
        guard let (mount, inner) = mount(for: url), let index = mount.index else { return nil }
        let path = inner.joined(separator: "/")
        guard path.isEmpty || index.entries[path] != nil else { return nil }
        return index.files(under: path).reduce(0) { $0 + $1.size }
    }

    /// Does the list hold `inner` below `url`'s archive? (the self-test reads it)
    func indexedNames(in url: URL) -> [String]? {
        guard let (mount, inner) = mount(for: url), let index = mount.index else { return nil }
        return (index.children[inner.joined(separator: "/")] ?? []).map { ($0 as NSString).lastPathComponent }.sorted()
    }

    // MARK: Housekeeping

    /// Removes unpacked archives nobody has opened for a while (called when the app starts).
    static func cleanOldCaches(olderThan seconds: TimeInterval = 2 * 86_400) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(date) > seconds {
                makeWritable(entry)                 // a folder unpacked with mode 0555 cannot be emptied otherwise
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Gives the owner write and search permission on every folder below `url` (and on `url`).
    static func makeWritable(_ url: URL) {
        let fm = FileManager.default
        func fix(_ item: URL) {
            guard let mode = (try? fm.attributesOfItem(atPath: item.path)[.posixPermissions]) as? NSNumber else { return }
            try? fm.setAttributes([.posixPermissions: NSNumber(value: mode.intValue | 0o700)], ofItemAtPath: item.path)
        }
        fix(url)
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { fix(item) }
    }

    /// The folder the directory tree shows for a lister: the one the archive lies in, not the cache folder.
    func treeFolder(for url: URL) -> URL {
        let real = realFile(for: url)
        return real == url ? url : real.deletingLastPathComponent()
    }

    /// The real file behind a path inside an archive (an archive inside an archive counts through to the outer one).
    func realFile(for url: URL) -> URL {
        var current = url
        while let location = location(of: current) { current = location.archive }
        return current
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

    // MARK: Opening an archive

    /// Double-click on an archive: read its list of contents and show it as a folder (the files stay in the archive until needed).
    func browseArchive(_ archive: URL, passphrase: String? = nil, attempt: Int = 1) {
        // an archive inside an archive has to come out of the outer one first
        if ArchiveBrowser.shared.needsMaterialization([archive]) {
            materialized([archive]) { [weak self] in self?.browseArchive(archive) }
            return
        }
        model.statusMessage = tr("Reading “%@”…", archive.lastPathComponent)
        ArchiveBrowser.shared.open(archive, passphrase: passphrase) { [weak self] result in
            guard let self else { return }
            self.model.statusMessage = nil
            switch result {
            case .success(let root): self.model.navigate(to: root)
            case .failure(let error) where error.needsPassphrase && attempt <= 3:
                if let entered = self.askPassphrase(for: archive, wrong: error.wrongPassphrase) {
                    self.browseArchive(archive, passphrase: entered, attempt: attempt + 1)
                }
            case .failure(let error): self.model.errorMessage = "\(archive.lastPathComponent): \(error.message)"
            }
        }
    }

    /// Asks for an archive's password; nil when the user gives up.
    func askPassphrase(for archive: URL, wrong: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = wrong ? tr("The password is not correct") : tr("“%@” is protected by a password", archive.lastPathComponent)
        alert.informativeText = tr("Enter the password to open it. It is kept only until MacLister quits.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Open"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.bringToFront()
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    // MARK: Taking files out when they are needed

    /// Runs `then` once the files at `urls` are really there: at once for anything outside an archive or already taken
    /// out, otherwise after they have been extracted (with progress, Cancel and a password question when needed).
    func materialized(_ urls: [URL], attempt: Int = 1, then: @escaping () -> Void) {
        guard ArchiveBrowser.shared.needsMaterialization(urls) else { then(); return }
        let total = max(1, ArchiveBrowser.shared.pendingBytes(urls))
        let token = CancelToken()
        let text = tr("Taking files out of the archive…")
        model.progress = TransferStatus(text: text, fraction: 0, cancel: { token.cancel() })
        ArchiveBrowser.shared.materialize(urls, cancel: token, progress: { [weak self] done in
            guard let self, self.model.progress != nil else { return }
            self.model.progress = TransferStatus(text: text + " · " + ByteCountFormatter.string(fromByteCount: done, countStyle: .file),
                                                 fraction: min(1, Double(done) / Double(total)), cancel: { token.cancel() })
        }, completion: { [weak self] result in
            guard let self else { return }
            self.model.progress = nil
            switch result {
            case .success: then()
            case .failure(.cancelled): break
            case .failure(let failure) where (failure == .passphraseRequired || failure == .wrongPassphrase) && attempt <= 3:
                let archive = urls.first.flatMap { ArchiveBrowser.shared.location(of: $0)?.archive } ?? URL(fileURLWithPath: "/")
                if let entered = self.askPassphrase(for: archive, wrong: failure == .wrongPassphrase) {
                    urls.forEach { ArchiveBrowser.shared.setPassphrase(entered, for: $0) }
                    self.materialized(urls, attempt: attempt + 1, then: then)
                }
            case .failure(let failure): self.model.errorMessage = failure.message
            }
        })
    }
}
