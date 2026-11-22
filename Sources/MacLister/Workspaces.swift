import AppKit

/// Workspace: a named layout of listers (folders, windows, tabs, two-panel windows, roles, sorting…), kept next to
/// the one "last session" layout of Save Layout / Restore Layout. Any number of them can be saved and opened later;
/// they are only ever changed by you.
struct Workspace: Codable, Identifiable {
    var id: UUID
    var name: String
    var listers: [ListerSnapshot]
    var modified: Date
    /// The look that is shared by all listers (nil: the workspace leaves it as it is).
    var view: WorkspaceView?

    /// Folders of the layout that do not exist (any more).
    var missingFolders: [String] {
        listers.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) }
    }
}

/// The settings of how listers look that are not per lister: the columns of the list, their widths, the icon size.
/// (Icons or list is kept for each lister in its snapshot.)
struct WorkspaceView: Codable, Equatable {
    var columns: [String]
    var widths: [String: Double]
    var iconSize: Double

    static func current() -> WorkspaceView {
        WorkspaceView(columns: ColumnSettings.visible.filter { $0 != .name }.map(\.rawValue),
                      widths: ColumnSettings.widths, iconSize: Double(Settings.iconSize))
    }

    /// Makes these the settings of the app (listers that are open follow; new ones start with them).
    func apply() {
        Settings.iconSize = CGFloat(iconSize)
        ColumnSettings.widths = widths
        ColumnSettings.setVisible(columns.compactMap(ListerColumn.init(rawValue:)))
    }
}

final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [Workspace] = []
    private var file: URL { AppSupport.directory.appendingPathComponent("workspaces.json") }

    private init() { load() }

    func workspace(id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func workspace(named name: String) -> Workspace? {
        let wanted = Self.clean(name).lowercased()
        return workspaces.first { $0.name.lowercased() == wanted }
    }

    static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `base` if no workspace has that name, else "base 2", "base 3"… (`excluding`: the workspace being renamed).
    func uniqueName(_ base: String, excluding: UUID? = nil) -> String {
        let root = Self.clean(base).isEmpty ? tr("Workspace") : Self.clean(base)
        let taken = Set(workspaces.filter { $0.id != excluding }.map { $0.name.lowercased() })
        if !taken.contains(root.lowercased()) { return root }
        var number = 2
        while taken.contains("\(root) \(number)".lowercased()) { number += 1 }
        return "\(root) \(number)"
    }

    /// The name offered for the next workspace.
    var suggestedName: String { uniqueName(tr("Workspace %d", workspaces.count + 1)) }

    @discardableResult
    func add(name: String, listers: [ListerSnapshot]) -> Workspace {
        let workspace = Workspace(id: UUID(), name: uniqueName(name), listers: listers, modified: Date(), view: WorkspaceView.current())
        workspaces.append(workspace)
        save()
        return workspace
    }

    /// Saves the open listers as a new workspace.
    @discardableResult
    func addCurrent(name: String, from manager: ListerManager) -> Workspace {
        add(name: name, listers: LayoutStore.capture(from: manager))
    }

    /// Replaces the listers of a workspace with the open ones.
    func update(_ id: UUID, from manager: ListerManager) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].listers = LayoutStore.capture(from: manager)
        workspaces[index].view = WorkspaceView.current()
        workspaces[index].modified = Date()
        save()
    }

    /// false: the name is empty or another workspace has it.
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let clean = Self.clean(name)
        guard !clean.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces.contains(where: { $0.id != id && $0.name.lowercased() == clean.lowercased() }) else { return false }
        workspaces[index].name = clean
        save()
        return true
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Workspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = workspaces[index]
        copy.id = UUID()
        copy.name = uniqueName(tr("%@ copy", copy.name))
        copy.modified = Date()
        workspaces.insert(copy, at: index + 1)
        save()
        return copy
    }

    func remove(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if Settings.startupWorkspaceID == id.uuidString { Settings.startupWorkspaceID = "" }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        let moving = source.map { workspaces[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { workspaces.remove(at: index) }
        workspaces.insert(contentsOf: moving, at: destination - before)
        save()
    }

    /// Opens a workspace. `replace`: the open listers are closed first; otherwise it comes in addition to them.
    /// `applyView`: the columns and icon size of the workspace become the app's (by default when it replaces the listers:
    /// listers that stay open would change their look under you). Returns how many listers were opened.
    @discardableResult
    func open(_ id: UUID, replace: Bool, applyView: Bool? = nil, into manager: ListerManager = .shared) -> Int {
        guard let workspace = workspace(id: id) else { return 0 }
        if replace { manager.closeAll() }
        if applyView ?? replace { workspace.view?.apply() }
        return LayoutStore.open(workspace.listers, into: manager)
    }

    /// Re-reads the file (tests switch the support folder).
    func reload() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { workspaces = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([Workspace].self, from: data) {
            workspaces = saved
        } else {
            // not readable: keep the file as it is for a look, and do not overwrite it with an empty list unnoticed
            let backup = file.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: file, to: backup)
            NSLog("[MacLister] workspaces.json not readable, a copy is in %@", backup.path)
            workspaces = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(workspaces) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Menus and asking for a name

/// What the Workspaces menus do. One target for every menu (menu bar, Dock, title bar of a lister).
final class WorkspaceActions: NSObject {
    static let shared = WorkspaceActions()

    private struct Choice { let id: UUID; let replace: Bool }

    /// Fills `menu` with the workspaces (a click opens one in place of the open listers, ⌥-click adds it to them),
    /// then Save and Manage.
    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = WorkspaceStore.shared
        for workspace in store.workspaces {
            let open = NSMenuItem(title: workspace.name, action: #selector(openWorkspace(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = Choice(id: workspace.id, replace: true)
            menu.addItem(open)
            let add = NSMenuItem(title: tr("Add “%@” to Open Listers", workspace.name), action: #selector(openWorkspace(_:)), keyEquivalent: "")
            add.target = self
            add.keyEquivalentModifierMask = .option
            add.isAlternate = true
            add.representedObject = Choice(id: workspace.id, replace: false)
            menu.addItem(add)
        }
        if store.workspaces.isEmpty {
            let none = NSMenuItem(title: tr("No workspaces"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let save = NSMenuItem(title: tr("Save Open Listers as Workspace…"), action: #selector(saveCurrent), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        let manage = NSMenuItem(title: tr("Manage Workspaces…"), action: #selector(manage), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        WorkspaceStore.shared.open(choice.id, replace: choice.replace)
    }

    @objc func saveCurrent() {
        guard ListerManager.shared.openCount > 0 else { return }
        guard let name = Self.askName(title: tr("Save Open Listers as Workspace"),
                                      message: tr("The folders, windows, tabs and roles of the open listers are saved under this name."),
                                      initial: WorkspaceStore.shared.suggestedName, button: tr("Save")) else { return }
        WorkspaceStore.shared.addCurrent(name: name, from: ListerManager.shared)
    }

    @objc func manage() { SettingsWindow.show(tab: SettingsWindow.workspacesTab) }

    /// A small window asking for a name; nil when cancelled or left empty.
    static func askName(title: String, message: String, initial: String, button: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: tr("Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.bringToFront()
        field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = WorkspaceStore.clean(field.stringValue)
        return name.isEmpty ? nil : name
    }
}
