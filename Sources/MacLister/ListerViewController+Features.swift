import AppKit

/// Directory-Opus-style features: pattern selection, filter, folder sizes, compare, info,
/// duplicate, filetype actions, bookmarks.
extension ListerViewController {

    // MARK: - Small text prompt

    func promptText(title: String, message: String, initial: String, button: String,
                    completion: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
        field.selectText(nil)
    }

    // MARK: - Selection

    /// Replaces the selection with the rows showing these URLs.
    func select(urls: Set<URL>) {
        var indexes = IndexSet()
        for (i, row) in rows.enumerated() where urls.contains(row.url) { indexes.insert(i) }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    func selectAllRows() { tableView.selectAll(nil) }

    func selectNoRows() { tableView.deselectAll(nil) }

    func invertSelection() {
        let current = tableView.selectedRowIndexes
        var inverted = IndexSet()
        for i in rows.indices where !current.contains(i) { inverted.insert(i) }
        tableView.selectRowIndexes(inverted, byExtendingSelection: false)
    }

    func promptPattern(select: Bool) {
        promptText(
            title: select ? "Select by Pattern" : "Deselect by Pattern",
            message: "Wildcards such as *.jpg or IMG_??.png, several separated by spaces. Text without wildcards matches names containing it.",
            initial: model.lastPattern,
            button: select ? "Select" : "Deselect"
        ) { [weak self] text in
            self?.model.lastPattern = text
            self?.applyPattern(text, select: select)
        }
    }

    /// Adds (or removes) every row whose name matches the pattern to the selection.
    func applyPattern(_ text: String, select: Bool) {
        let patterns = NamePattern.parse(text)
        guard !patterns.isEmpty else { return }
        var indexes = tableView.selectedRowIndexes
        for (i, row) in rows.enumerated() where NamePattern.matches(row.name, patterns: patterns) {
            if select { indexes.insert(i) } else { indexes.remove(i) }
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    // MARK: - Filter

    func promptFilter() {
        promptText(
            title: "Filter",
            message: "Show only files matching these patterns (folders always stay). Leave empty to show everything.",
            initial: model.filter,
            button: "Apply"
        ) { [weak self] text in self?.model.setFilter(text) }
    }

    // MARK: - Folder sizes

    /// Calculates the sizes of the selected folders, or of all folders here when none is selected.
    func calculateFolderSizes() {
        let selectedFolders = selectedItems.filter(\.isDirectory).map(\.url)
        let targets = selectedFolders.isEmpty ? rows.filter(\.isDirectory).map(\.url) : selectedFolders
        guard !targets.isEmpty else {
            flash("No folders to measure")
            return
        }
        model.calculateSizes(of: targets)
    }

    // MARK: - Compare

    /// Selects, in both the source and the destination lister, the items that are missing on the
    /// other side or differ (other size, or newer). Magellan's "compare".
    func compareWithDestination() {
        let manager = ListerManager.shared
        guard let destination = manager.destinationController else {
            model.errorMessage = "No destination lister: press DST in the lister to compare with"
            return
        }
        guard let source = manager.sourceController ?? (view.window?.windowController as? ListerWindowController),
              source !== destination else {
            model.errorMessage = "Source and destination are the same lister"
            return
        }
        model.errorMessage = nil
        let inSource = Self.differing(source.model.items, against: destination.model.items)
        let inDestination = Self.differing(destination.model.items, against: source.model.items)
        source.listerViewController?.select(urls: inSource)
        destination.listerViewController?.select(urls: inDestination)
        flash("Compare: \(inSource.count) differ in source, \(inDestination.count) in destination")
    }

    /// Items of `items` that have no same-named counterpart in `other`, or whose file differs
    /// (different size, or modified more than 2 s later).
    static func differing(_ items: [FileItem], against other: [FileItem]) -> Set<URL> {
        var byName: [String: FileItem] = [:]
        for item in other { byName[item.name] = item }
        return Set(items.filter { item in
            guard let counterpart = byName[item.name] else { return true }
            if item.isDirectory || counterpart.isDirectory { return false }
            if item.size != counterpart.size { return true }
            if let mine = item.modified, let theirs = counterpart.modified, mine > theirs.addingTimeInterval(2) { return true }
            return false
        }.map(\.url))
    }

    // MARK: - Source / destination helpers

    /// Opens the selected folder (or this folder) in the destination lister.
    func showInDestination() {
        guard let destination = ListerManager.shared.destinationController, destination.model !== model else {
            model.errorMessage = "No other destination lister: press DST in another lister first"
            return
        }
        let target = selectedItems.count == 1 && selectedItems[0].isNavigable ? selectedItems[0].url : model.url
        destination.model.navigate(to: target)
    }

    /// Makes the destination lister show the same folder as the source.
    func destinationHere() {
        let manager = ListerManager.shared
        let sourceModel = manager.sourceController?.model ?? model
        guard let destination = manager.destinationController, destination.model !== sourceModel else {
            model.errorMessage = "No other destination lister: press DST in another lister first"
            return
        }
        destination.model.navigate(to: sourceModel.url)
    }

    // MARK: - Info and duplicate

    func showInfo() {
        let urls = model.selectedURLs.isEmpty ? [model.url] : model.selectedURLs
        model.statusMessage = "Reading info…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = InfoText.make(for: urls)
            DispatchQueue.main.async {
                self?.model.statusMessage = nil
                self?.presentInfo(info)
            }
        }
    }

    private func presentInfo(_ info: (title: String, body: String)) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = info.title
        alert.informativeText = info.body
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Duplicates the selected files next to the originals ("name copy.ext").
    func duplicateSelection() {
        let urls = model.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileTransfer.duplicate(urls)
            DispatchQueue.main.async {
                guard let self else { return }
                var selection: [ObjectIdentifier: URL] = [:]
                if let first = result.done.first, let controller = self.view.window?.windowController {
                    selection[ObjectIdentifier(controller)] = first
                }
                ListerManager.shared.reloadListers(showing: [self.model.url], selecting: selection)
                if !result.failures.isEmpty { self.model.errorMessage = result.failures.joined(separator: "; ") }
            }
        }
    }

    func duplicateLister() {
        guard let controller = view.window?.windowController as? ListerWindowController else { return }
        ListerManager.shared.duplicate(controller)
    }

    func addBookmark() {
        BookmarkStore.shared.add(model.url)
        flash("Bookmarked \(model.url.lastPathComponent)")
    }

    // MARK: - Filetypes

    /// Runs a filetype rule for a double-clicked file. Returns false to fall back to the default open.
    func runFiletype(_ rule: FiletypeRule, on item: FileItem) -> Bool {
        switch rule.action {
        case .open:
            return false
        case .extract:
            guard ArchiveExtractor.isArchive(item.url) else { return false }
            extractArchives([item.url], from: model)
            return true
        case .quicklook:
            toggleQuickLook()
            return true
        case .app:
            guard let spec = rule.app, let app = Self.applicationURL(spec) else {
                model.errorMessage = "Filetype application not found: \(rule.app ?? "(none)")"
                return true
            }
            NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .shell:
            runShell(rule.command)
            return true
        }
    }

    private static func applicationURL(_ spec: String) -> URL? {
        if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec) { return byID }
        let path = (spec as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: - Drag and drop

    static func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (objects ?? []).map(\.standardizedFileURL)
    }

    /// Finder rules: same volume moves, another volume copies, ⌥ forces copy, ⌘ forces move.
    /// Returns [] (refuse) when an item is already in the target folder or the target lies inside an item.
    static func dragOperation(for urls: [URL], into folder: URL, modifiers: NSEvent.ModifierFlags,
                              sourceMask: NSDragOperation) -> NSDragOperation {
        let target = folder.standardizedFileURL.path
        for url in urls {
            let item = url.standardizedFileURL
            if item.deletingLastPathComponent().path == target { return [] }
            if target == item.path || target.hasPrefix(item.path + "/") { return [] }
        }
        var wanted: NSDragOperation
        if modifiers.contains(.option) { wanted = .copy }
        else if modifiers.contains(.command) { wanted = .move }
        else { wanted = urls.allSatisfy { sameVolume($0, folder) } ? .move : .copy }
        if !sourceMask.contains(wanted) { wanted = sourceMask.contains(.copy) ? .copy : (sourceMask.contains(.move) ? .move : []) }
        return wanted
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func id(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x.isEqual(y)
    }

    /// Copies or moves dropped files into `folder`, asking once about name conflicts.
    func transfer(_ kind: TransferKind, items: [URL], into folder: URL) {
        let start: (ConflictPolicy) -> Void = { [weak self] policy in
            guard let self else { return }
            self.model.statusMessage = "\(kind.progressVerb) \(items.count) item\(items.count == 1 ? "" : "s")…"
            FileTransfer.perform(kind, items: items, into: folder, policy: policy) { result in
                self.model.statusMessage = nil
                let folders = [folder] + items.map { $0.deletingLastPathComponent() }
                ListerManager.shared.reloadListers(showing: folders)
                if !result.failures.isEmpty { self.model.errorMessage = result.failures.joined(separator: "; ") }
            }
        }
        let conflicts = FileTransfer.conflicts(of: items, in: folder)
        if conflicts.isEmpty {
            start(.keepBoth)
        } else {
            askConflictPolicy(kind, conflicts: conflicts, destination: folder) { policy in
                if let policy { start(policy) }
            }
        }
    }

    // MARK: - Transient status

    /// Shows a message in the status bar for a few seconds.
    func flash(_ text: String) {
        model.statusMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak model] in
            if model?.statusMessage == text { model?.statusMessage = nil }
        }
    }
}
