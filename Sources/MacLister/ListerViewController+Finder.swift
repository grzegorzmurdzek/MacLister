import AppKit
import SwiftUI

/// Holds the closure of a menu item (NSMenuItem has no block API).
final class ClosureBox: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// What the Finder-style menu groups keep alive while a menu is open.
enum FinderMenuState {
    static var sharePicker: NSSharingServicePicker?
}

enum FinderServices {
    static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static var sendTypes: [NSPasteboard.PasteboardType] { [.fileURL, filenames] }

    /// Puts the files on the pasteboard the way Finder does for a service.
    static func write(_ urls: [URL], to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        var ok = pasteboard.writeObjects(urls as [NSURL])
        if types.contains(filenames) {
            ok = pasteboard.setPropertyList(urls.map(\.path), forType: filenames) || ok
        }
        return ok
    }
}

// MARK: - Colour dots (like the row of coloured circles in Finder's menu)

/// The row of seven coloured circles; clicking one toggles that colour tag on the selection.
final class TagColorRowView: NSView {
    static let diameter: CGFloat = 15
    static let gap: CGFloat = 9
    static let inset: CGFloat = 14

    /// Colour labels (1…7) that every selected item already has.
    var active: Set<Int> = [] { didSet { needsDisplay = true } }
    var onToggle: ((Int) -> Void)?

    static var width: CGFloat {
        let count = CGFloat(FinderTags.menuOrder.count)
        return inset * 2 + count * diameter + (count - 1) * gap
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Tag Colors"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func rect(at index: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(index) * (Self.diameter + Self.gap),
               y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
    }

    func label(at point: NSPoint) -> Int? {
        for (index, label) in FinderTags.menuOrder.enumerated()
        where rect(at: index).insetBy(dx: -Self.gap / 2, dy: -4).contains(point) { return label }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, label) in FinderTags.menuOrder.enumerated() {
            let circle = rect(at: index)
            let color = FinderTags.color(for: label)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            let outline = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            if active.contains(label) {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: circle.minX + 4, y: circle.midY))
                check.line(to: NSPoint(x: circle.minX + 6.5, y: circle.midY - 3))
                check.line(to: NSPoint(x: circle.maxX - 3.5, y: circle.midY + 3.5))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let label = label(at: convert(event.locationInWindow, from: nil)) else { return }
        onToggle?(label)
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Finder-style items of the context menu

extension ListerViewController {
    @objc func finderMenuItemChosen(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.run()
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @discardableResult
    private func addFinderItem(_ title: String, to menu: NSMenu, symbol name: String? = nil,
                               enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(finderMenuItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ClosureBox(run)
        item.isEnabled = enabled
        if let name { item.image = symbol(name) }
        menu.addItem(item)
        return item
    }

    /// "Share" with the system's own sharing submenu.
    func addShareItem(to menu: NSMenu, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        FinderMenuState.sharePicker = picker
        let item = picker.standardShareMenuItem
        item.title = tr("Share")
        if item.image == nil { item.image = symbol("square.and.arrow.up") }
        menu.addItem(item)
    }

    /// The row of colour dots and "Tags…".
    /// `tagsMenu`: where the "Tags…" item goes (a submenu); next to the dots when nil.
    func addTagItems(to menu: NSMenu, urls: [URL], tagsMenu: NSMenu? = nil) {
        guard !urls.isEmpty else { return }
        let row = TagColorRowView(frame: NSRect(x: 0, y: 0, width: TagColorRowView.width, height: 26))
        row.autoresizingMask = [.width]
        let perItem = urls.map { url in Set(FinderTags.entries(of: url).map(FinderTags.label(of:))) }
        row.active = Set(FinderTags.menuOrder.filter { label in perItem.allSatisfy { $0.contains(label) } })
        row.onToggle = { [weak self, weak menu] label in
            menu?.cancelTracking()
            DispatchQueue.main.async { self?.toggleTagColor(label, on: urls) }
        }
        let rowItem = NSMenuItem()
        rowItem.view = row
        rowItem.title = tr("Tag Colors")
        menu.addItem(rowItem)
        addFinderItem(tr("Tags…"), to: tagsMenu ?? menu, symbol: "tag") { [weak self] in self?.promptTags(for: urls) }
    }

    /// "Quick Actions": image actions and the user's Automator Quick Action workflows.
    func addQuickActions(to menu: NSMenu, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sub = NSMenu(title: tr("Quick Actions"))
        sub.autoenablesItems = false

        if QuickActions.allImages(urls) {
            addFinderItem(tr("Rotate Left"), to: sub, symbol: "rotate.left") { [weak self] in self?.rotateImages(urls, degrees: 270) }
            addFinderItem(tr("Rotate Right"), to: sub, symbol: "rotate.right") { [weak self] in self?.rotateImages(urls, degrees: 90) }
            addFinderItem(tr("Create PDF"), to: sub, symbol: "doc.richtext") { [weak self] in self?.createPDFs(urls) }
            let convert = NSMenuItem(title: tr("Convert Image"), action: nil, keyEquivalent: "")
            convert.image = symbol("photo.on.rectangle")
            let formats = NSMenu(title: convert.title)
            for format in QuickActions.formats {
                addFinderItem(format.title, to: formats) { [weak self] in self?.convertImages(urls, to: format) }
            }
            convert.submenu = formats
            sub.addItem(convert)
        }

        let workflows = QuickActions.workflows()
        if !workflows.isEmpty {
            if sub.numberOfItems > 0 { sub.addItem(.separator()) }
            for workflow in workflows {
                addFinderItem(workflow.title, to: sub) { [weak self] in self?.runWorkflow(workflow, on: urls) }
            }
        }
        if sub.numberOfItems == 0 { addFinderItem(tr("No Quick Actions for this selection"), to: sub, enabled: false) { } }

        let parent = NSMenuItem(title: tr("Quick Actions"), action: nil, keyEquivalent: "")
        parent.image = symbol("gearshape")
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// "Services": the system fills it with the services that accept the selected files.
    func addServicesItem(to menu: NSMenu) {
        let services = NSMenu(title: tr("Services"))
        NSApp.servicesMenu = services
        let parent = NSMenuItem(title: tr("Services"), action: nil, keyEquivalent: "")
        parent.submenu = services
        menu.addItem(parent)
    }

    func addTrashItem(to menu: NSMenu, title: String, _ run: @escaping () -> Void) {
        addFinderItem(title, to: menu, symbol: "trash", run)
    }

    // MARK: Copy

    /// Puts the files on the pasteboard so they can be pasted in Finder, Mail …
    func copyFilesToPasteboard() {
        let urls = model.selectedURLs
        guard !urls.isEmpty, !isRemote else { NSSound.beep(); return }
        materialized(urls) { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            self?.flash(urls.count == 1 ? tr("Copied “%@”", urls[0].lastPathComponent) : trCount("Copied %d items", urls.count))
        }
    }

    // MARK: Compress

    func compressSelection() {
        if remoteUnavailable(tr("Compress")) { return }
        if refuseInArchive(tr("Compress")) { return }
        let urls = model.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = model.url
        model.statusMessage = tr("Compressing…")
        Compressor.compress(urls) { [weak self] result in
            guard let self else { return }
            self.model.statusMessage = nil
            var selecting: [ObjectIdentifier: URL] = [:]
            if let output = result.output, let controller = self.view.window?.windowController { selecting[ObjectIdentifier(controller)] = output }
            ListerManager.shared.reloadListers(showing: [folder], selecting: selecting)
            if let error = result.error { self.model.errorMessage = tr("Cannot compress: %@", error) }
        }
    }

    // MARK: Tags

    func toggleTagColor(_ label: Int, on urls: [URL]) {
        if remoteUnavailable(tr("Tags")) { return }
        let failures = FinderTags.toggle(label: label, on: urls)
        ListerManager.shared.reloadListers(showing: [model.url])
        if !failures.isEmpty { model.errorMessage = failures.joined(separator: "; ") }
    }

    func promptTags(for urls: [URL]) {
        if remoteUnavailable(tr("Tags")) { return }
        guard !urls.isEmpty, let window = view.window else { return }
        let state = TagsEditorState.make(for: urls, alsoSeen: rows.flatMap(\.tags))
        SheetPresenter().present(on: window, size: NSSize(width: 380, height: 440)) { close in
            TagsEditorView(state: state, title: urls.count == 1 ? urls[0].lastPathComponent : trCount("%d items", urls.count),
                           onApply: { [weak self] add, remove in self?.applyTags(add: add, remove: remove, to: urls) }, close: close)
        }
    }

    func applyTags(add: [FinderTags.Entry], remove: [FinderTags.Entry], to urls: [URL]) {
        let failures = FinderTags.apply(add: add, remove: remove, to: urls)
        ListerManager.shared.reloadListers(showing: [model.url])
        if !failures.isEmpty { model.errorMessage = failures.joined(separator: "; ") }
    }

    // MARK: Quick Actions

    func rotateImages(_ urls: [URL], degrees: Int) {
        runInBackground(tr("Rotating…")) { QuickActions.rotate(urls, degrees: degrees) }
    }

    func createPDFs(_ urls: [URL]) {
        runInBackground(tr("Creating PDF…")) { QuickActions.createPDFs(urls).failures }
    }

    func convertImages(_ urls: [URL], to format: QuickActions.ImageFormat) {
        runInBackground(tr("Converting…")) { QuickActions.convert(urls, to: format).failures }
    }

    func runWorkflow(_ workflow: QuickActions.Workflow, on urls: [URL]) {
        runInBackground(tr("Running “%@”…", workflow.title)) {
            QuickActions.run(workflow, on: urls).map { ["\(workflow.title): \($0)"] } ?? []
        }
    }

    /// Runs `work` off the main thread with a status message, then reloads and reports failures.
    func runInBackground(_ message: String, _ work: @escaping () -> [String]) {
        if remoteUnavailable(tr("Quick Actions")) { return }
        let folder = model.url
        model.statusMessage = message
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failures = work()
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.statusMessage = nil
                ListerManager.shared.reloadListers(showing: [folder])
                if !failures.isEmpty { self.model.errorMessage = failures.joined(separator: "; ") }
            }
        }
    }
}

// MARK: - Tags sheet

/// What the "Tags…" sheet shows: every candidate tag and how many of the selected items carry it.
struct TagsEditorState {
    struct Row: Identifiable {
        var entry: FinderTags.Entry
        var count: Int
        var id: String { entry.label > 0 ? "L\(entry.label)" : "N\(entry.name)" }
    }

    var rows: [Row]
    var total: Int

    static func matches(_ existing: FinderTags.Entry, _ candidate: FinderTags.Entry) -> Bool {
        candidate.label > 0 ? FinderTags.label(of: existing) == candidate.label : existing.name == candidate.name
    }

    static func make(for urls: [URL], alsoSeen names: [String]) -> TagsEditorState {
        let perItem = urls.map { FinderTags.entries(of: $0) }
        var candidates: [FinderTags.Entry] = FinderTags.menuOrder.map { FinderTags.Entry(name: FinderTags.name(for: $0), label: $0) }
        func consider(_ entry: FinderTags.Entry) {
            let label = FinderTags.label(of: entry)
            let normalised = label > 0 ? FinderTags.Entry(name: FinderTags.name(for: label), label: label) : entry
            if !candidates.contains(where: { matches(normalised, $0) }) { candidates.append(normalised) }
        }
        perItem.flatMap { $0 }.forEach(consider)
        for name in Set(names).sorted() { consider(FinderTags.Entry(name: name, label: 0)) }
        let rows = candidates.map { candidate in
            TagsEditorState.Row(entry: candidate, count: perItem.filter { $0.contains { matches($0, candidate) } }.count)
        }
        return TagsEditorState(rows: rows, total: urls.count)
    }
}

struct TagsEditorView: View {
    let state: TagsEditorState
    let title: String
    let onApply: ([FinderTags.Entry], [FinderTags.Entry]) -> Void
    let close: () -> Void

    /// The user's decision per tag: true add, false remove; absent: leave as it is.
    @State private var decisions: [String: Bool] = [:]
    @State private var extra: [TagsEditorState.Row] = []
    @State private var newName = ""
    @State private var newLabel = 0

    private var allRows: [TagsEditorState.Row] { state.rows + extra }

    private func isOn(_ row: TagsEditorState.Row) -> Bool? {
        if let decided = decisions[row.id] { return decided }
        if row.count == state.total { return true }
        return row.count == 0 ? false : nil          // nil: some of the items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags").font(.title3.bold())
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

            List(allRows) { row in
                Button {
                    decisions[row.id] = isOn(row) != true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOn(row) == true ? "checkmark.square.fill" : (isOn(row) == nil ? "minus.square.fill" : "square"))
                            .foregroundStyle(isOn(row) == false ? Color.secondary : Color.accentColor)
                        Circle()
                            .fill(row.entry.label > 0 ? Color(nsColor: FinderTags.color(for: row.entry.label)) : Color.clear)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: row.entry.label > 0 ? 0 : 1))
                            .frame(width: 12, height: 12)
                        Text(row.entry.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 200)

            HStack {
                TextField("New tag", text: $newName).textFieldStyle(.roundedBorder).onSubmit(addNew)
                Picker("", selection: $newLabel) {
                    Text("No color").tag(0)
                    ForEach(FinderTags.menuOrder, id: \.self) { Text(FinderTags.name(for: $0)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
                Button("Add", action: addNew).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 440)
    }

    private func addNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let entry = FinderTags.Entry(name: newLabel > 0 ? FinderTags.name(for: newLabel) : name, label: newLabel)
        let row = TagsEditorState.Row(entry: entry, count: 0)
        if !allRows.contains(where: { $0.id == row.id }) { extra.append(row) }
        decisions[row.id] = true
        newName = ""
    }

    private func apply() {
        var add: [FinderTags.Entry] = [], remove: [FinderTags.Entry] = []
        for row in allRows {
            guard let decided = decisions[row.id] else { continue }
            if decided { add.append(row.entry) } else { remove.append(row.entry) }
        }
        onApply(add, remove)
        close()
    }
}
