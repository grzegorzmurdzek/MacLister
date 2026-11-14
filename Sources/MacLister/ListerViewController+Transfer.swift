import AppKit

/// Copy and move with progress, Cancel and per-conflict decisions.
extension ListerViewController {

    /// Copies or moves dropped files into `folder`.
    func transfer(_ kind: TransferKind, items: [URL], into folder: URL) {
        if kind == .move, refuseIfBusy(items) { return }
        if RemoteURL.isRemote(folder) || items.contains(where: RemoteURL.isRemote) {
            beginRemoteTransfer(kind, items: items, into: folder, showingIn: [model])
            return
        }
        beginTransfer(kind, items: items, into: folder, showingIn: [model])
    }

    /// Something that is being copied or moved (or waits in the queue to be) must not be trashed, renamed or
    /// moved from under the job. Tells the user and returns true when `urls` are in use.
    func refuseIfBusy(_ urls: [URL]) -> Bool {
        guard let busy = urls.first(where: { TransferQueue.shared.isBusy($0) }) else { return false }
        let name = RemoteURL.isRemote(busy) ? (RemoteURL.path(of: busy) as NSString).lastPathComponent : busy.lastPathComponent
        model.errorMessage = tr("“%@” is being transferred. Wait until it finishes or cancel the operation.", name)
        return true
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
                flash(tr("Copying between two servers is not supported yet: download the files first"))
                return
            }
            guard kind == .move else {
                flash(tr("Copying inside one server is not supported yet; Move works"))
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

        let verb = direction == .upload ? (kind == .move ? tr("Uploading (move)") : tr("Uploading"))
                 : direction == .download ? (kind == .move ? tr("Downloading (move)") : tr("Downloading")) : tr("Moving")
        let cancel: () -> Void = { [weak job] in job?.cancel() }
        let monitor = TransferMonitor(title: verb, from: Self.placeName(items.first?.deletingLastPathComponent()), to: Self.placeName(folder))
        monitor.onCancel = cancel
        monitor.onPause = { [weak job] in job?.gate.pause() }
        monitor.onResume = { [weak job] in job?.gate.resume() }
        job.onProgress = { progress in
            monitor.update(progress)
            let status = TransferStatus(text: Self.progressText(verb: verb, progress: progress, speed: monitor.speed, paused: monitor.isPaused),
                                        fraction: progress.bytesTotal > 0 ? progress.fraction : (progress.itemsTotal > 1 ? Double(progress.itemsDone) / Double(progress.itemsTotal) : nil),
                                        cancel: cancel, details: monitor)
            for m in models { m.progress = status }
        }
        let started = TransferQueue.shared.submit(
            key: TransferQueue.key(forDestination: folder), sources: items,
            detail: Self.queueDetail(verb: verb, items: items, to: folder),
            onCancel: { for m in models { m.statusMessage = nil } }
        ) { done in
            for m in models { m.statusMessage = nil; m.progress = TransferStatus(text: tr("%@…", verb), fraction: nil, cancel: cancel, details: monitor) }
            job.start { [weak self] result in
                monitor.finish(result.cancelled ? .cancelled : (result.failures.isEmpty ? .finished : .failed))
                for m in models { m.progress = nil }
                OperationLog.shared.record(kind: direction == .upload ? .upload : direction == .download ? .download : .moveOnServer,
                                           items: items, result: result,
                                           from: Self.placeName(items.first?.deletingLastPathComponent()), to: Self.placeName(folder))
                ListerManager.shared.reloadListers(showing: [folder] + items.map { $0.deletingLastPathComponent() })
                done()
                guard let self else { return }
                if !result.failures.isEmpty {
                    self.model.errorMessage = result.failures.joined(separator: "; ")
                } else if result.cancelled {
                    self.flash(tr("Cancelled after %d of %d items", result.done.count, items.count))
                } else if result.done.isEmpty, result.skipped > 0 {
                    self.flash(tr("Nothing transferred: %d skipped", result.skipped))
                }
            }
        }
        if !started { for m in models { m.statusMessage = tr("Waiting in queue…") } }
    }

    /// "Copying 3 of 12 · 1,2 GB of 6 GB · 37,8 MB/s · name" — the status-line text.
    static func progressText(verb: String, progress: TransferProgress, speed: Double, paused: Bool, queued: Int = TransferQueue.shared.waiting.count) -> String {
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        var text = tr("%@ %d of %d", verb, min(progress.itemsDone + 1, progress.itemsTotal), progress.itemsTotal)
        if progress.bytesTotal > 0 {
            text += " · " + tr("%@ of %@", byteFormatter.string(fromByteCount: min(progress.effectiveBytes, progress.bytesTotal)), byteFormatter.string(fromByteCount: progress.bytesTotal))
        }
        if paused { text += " · " + tr("Paused") } else if speed > 0 { text += " · " + TransferMonitor.speedText(speed) }
        if !progress.current.isEmpty { text += " · \(progress.current)" }
        if queued > 0 { text += " · " + tr("In queue: %d", queued) }
        return text
    }

    /// "Copying: report.pdf +2 → NAS Backup" — how a waiting operation is listed in the queue menu.
    static func queueDetail(verb: String, items: [URL], to folder: URL) -> String {
        let first = RemoteURL.isRemote(items[0]) ? (RemoteURL.path(of: items[0]) as NSString).lastPathComponent : items[0].lastPathComponent
        let more = items.count > 1 ? " +\(items.count - 1)" : ""
        return "\(verb): \(first)\(more) → \(Self.placeName(folder))"
    }

    /// A short place name for the details window: "Downloads", or the server for a remote folder.
    static func placeName(_ url: URL?) -> String {
        guard let url else { return "" }
        if RemoteURL.isRemote(url) { return RemoteURL.serverLabel(of: url) + RemoteURL.path(of: url) }
        return FileManager.default.displayName(atPath: url.path)
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
        let monitor = TransferMonitor(title: verb, from: Self.placeName(items.first?.deletingLastPathComponent()), to: Self.placeName(folder))
        monitor.onCancel = cancel
        monitor.onPause = { [weak job] in job?.gate.pause() }
        monitor.onResume = { [weak job] in job?.gate.resume() }

        job.onProgress = { progress in
            monitor.update(progress)
            let status = TransferStatus(text: Self.progressText(verb: verb, progress: progress, speed: monitor.speed, paused: monitor.isPaused),
                                        fraction: progress.bytesTotal > 0 || progress.itemsTotal > 0 ? progress.fraction : nil,
                                        cancel: cancel, details: monitor)
            for m in models { m.progress = status }
        }

        let started = TransferQueue.shared.submit(
            key: TransferQueue.key(forDestination: folder), sources: items,
            detail: Self.queueDetail(verb: verb, items: items, to: folder),
            onCancel: { for m in models { m.statusMessage = nil } }
        ) { done in
            for m in models { m.statusMessage = nil; m.progress = TransferStatus(text: tr("%@…", verb), fraction: nil, cancel: cancel, details: monitor) }
            job.start { [weak self] result in
                monitor.finish(result.cancelled ? .cancelled : (result.failures.isEmpty ? .finished : .failed))
                for m in models { m.progress = nil }
                OperationLog.shared.record(kind: kind == .copy ? .copy : .move, items: items, result: result,
                                           from: Self.placeName(items.first?.deletingLastPathComponent()), to: Self.placeName(folder))
                let folders = [folder] + items.map { $0.deletingLastPathComponent() }
                ListerManager.shared.reloadListers(showing: folders)
                done()
                guard let self else { return }
                if !result.failures.isEmpty {
                    self.model.errorMessage = result.failures.joined(separator: "; ")
                } else if result.cancelled {
                    self.flash(tr("Cancelled after %d of %d items", result.done.count, items.count))
                } else if result.done.isEmpty, result.skipped > 0 {
                    self.flash(kind == .copy ? tr("Nothing copied: %d skipped", result.skipped) : tr("Nothing moved: %d skipped", result.skipped))
                }
            }
        }
        if !started { for m in models { m.statusMessage = tr("Waiting in queue…") } }
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
            return [(tr("Merge"), .merge), (tr("Replace"), .replace), (tr("Keep Both"), .keepBoth), (tr("Skip"), .skip), (tr("Cancel"), .cancel)]
        }
        if conflict.bothFiles {
            return [(tr("Replace"), .replace), (tr("Replace If Newer"), .replaceIfNewer), (tr("Keep Both"), .keepBoth), (tr("Skip"), .skip), (tr("Cancel"), .cancel)]
        }
        return [(tr("Replace"), .replace), (tr("Keep Both"), .keepBoth), (tr("Skip"), .skip), (tr("Cancel"), .cancel)]
    }

    private static func describe(size: Int64?, modified: Date?, isDirectory: Bool) -> String {
        if isDirectory { return tr("folder") + (modified.map { ", " + tr("modified %@", dateFormatter.string(from: $0)) } ?? "") }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
        return sizeText + (modified.map { ", " + tr("modified %@", dateFormatter.string(from: $0)) } ?? "")
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
        alert.messageText = tr("“%@” already exists in “%@”", conflict.target.lastPathComponent, conflict.target.deletingLastPathComponent().lastPathComponent)
        alert.informativeText = """
            \(tr("New:")) \(describe(size: conflict.sourceSize, modified: conflict.sourceModified, isDirectory: conflict.sourceIsDirectory))
            \(tr("Existing:")) \(describe(size: conflict.targetSize, modified: conflict.targetModified, isDirectory: conflict.targetIsDirectory))

            \(tr("Replace moves the existing item to the Trash."))
            """
        for choice in choices { alert.addButton(withTitle: choice.title) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = tr("Apply to all remaining conflicts")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let action = choices.indices.contains(index) ? choices[index].action : .cancel
            completion(ConflictDecision(action: action, applyToAll: alert.suppressionButton?.state == .on))
        }
        // A sheet on a window that is closed or hidden never shows and may never answer, which would leave
        // the worker (and the whole transfer queue) waiting for good: ask in a dialog of its own instead.
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
