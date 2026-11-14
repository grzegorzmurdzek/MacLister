import AppKit

/// Copy and move with progress, Cancel and per-conflict decisions.
extension ListerViewController {

    /// Copies or moves dropped files into `folder`.
    func transfer(_ kind: TransferKind, items: [URL], into folder: URL) {
        if RemoteURL.isRemote(folder) || items.contains(where: RemoteURL.isRemote) {
            beginRemoteTransfer(kind, items: items, into: folder, showingIn: [model])
            return
        }
        beginTransfer(kind, items: items, into: folder, showingIn: [model])
    }

    /// Finder-like rule for a drop onto a server: copy, ⌘ moves. Only local files can be dropped.
    static func remoteDragOperation(for urls: [URL], modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return [] }
        return modifiers.contains(.command) ? .move : .copy
    }

    /// Upload, download, or a move inside one server. Same progress, Cancel and conflict questions as
    /// local transfers.
    func beginRemoteTransfer(_ kind: TransferKind, items: [URL], into folder: URL, showingIn models: [ListerModel],
                             knownSizes: [URL: Int64] = [:]) {
        guard let first = items.first else { return }
        let direction: RemoteTransferJob.Direction
        switch (RemoteURL.isRemote(first), RemoteURL.isRemote(folder)) {
        case (false, true): direction = .upload
        case (true, false): direction = .download
        case (true, true):
            guard RemoteURL.sessionKey(of: first) == RemoteURL.sessionKey(of: folder) else {
                flash("Copying between two servers is not supported yet: download the files first")
                return
            }
            guard kind == .move else {
                flash("Copying inside one server is not supported yet; Move works")
                return
            }
            direction = .moveOnServer
        default:
            return
        }

        let job = RemoteTransferJob(kind: kind, direction: direction, items: items, destination: folder, knownSizes: knownSizes)
        let memory = ConflictMemory()
        let window = view.window
        job.resolver = { conflict in
            if let remembered = memory.action, ConflictRules.canReuse(remembered, for: conflict) {
                return ConflictDecision(action: remembered, applyToAll: true)
            }
            let decision = Self.askAboutConflict(conflict, on: window)
            if decision.applyToAll { memory.action = decision.action }
            return decision
        }

        let verb = direction == .upload ? (kind == .move ? "Uploading (move)" : "Uploading")
                 : direction == .download ? (kind == .move ? "Downloading (move)" : "Downloading") : "Moving"
        let cancel: () -> Void = { [weak job] in job?.cancel() }
        for m in models { m.progress = TransferStatus(text: "\(verb)…", fraction: nil, cancel: cancel) }
        job.onProgress = { progress in
            let byteFormatter = ByteCountFormatter()
            byteFormatter.countStyle = .file
            var text = "\(verb) \(min(progress.itemsDone + 1, progress.itemsTotal)) of \(progress.itemsTotal)"
            if progress.bytesTotal > 0 {
                text += " · \(byteFormatter.string(fromByteCount: progress.bytesDone)) of \(byteFormatter.string(fromByteCount: progress.bytesTotal))"
            }
            if !progress.current.isEmpty { text += " · \(progress.current)" }
            let status = TransferStatus(text: text, fraction: progress.bytesTotal > 0 ? progress.fraction : (progress.itemsTotal > 1 ? Double(progress.itemsDone) / Double(progress.itemsTotal) : nil), cancel: cancel)
            for m in models { m.progress = status }
        }
        job.start { [weak self] result in
            for m in models { m.progress = nil }
            ListerManager.shared.reloadListers(showing: [folder] + items.map { $0.deletingLastPathComponent() })
            guard let self else { return }
            if !result.failures.isEmpty {
                self.model.errorMessage = result.failures.joined(separator: "; ")
            } else if result.cancelled {
                self.flash("Cancelled after \(result.done.count) of \(items.count) item\(items.count == 1 ? "" : "s")")
            } else if result.done.isEmpty, result.skipped > 0 {
                self.flash("Nothing transferred: \(result.skipped) skipped")
            }
        }
    }

    /// Starts a job. Progress and a Cancel button appear in the status line of every lister in `models`.
    func beginTransfer(_ kind: TransferKind, items: [URL], into folder: URL, showingIn models: [ListerModel]) {
        let job = TransferJob(kind: kind, items: items, destination: folder)
        let memory = ConflictMemory()
        let window = view.window

        job.resolver = { conflict in
            if let remembered = memory.action, ConflictRules.canReuse(remembered, for: conflict) {
                return ConflictDecision(action: remembered, applyToAll: true)
            }
            let decision = Self.askAboutConflict(conflict, on: window)
            if decision.applyToAll { memory.action = decision.action }
            return decision
        }

        let verb = kind.progressVerb
        let cancel: () -> Void = { [weak job] in job?.cancel() }
        for m in models { m.progress = TransferStatus(text: "\(verb)…", fraction: nil, cancel: cancel) }

        job.onProgress = { progress in
            let byteFormatter = ByteCountFormatter()
            byteFormatter.countStyle = .file
            var text = "\(verb) \(min(progress.itemsDone + 1, progress.itemsTotal)) of \(progress.itemsTotal)"
            if progress.bytesTotal > 0 {
                text += " · \(byteFormatter.string(fromByteCount: progress.bytesDone)) of \(byteFormatter.string(fromByteCount: progress.bytesTotal))"
            }
            if !progress.current.isEmpty { text += " · \(progress.current)" }
            let status = TransferStatus(text: text, fraction: progress.bytesTotal > 0 || progress.itemsTotal > 0 ? progress.fraction : nil, cancel: cancel)
            for m in models { m.progress = status }
        }

        job.start { [weak self] result in
            for m in models { m.progress = nil }
            let folders = [folder] + items.map { $0.deletingLastPathComponent() }
            ListerManager.shared.reloadListers(showing: folders)
            guard let self else { return }
            if !result.failures.isEmpty {
                self.model.errorMessage = result.failures.joined(separator: "; ")
            } else if result.cancelled {
                self.flash("Cancelled after \(result.done.count) of \(items.count) item\(items.count == 1 ? "" : "s")")
            } else if result.done.isEmpty, result.skipped > 0 {
                self.flash("Nothing \(kind == .copy ? "copied" : "moved"): \(result.skipped) skipped")
            }
        }
    }

    // MARK: - Asking about a conflict

    /// Called on the worker thread: shows the question on the main thread and waits for the answer.
    private static func askAboutConflict(_ conflict: TransferConflict, on window: NSWindow?) -> ConflictDecision {
        var decision = ConflictDecision(action: .cancel)
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            presentConflict(conflict, on: window) { answer in
                decision = answer
                semaphore.signal()
            }
        }
        semaphore.wait()
        return decision
    }

    /// The buttons offered for a conflict, in display order.
    static func conflictChoices(for conflict: TransferConflict) -> [(title: String, action: ConflictAction)] {
        if conflict.bothDirectories {
            return [("Merge", .merge), ("Replace", .replace), ("Keep Both", .keepBoth), ("Skip", .skip), ("Cancel", .cancel)]
        }
        if conflict.bothFiles {
            return [("Replace", .replace), ("Replace If Newer", .replaceIfNewer), ("Keep Both", .keepBoth), ("Skip", .skip), ("Cancel", .cancel)]
        }
        return [("Replace", .replace), ("Keep Both", .keepBoth), ("Skip", .skip), ("Cancel", .cancel)]
    }

    private static func describe(size: Int64?, modified: Date?, isDirectory: Bool) -> String {
        if isDirectory { return "folder" + (modified.map { ", modified \(dateFormatter.string(from: $0))" } ?? "") }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
        return sizeText + (modified.map { ", modified \(dateFormatter.string(from: $0))" } ?? "")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func presentConflict(_ conflict: TransferConflict, on window: NSWindow?,
                                        completion: @escaping (ConflictDecision) -> Void) {
        let choices = conflictChoices(for: conflict)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(conflict.target.lastPathComponent)” already exists in “\(conflict.target.deletingLastPathComponent().lastPathComponent)”"
        alert.informativeText = """
            New: \(describe(size: conflict.sourceSize, modified: conflict.sourceModified, isDirectory: conflict.sourceIsDirectory))
            Existing: \(describe(size: conflict.targetSize, modified: conflict.targetModified, isDirectory: conflict.targetIsDirectory))

            Replace moves the existing item to the Trash.
            """
        for choice in choices { alert.addButton(withTitle: choice.title) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all remaining conflicts"

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let action = choices.indices.contains(index) ? choices[index].action : .cancel
            completion(ConflictDecision(action: action, applyToAll: alert.suppressionButton?.state == .on))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
