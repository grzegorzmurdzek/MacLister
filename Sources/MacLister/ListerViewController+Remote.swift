import AppKit
import Quartz

/// Servers in a lister: connecting, opening files, Quick Look, and the folder operations that exist
/// on a server (new folder, rename, delete).
extension ListerViewController {

    var isRemote: Bool { model.isRemote }
    var remoteSession: RemoteSession? { RemoteSessions.shared.session(for: model.url) }

    /// For commands that only make sense on this Mac. Returns true (after telling the user) on a server.
    @discardableResult
    func remoteUnavailable(_ what: String) -> Bool {
        guard isRemote else { return false }
        flash(tr("Not available on a server yet: %@", what))
        return true
    }

    // MARK: - Connecting

    /// Called from the Go menu: a saved server connects directly when its login is known, otherwise the
    /// form opens with the fields filled in. `nil` opens an empty form.
    func connectChoice(_ profile: ServerProfile?) {
        guard let profile else { connectToServer(); return }
        let stored = SecretStore.get(profile.id.uuidString) ?? ""
        let canConnectDirectly = !stored.isEmpty || (profile.scheme == .sftp && profile.keyPath != nil) || profile.user.isEmpty
        if canConnectDirectly {
            model.statusMessage = tr("Connecting to %@…", profile.displayName)
            performConnect(profile, secret: stored, remember: false, savePassword: false) { [weak self] message in
                self?.model.statusMessage = nil
                if let message { self?.model.errorMessage = message }
            }
        } else {
            connectToServer(prefill: profile, secret: stored)
        }
    }

    func connectToServer(prefill: ServerProfile? = nil, secret: String = "") {
        guard let window = view.window else { return }
        SheetPresenter().present(on: window, size: NSSize(width: 500, height: 560)) { close in
            ConnectToServerView(initial: prefill, initialSecret: secret, onConnect: { [weak self] profile, password, remember, savePassword, report in
                self?.performConnect(profile, secret: password, remember: remember, savePassword: savePassword, report: report)
            }, close: close)
        }
    }

    private func performConnect(_ profile: ServerProfile, secret: String, remember: Bool, savePassword: Bool,
                                report: @escaping (String?) -> Void) {
        RemoteSessions.shared.connect(profile: profile, secret: secret, confirmHostKey: { keys in
            Self.askToTrustHostKey(profile, keys)
        }, completion: { [weak self] result in
            switch result {
            case .success(let session):
                if remember {
                    ServerStore.shared.save(profile)
                    if savePassword && !secret.isEmpty { SecretStore.set(secret, for: profile.id.uuidString) }
                    else if !savePassword { SecretStore.delete(profile.id.uuidString) }
                }
                report(nil)
                self?.model.navigate(to: session.url(path: session.home))
            case .failure(let error):
                report(error.message)
            }
        })
    }

    /// Runs on the connection's background queue and waits for the answer.
    private static func askToTrustHostKey(_ profile: ServerProfile, _ keys: [HostKeyInfo]) -> Bool {
        var trusted = false
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("Trust the server “%@”?", profile.host)
            let list = keys.map { "\($0.type)  \($0.fingerprint)" }.joined(separator: "\n")
            alert.informativeText = """
                This is the first time you connect to \(profile.host):\(profile.port), so its identity cannot be checked yet.

                \(list)

                Continue only if these fingerprints match what the server's administrator gave you. MacLister remembers them and warns you if they ever change.
                """
            alert.addButton(withTitle: tr("Trust and Connect"))
            alert.addButton(withTitle: tr("Cancel"))
            trusted = alert.runModal() == .alertFirstButtonReturn
        }
        return trusted
    }

    func disconnectCurrent() {
        guard isRemote else { return }
        RemoteSessions.shared.disconnect(model.url)
        model.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Opening and previewing

    func openRemote(_ item: FileItem) {
        guard let session = RemoteSessions.shared.session(for: item.url) else {
            model.errorMessage = tr("Not connected to %@", RemoteURL.serverLabel(of: item.url))
            return
        }
        if item.isDirectory { model.navigate(to: item.url); return }
        if item.isSymlink {
            // a link may point to a folder: find out before deciding between entering and downloading
            model.statusMessage = tr("Opening…")
            let path = RemoteURL.path(of: item.url)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let isFolder = RemoteOps.isFolder(session.fs, path: path)
                DispatchQueue.main.async {
                    self?.model.statusMessage = nil
                    if isFolder { self?.model.navigate(to: item.url) } else { self?.downloadAndOpen([item]) }
                }
            }
            return
        }
        downloadAndOpen([item])
    }

    func downloadAndOpen(_ items: [FileItem]) {
        downloadToCache(items) { urls in urls.forEach { NSWorkspace.shared.open($0) } }
    }

    private static func cacheIsFresh(_ local: URL, for item: FileItem) -> Bool {
        guard let values = try? local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              Int64(values.fileSize ?? -1) == (item.size ?? -2) else { return false }
        // The cache file carries the server's own date (set after the download), so the two compare
        // without involving this Mac's clock. No date on either side: cannot tell, fetch again.
        guard let remote = item.modified, let cached = values.contentModificationDate else { return false }
        return abs(cached.timeIntervalSince(remote)) < 1
    }

    /// Downloads files into the cache (skipping fresh copies) with progress and Cancel, then calls
    /// `completion` with their local URLs on the main queue.
    @discardableResult
    func downloadToCache(_ items: [FileItem], completion: @escaping ([URL]) -> Void) -> (() -> Void)? {
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return nil }
        let token = CancelToken()
        let cancel: () -> Void = { token.cancel() }
        downloadGeneration += 1
        let generation = downloadGeneration
        model.progress = TransferStatus(text: tr("Downloading…"), fraction: nil, cancel: cancel)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var local: [URL] = []
            var failure: String?
            for (index, item) in files.enumerated() {
                if token.isCancelled { break }
                guard let session = RemoteSessions.shared.session(for: item.url) else { failure = tr("Not connected to the server"); break }
                let target = RemoteCache.localURL(for: item.url)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if Self.cacheIsFresh(target, for: item) { local.append(target); continue }
                DispatchQueue.main.async {
                    self?.model.progress = TransferStatus(text: tr("Downloading %d of %d", index + 1, files.count) + " · \(item.name)",
                                                          fraction: Double(index) / Double(files.count), cancel: cancel)
                }
                do {
                    try session.fs.download(RemoteURL.path(of: item.url), to: target, cancel: token)
                    if let modified = item.modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
                    local.append(target)
                } catch {
                    if (error as? RemoteError)?.message != RemoteError.cancelled.message { failure = error.localizedDescription }
                    break
                }
            }
            DispatchQueue.main.async {
                // A newer download owns the progress display now: leave it alone.
                if let self, self.downloadGeneration == generation { self.model.progress = nil }
                if let failure { self?.model.errorMessage = failure }
                else if !token.isCancelled { completion(local) }
            }
        }
        return cancel
    }

    /// Local copies of the selected server files that are already downloaded.
    var quickLookURLs: [URL] {
        guard isRemote else { return selectedItems.map(\.url) }
        return selectedItems.filter { !$0.isDirectory }.compactMap { item in
            let local = RemoteCache.localURL(for: item.url)
            return FileManager.default.fileExists(atPath: local.path) ? local : nil
        }
    }

    /// Quick Look on a server: download the selection first, then show the panel.
    func remoteQuickLook() {
        let files = selectedItems.filter { !$0.isDirectory }
        guard !files.isEmpty, let panel = QLPreviewPanel.shared() else { NSSound.beep(); return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { panel.orderOut(nil); return }
        quickLookDownloadCancel?()
        quickLookDownloadCancel = downloadToCache(files) { _ in
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// While the panel is open and the selection changes, fetch the new files so it can follow.
    func refreshRemoteQuickLook() {
        let files = selectedItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { QLPreviewPanel.shared()?.reloadData(); return }
        quickLookDownloadCancel?()          // the selection moved on: stop fetching the previous one
        quickLookDownloadCancel = downloadToCache(files) { _ in QLPreviewPanel.shared()?.reloadData() }
    }

    // MARK: - Folder operations

    func remoteMakeDirectory(_ name: String) {
        guard let session = remoteSession else { return }
        let target = RemoteURL.child(of: model.url, named: name)
        let path = RemoteURL.path(of: target)
        model.statusMessage = tr("Creating folder…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try session.fs.makeDirectory(path) }
            DispatchQueue.main.async {
                self?.model.statusMessage = nil
                switch result {
                case .success: self?.model.reload(selecting: target)
                case .failure(let error): self?.model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func promptRemoteRename(_ item: FileItem) {
        promptText(title: tr("Rename “%@”", item.name), message: tr("New name on the server:"), initial: item.name, button: tr("Rename")) { [weak self] newName in
            self?.remoteRename(item, to: newName)
        }
    }

    func remoteRename(_ item: FileItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == item.name { return }
        guard !name.isEmpty, !name.contains("/") else {
            model.errorMessage = tr("Invalid name")
            return
        }
        guard let session = RemoteSessions.shared.session(for: item.url) else { return }
        let from = RemoteURL.path(of: item.url)
        let to = RemoteURL.join(RemoteURL.parentPath(of: from), name)
        let newURL = RemoteURL.with(path: to, on: item.url)
        model.statusMessage = tr("Renaming…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try session.fs.rename(from, to: to) }
            DispatchQueue.main.async {
                self?.model.statusMessage = nil
                switch result {
                case .success: self?.model.reload(selecting: newURL)
                case .failure(let error): self?.model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func confirmRemoteDelete() {
        let items = selectedItems
        guard !items.isEmpty, let window = view.window else { NSSound.beep(); return }
        if refuseIfBusy(items.map(\.url)) { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = items.count == 1 ? tr("Delete “%@” from the server?", items[0].name) : trCount("Delete %d items from the server?", items.count)
        alert.informativeText = tr("This cannot be undone: a server has no Trash. Folders are deleted with everything inside.")
        let delete = alert.addButton(withTitle: tr("Delete"))
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remoteDelete(items) }
        }
    }

    func remoteDelete(_ items: [FileItem]) {
        let token = CancelToken()
        let cancel: () -> Void = { token.cancel() }
        model.progress = TransferStatus(text: tr("Deleting…"), fraction: nil, cancel: cancel)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            for item in items {
                guard let session = RemoteSessions.shared.session(for: item.url) else { failures.append(tr("Not connected")); break }
                do {
                    try RemoteOps.deleteRecursively(session.fs, path: RemoteURL.path(of: item.url),
                                                    isDirectory: item.isDirectory && !item.isSymlink, cancel: token)
                } catch {
                    if (error as? RemoteError)?.message != RemoteError.cancelled.message { failures.append("\(item.name): \(error.localizedDescription)") }
                    break
                }
            }
            DispatchQueue.main.async {
                self?.model.progress = nil
                self?.model.reload()
                if !failures.isEmpty { self?.model.errorMessage = failures.joined(separator: "; ") }
            }
        }
    }
}
