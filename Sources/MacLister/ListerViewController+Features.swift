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
        alert.addButton(withTitle: tr("Cancel"))
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
            title: select ? tr("Select by Pattern") : tr("Deselect by Pattern"),
            message: tr("Wildcards such as *.jpg or IMG_??.png, several separated by spaces. Text without wildcards matches names containing it."),
            initial: model.lastPattern,
            button: select ? tr("Select") : tr("Deselect")
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
            title: tr("Filter"),
            message: tr("Show only files matching these patterns (folders always stay). Leave empty to show everything."),
            initial: model.filter,
            button: tr("Apply")
        ) { [weak self] text in self?.model.setFilter(text) }
    }

    // MARK: - Folder sizes

    /// Calculates the sizes of the selected folders, or of all folders here when none is selected.
    func calculateFolderSizes() {
        if remoteUnavailable(tr("Folder sizes")) { return }
        let selectedFolders = selectedItems.filter(\.isDirectory).map(\.url)
        let targets = selectedFolders.isEmpty ? rows.filter(\.isDirectory).map(\.url) : selectedFolders
        guard !targets.isEmpty else {
            flash(tr("No folders to measure"))
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
            model.errorMessage = tr("No destination lister: press DST in the lister to compare with")
            return
        }
        guard let source = manager.sourceController ?? (view.window?.windowController as? ListerWindowController),
              source !== destination else {
            model.errorMessage = tr("Source and destination are the same lister")
            return
        }
        model.errorMessage = nil
        let inSource = Self.differing(source.model.items, against: destination.model.items)
        let inDestination = Self.differing(destination.model.items, against: source.model.items)
        source.listerViewController?.select(urls: inSource)
        destination.listerViewController?.select(urls: inDestination)
        flash(tr("Compare: %d differ in source, %d in destination", inSource.count, inDestination.count))
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
            model.errorMessage = tr("No other destination lister: press DST in another lister first")
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
            model.errorMessage = tr("No other destination lister: press DST in another lister first")
            return
        }
        destination.model.navigate(to: sourceModel.url)
    }

    // MARK: - Info and duplicate

    func showInfo() {
        if remoteUnavailable(tr("Info")) { return }
        let urls = model.selectedURLs.isEmpty ? [model.url] : model.selectedURLs
        model.statusMessage = tr("Reading info…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = InfoText.make(for: urls)
            DispatchQueue.main.async {
                self?.model.statusMessage = nil
                self?.presentInfo(info, urls: urls)
            }
        }
    }

    private func presentInfo(_ info: (title: String, body: String), urls: [URL]) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = info.title
        alert.informativeText = info.body
        alert.addButton(withTitle: tr("OK"))
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        if !files.isEmpty { alert.addButton(withTitle: tr("Checksums…")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.showChecksums(for: files) }
        }
    }

    /// Duplicates the selected files next to the originals ("name copy.ext").
    func duplicateSelection() {
        if remoteUnavailable(tr("Duplicate")) { return }
        if refuseInArchive(tr("Duplicate")) { return }
        let urls = model.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileTransfer.duplicate(urls)
            DispatchQueue.main.async {
                guard let self else { return }
                OperationLog.shared.record(kind: .duplicate, items: urls, result: result,
                                           from: Self.placeName(urls.first?.deletingLastPathComponent()), to: Self.placeName(self.model.url))
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

    /// Opens the selected folder in a new lister.
    func openFolderInNewLister() {
        guard selectedItems.count == 1 else { return }
        openInNewLister(selectedItems[0])
    }

    /// Whether `item` is a folder that can open in a lister of its own (not on a server, in an archive or in a virtual place).
    func canOpenInNewLister(_ item: FileItem) -> Bool {
        item.isNavigable && !isRemote && !model.isInArchive && item.url.scheme != VirtualPlace.scheme
    }

    /// Opens the selected folder in a new tab of this lister's window.
    func openFolderInNewTab() {
        guard selectedItems.count == 1 else { return }
        openInNewTab(selectedItems[0])
    }

    func openInNewTab(_ item: FileItem) {
        guard canOpenInNewLister(item), let controller = windowController else { return }
        ListerManager.shared.openFolder(item.url, inNewTabFrom: controller)
    }

    var windowController: ListerWindowController? { view.window?.windowController as? ListerWindowController }

    /// ⌘T: a new tab on this folder.
    func newTab() {
        guard let controller = windowController else { return }
        ListerManager.shared.newTab(from: controller)
    }

    func selectNeighbourTab(forward: Bool) {
        guard let controller = windowController else { return }
        guard Settings.listerTabs else { flash(tr("Tabs are off: turn them on in Settings → Listers")); return }
        ListerManager.shared.selectNeighbourTab(of: controller, forward: forward)
    }

    /// The menu item that names this lister — or this tab, when the window has tabs.
    var nameMenuTitle: String {
        if isTab { return model.label.isEmpty ? tr("Name This Tab…") : tr("Rename This Tab…") }
        return model.label.isEmpty ? tr("Name This Lister…") : tr("Rename This Lister…")
    }

    func openInNewLister(_ item: FileItem) {
        guard canOpenInNewLister(item), let controller = view.window?.windowController as? ListerWindowController else { return }
        ListerManager.shared.openFolder(item.url, inNewListerFrom: controller)
    }

    func addBookmark() {
        if refuseInList(tr("Add Bookmark")) { return }
        if refuseInArchive(tr("Add Bookmark")) { return }
        BookmarkStore.shared.add(model.url)
        flash(tr("Bookmarked %@", model.url.lastPathComponent))
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
                model.errorMessage = tr("Filetype application not found: %@", rule.app ?? tr("(none)"))
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

    // MARK: - Transient status

    /// Shows a message in the status bar for a few seconds.
    func flash(_ text: String) { model.flash(text) }

    // MARK: - Select by attributes

    func promptSelectByAttributes() {
        guard let window = view.window else { return }
        SheetPresenter().present(on: window, size: NSSize(width: 440, height: 330)) { close in
            SelectByAttributesView(onSelect: { [weak self] filter in self?.applyAttributeFilter(filter) }, close: close)
        }
    }

    /// Adds every matching row to the selection.
    func applyAttributeFilter(_ filter: AttributeFilter) {
        var indexes = tableView.selectedRowIndexes
        for (i, row) in rows.enumerated() where filter.matches(row) { indexes.insert(i) }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        flash(tr("%d selected", indexes.count))
    }

    // MARK: - Batch rename and attributes

    func promptBatchRename() {
        if remoteUnavailable(tr("Batch rename")) { return }
        if refuseInArchive(tr("Batch rename")) { return }
        let urls = model.selectedURLs
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        if refuseIfBusy(urls) { return }
        SheetPresenter().present(on: window, size: NSSize(width: 620, height: 560)) { close in
            BatchRenameView(items: urls, onApply: { [weak self] plan in self?.applyRename(plan) }, close: close)
        }
    }

    func applyRename(_ plan: [RenameEntry]) {
        let result = BatchRename.apply(plan)
        var selection: [ObjectIdentifier: URL] = [:]
        if let first = result.renamed.first, let controller = view.window?.windowController { selection[ObjectIdentifier(controller)] = first }
        ListerManager.shared.reloadListers(showing: Array(Set(plan.map { $0.url.deletingLastPathComponent() })), selecting: selection)
        if !result.failures.isEmpty { model.errorMessage = result.failures.joined(separator: "; ") }
        else { flash(result.renamed.count == 1 ? tr("Renamed 1 item") : trCount("Renamed %d items", result.renamed.count)) }
    }

    /// Permissions, dates, hidden flag, tags and comment of the selection (or of this folder).
    func promptAttributes() {
        if refuseInArchive(tr("Attributes")) { return }
        if remoteUnavailable(tr("Attributes")) { return }
        let urls = model.selectedURLs.isEmpty ? [model.url] : model.selectedURLs
        guard let window = view.window else { return }
        let title = urls.count == 1 ? tr("Attributes of “%@”", urls[0].lastPathComponent) : trCount("Attributes of %d Items", urls.count)
        let initial = AttributeFormState.initial(for: urls)
        SheetPresenter().present(on: window, size: NSSize(width: 480, height: 560)) { close in
            AttributesView(title: title, initial: initial, onApply: { [weak self] change in self?.applyAttributes(change, to: urls) }, close: close)
        }
    }

    func applyAttributes(_ change: AttributeChange, to urls: [URL]) {
        let failures = AttributeEditor.apply(change, to: urls)
        model.reload()
        if !failures.isEmpty { model.errorMessage = failures.joined(separator: "; ") } else { flash(tr("Attributes changed")) }
    }

    // MARK: - Alias and symbolic link

    /// Creates aliases or symbolic links to the selected items in the destination lister's folder, or
    /// next to the originals when there is no destination.
    func makeLinks(symbolic: Bool) {
        if refuseInArchive(symbolic ? tr("Make Symbolic Link") : tr("Make Alias")) { return }
        if remoteUnavailable(tr("Aliases and links")) { return }
        let urls = model.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        let manager = ListerManager.shared
        let folder = manager.destinationController.flatMap { $0.model !== model ? $0.model.url : nil }
        let result = LinkMaker.make(symbolic: symbolic ? true : false, items: urls, in: folder)
        let shown = [model.url] + (folder.map { [$0] } ?? [])
        manager.reloadListers(showing: shown)
        if !result.failures.isEmpty { model.errorMessage = result.failures.joined(separator: "; ") }
    }
}

extension ListerViewController {
    /// Test helper: selects the rows showing these URLs.
    func setSelectionForSheetTest(_ urls: [URL]) { select(urls: Set(urls)) }
}
