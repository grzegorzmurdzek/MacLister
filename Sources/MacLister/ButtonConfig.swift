import AppKit

/// What a bottom-bar button does.
enum ListerAction: String, Codable, CaseIterable, Identifiable {
    case newFolder, newTextFile, terminalHere, delete, parent, back, refresh
    /// Renames the selected item in its row (a disk too, when the volume allows it); eject unmounts the selected disks.
    case rename, eject
    case revealInFinder, open, newLister, toggleHidden
    /// Source → destination lister (see the SRC / DST toggles in the path bar).
    case copy, move, copyAs, moveAs, setSource, setDestination, swapSourceDestination
    /// Unpacks the selected archives (zip, tar.*, tgz, 7z, rar, gz, bz2 …) into a sub-folder of the
    /// destination lister's folder, or of the current folder when no destination is set.
    case extract
    /// Raises every open lister above all other windows.
    case bringAllToFront
    // Directory Opus style tools
    case duplicateLister, duplicateFile
    case selectPattern, deselectPattern, selectAll, selectNone, invertSelection
    case filter, clearFilter, calcSizes, compare, info
    /// Compares the source and destination folders and copies what differs (see the preview first).
    case synchronize
    /// Searches the folder and everything below it (Spotlight, or the folders themselves); the results are a list.
    case find
    /// Shows or hides the directory tree beside the file list.
    case toggleTree
    /// Remembers this window's size and position and the sort order for the folder it shows; forgetSnapshot removes it.
    case snapshot, forgetSnapshot
    /// MD5, SHA-1, SHA-256 and SHA-512 of the selected files, with a field to compare with a checksum you were given.
    case checksums
    /// Looks for files with the same content below a folder; you choose which copies go to the Trash.
    case findDuplicates
    /// Shows every file below this folder as one list; the same action leaves it again.
    case flatView
    case showInDestination, destinationHere, addBookmark
    case makeAlias, makeSymlink, selectByAttributes, toggleRoleLock, batchRename, attributes, connectToServer
    /// Gives this lister a name and colour of your own.
    case nameLister
    /// Show the lists of recently opened files, of what is shared on the network and of the disks (devices) of this Mac.
    case showRecents, showShared, showDevices
    /// Goes to the folder in the button's `command` (~ is the home folder): a Home, Desktop or Downloads button.
    case goToFolder
    /// Takes back the last copy, move, duplicate or Move to Trash; shows the operation log.
    case undo, showLog
    /// Moves the keyboard focus to the next / previous lister (Tab / Shift-Tab).
    case nextLister, previousLister
    /// Tabs (Settings → Tabs): a new tab on this folder, the next / previous tab, a tab out into a window of its own,
    /// every lister window into tabs of one.
    case newTab, nextTab, previousTab, moveTabToNewLister, mergeListers
    /// Two-panel windows: a new one, this lister and its partner joined into one, a two-panel window split into listers.
    case newTwoPanel, joinTwoPanel, splitTwoPanel
    /// This lister becomes the left pane of a two-panel window; the right pane opens in the same folder.
    case expandToTwoPanel
    /// Turns a two-panel window back into a single lister, keeping the SRC (or active) pane.
    case collapseToSinglePanel
    /// Shows the files as icons, or as a list again.
    case toggleIconView
    /// A menu under the button to choose what the files are grouped by (Finder's Group By).
    case groupBy
    /// Brings every lister to the macOS desktop (Space) you are on.
    case gatherListers
    /// A thin divider between groups of buttons (no action).
    case separator
    /// Runs `command` with /bin/zsh in the current folder.
    /// Codes: {f} {F} {o} {O} {df} {dF} {do} {dO} {d} {s} (see FiletypeCommand), quoted for the shell.
    /// Environment: LISTER_DIR (current folder), LISTER_SELECTION (selected paths, newline separated).
    case shell

    var id: String { rawValue }

    var needsSelection: Bool {
        switch self {
        case .delete, .open, .extract, .duplicateFile: return true
        default: return false
        }
    }
}

/// One entry of the configurable bottom bar (see buttons.json).
struct ListerButton: Codable, Hashable {
    var title: String
    var symbol: String?            // SF Symbol name, optional
    var action: ListerAction
    var command: String?           // for action == .shell (the command) and .goToFolder (the folder)
    var requiresSelection: Bool?   // overrides the action's default
    var help: String?              // tooltip
    var color: String?             // icon tint: blue green orange red purple teal pink yellow brown gray (default: neutral)
    /// What the right and the middle mouse button do on this button (Directory Opus 5 style); nothing when absent.
    var rightAction: ListerAction?
    var rightCommand: String?      // only for rightAction == .shell
    var middleAction: ListerAction?
    var middleCommand: String?     // only for middleAction == .shell
    /// Your own picture instead of the SF Symbol: the name of a file in ~/Library/Application Support/MacLister/ButtonIcons.
    var iconFile: String?
    /// More actions, in a menu that opens when you hold the button down (or click its arrow, see Settings → Buttons).
    /// A plain click still does `action`. Entries are buttons too (title, icon, action, command); a separator entry
    /// draws a line. Entries of an entry are not used.
    var menu: [ListerButton]?

    enum Click { case left, right, middle }

    var hasMenu: Bool { !(menu ?? []).isEmpty }

    /// What an entry of a button's menu is called: its own title, or the name of its action.
    var menuTitle: String { tr(title.isEmpty ? action.title : title) }

    /// The button as it acts for a click with the given mouse button; nil when that button has no job here.
    func variant(for click: Click) -> ListerButton? {
        switch click {
        case .left: return self
        case .right:
            guard let rightAction, rightAction != .separator else { return nil }
            return ListerButton(title: title, symbol: symbol, action: rightAction, command: rightCommand)
        case .middle:
            guard let middleAction, middleAction != .separator else { return nil }
            return ListerButton(title: title, symbol: symbol, action: middleAction, command: middleCommand)
        }
    }

    var hasExtraClicks: Bool { variant(for: .right) != nil || variant(for: .middle) != nil }

    /// "Right-click: Move · Middle-click: Info", added to the tooltip.
    var clickHelp: String {
        var parts: [String] = []
        if let right = variant(for: .right) { parts.append(tr("Right-click: %@", right.action.title)) }
        if let middle = variant(for: .middle) { parts.append(tr("Middle-click: %@", middle.action.title)) }
        if hasMenu { parts.append(tr("Hold: more actions")) }
        return parts.joined(separator: " · ")
    }

    var needsSelection: Bool { requiresSelection ?? action.needsSelection }

    /// The first button of the bar: the list of disks (and the usual folders), with eject in its context menu.
    static let showDevicesButton = ListerButton(title: "Show devices", symbol: "externaldrive.fill", action: .showDevices,
                                                help: "List the disks of this Mac and the usual folders; right-click a disk to eject it", color: "gray")

    /// Goes to the home folder with one click (the Home button of the default bar).
    static let homeButton = ListerButton(title: "Home folder", symbol: "house.fill", action: .goToFolder, command: "~",
                                         help: "Go to your home folder", color: "gray")

    /// Short on purpose: the rest (select, filter, sizes, duplicate lister, swap …) lives in the context and
    /// title-bar menus and in keyboard shortcuts, and can be added back through buttons.json.
    static let defaults: [ListerButton] = [
        showDevicesButton,
        homeButton,
        ListerButton(title: "New Folder", symbol: "folder.fill.badge.plus", action: .newFolder, help: "Create a folder here", color: "blue"),
        ListerButton(title: "New Text File", symbol: "doc.badge.plus", action: .newTextFile, help: "Create a text file here and open it in your text editor", color: "green"),
        ListerButton(title: "Terminal Here", symbol: "terminal.fill", action: .terminalHere, help: "Open a terminal in this folder", color: "gray"),
        ListerButton(title: "", symbol: nil, action: .separator),
        ListerButton(title: "Copy", symbol: "doc.on.doc.fill", action: .copy, help: "Copy the source selection to the destination lister (F5)", color: "blue"),
        ListerButton(title: "Move", symbol: "arrowshape.turn.up.right.fill", action: .move, help: "Move the source selection to the destination lister (F6)", color: "orange"),
        ListerButton(title: "Extract", symbol: "archivebox.fill", action: .extract, help: "Unpack the selected archives (⌘E)", color: "brown"),
        ListerButton(title: "Compare", symbol: "arrow.left.arrow.right.circle.fill", action: .compare, help: "Select differences between source and destination", color: "purple"),
        ListerButton(title: "", symbol: nil, action: .separator),
        ListerButton(title: "Info", symbol: "info.circle.fill", action: .info, help: "Size, dates, permissions (⌘I)", color: "teal"),
        ListerButton(title: "Delete", symbol: "trash.fill", action: .delete, help: "Move the selection to the Trash", color: "red"),
    ]
}

/// Loads the bottom-bar layout from ~/Library/Application Support/MacLister/buttons.json
/// (created with defaults on first run). Editing the file + "Reload Buttons" updates all open listers.
final class ButtonStore: ObservableObject {
    static let shared = ButtonStore()

    @Published private(set) var buttons: [ListerButton] = ListerButton.defaults

    static var configURL: URL {
        AppSupport.directory.appendingPathComponent("buttons.json")
    }

    private init() { reload() }

    /// Remembers that Show devices was put at the front of a saved bar once, so removing it later sticks.
    static let showDevicesMigrationKey = "buttonsShowDevicesAdded"

    /// `buttons` with Show devices as the first button, or nil when the bar has it somewhere already (also in a menu).
    static func addingShowDevices(to buttons: [ListerButton]) -> [ListerButton]? {
        func has(_ list: [ListerButton]) -> Bool { list.contains { $0.action == .showDevices || has($0.menu ?? []) } }
        return has(buttons) ? nil : [ListerButton.showDevicesButton] + buttons
    }

    /// Remembers that the Home button was added to a saved bar once, so removing it later sticks.
    static let homeMigrationKey = "buttonsHomeAdded"

    /// `buttons` with the Home button after Show devices (else first), or nil when the bar has a Go to folder button already.
    static func addingHome(to buttons: [ListerButton]) -> [ListerButton]? {
        func has(_ list: [ListerButton]) -> Bool { list.contains { $0.action == .goToFolder || has($0.menu ?? []) } }
        guard !has(buttons) else { return nil }
        var result = buttons
        result.insert(ListerButton.homeButton, at: (buttons.firstIndex { $0.action == .showDevices }).map { $0 + 1 } ?? 0)
        return result
    }

    /// A bar saved by an earlier version gets Show devices as its first button and a Home button after it, once each.
    private func migrateShowDevices(at url: URL) {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.showDevicesMigrationKey) {
            defaults.set(true, forKey: Self.showDevicesMigrationKey)
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ListerButton].self, from: data),
               let updated = Self.addingShowDevices(to: saved), let encoded = try? encode(updated) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
        guard !defaults.bool(forKey: Self.homeMigrationKey) else { return }
        defaults.set(true, forKey: Self.homeMigrationKey)
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ListerButton].self, from: data),
              let updated = Self.addingHome(to: saved), let encoded = try? encode(updated) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    /// Writes the default file if there is none yet.
    func ensureConfigFileExists() {
        let url = Self.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { migrateShowDevices(at: url); return }
        UserDefaults.standard.set(true, forKey: Self.showDevicesMigrationKey)      // the defaults have both already
        UserDefaults.standard.set(true, forKey: Self.homeMigrationKey)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(ListerButton.defaults).write(to: url, options: .atomic)
        } catch {
            NSLog("[MacLister] cannot write default buttons.json: %@", error.localizedDescription)
        }
    }

    /// Writes a new button layout (from the button editor) and applies it to every lister.
    func save(_ buttons: [ListerButton]) {
        do {
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(buttons).write(to: Self.configURL, options: .atomic)
        } catch {
            NSLog("[MacLister] cannot write buttons.json: %@", error.localizedDescription)
        }
        reload()
    }

    /// Overwrites buttons.json with the built-in defaults (new releases add buttons that an old file lacks).
    func resetToDefaults() {
        do {
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(ListerButton.defaults).write(to: Self.configURL, options: .atomic)
        } catch {
            NSLog("[MacLister] cannot reset buttons.json: %@", error.localizedDescription)
        }
        reload()
    }

    func reload() {
        ensureConfigFileExists()
        do {
            let data = try Data(contentsOf: Self.configURL)
            buttons = try JSONDecoder().decode([ListerButton].self, from: data)
        } catch {
            // Keep whatever is loaded (defaults on first run) rather than wiping the bar on a typo.
            NSLog("[MacLister] buttons.json not applied: %@", String(describing: error))
        }
    }

    private func encode(_ buttons: [ListerButton]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(buttons)
    }
}

extension ListerAction {
    /// The icon (an SF Symbol: one of the icons that ship with macOS) a button gets when you choose this action.
    var suggestedSymbol: String {
        switch self {
        case .newFolder: return "folder.fill.badge.plus"
        case .newTextFile: return "doc.badge.plus"
        case .terminalHere, .shell: return "terminal.fill"
        case .delete: return "trash.fill"
        case .parent: return "arrow.up.circle.fill"
        case .back: return "chevron.backward.circle.fill"
        case .refresh: return "arrow.clockwise.circle.fill"
        case .revealInFinder: return "magnifyingglass.circle.fill"
        case .open: return "arrow.up.forward.app.fill"
        case .newLister, .duplicateLister: return "macwindow.badge.plus"
        case .toggleHidden: return "eye.circle.fill"
        case .copy, .copyAs, .duplicateFile: return "doc.on.doc.fill"
        case .move, .moveAs: return "arrowshape.turn.up.right.fill"
        case .setSource, .setDestination, .swapSourceDestination, .showInDestination, .destinationHere: return "arrow.left.arrow.right.circle.fill"
        case .extract: return "archivebox.fill"
        case .bringAllToFront, .gatherListers: return "rectangle.on.rectangle"
        case .selectPattern, .deselectPattern, .selectAll, .selectNone, .invertSelection, .selectByAttributes: return "checkmark.circle.fill"
        case .filter, .clearFilter: return "line.3.horizontal.decrease.circle.fill"
        case .calcSizes: return "externaldrive.fill"
        case .compare: return "arrow.left.arrow.right.circle.fill"
        case .synchronize: return "arrow.triangle.2.circlepath.circle.fill"
        case .info: return "info.circle.fill"
        case .find: return "magnifyingglass"
        case .toggleTree: return "sidebar.left"
        case .snapshot, .forgetSnapshot: return "camera.fill"
        case .checksums: return "number.circle.fill"
        case .findDuplicates: return "square.on.square"
        case .flatView: return "list.bullet.indent"
        case .addBookmark: return "bookmark.fill"
        case .makeAlias, .makeSymlink: return "link.circle.fill"
        case .toggleRoleLock: return "lock.fill"
        case .batchRename, .attributes, .nameLister: return "pencil.circle.fill"
        case .connectToServer, .showShared: return "network"
        case .showRecents: return "clock.fill"
        case .showDevices: return "externaldrive.fill"
        case .goToFolder: return "house.fill"
        case .toggleIconView: return "square.grid.2x2"
        case .groupBy: return "square.grid.3x1.below.line.grid.1x2"
        case .eject: return "eject.fill"
        case .rename: return "pencil"
        case .undo: return "arrow.uturn.backward.circle.fill"
        case .showLog: return "list.bullet.rectangle.fill"
        case .nextLister: return "arrow.right.circle.fill"
        case .previousLister: return "arrow.left.circle.fill"
        case .newTab: return "plus.square.on.square"
        case .nextTab: return "chevron.right.square.fill"
        case .previousTab: return "chevron.left.square.fill"
        case .moveTabToNewLister: return "macwindow.on.rectangle"
        case .mergeListers: return "square.stack.fill"
        case .newTwoPanel: return "rectangle.split.2x1"
        case .joinTwoPanel: return "rectangle.split.2x1.fill"
        case .splitTwoPanel: return "rectangle.on.rectangle"
        case .expandToTwoPanel: return "rectangle.split.2x1"
        case .collapseToSinglePanel: return "rectangle"
        case .separator: return "minus"
        }
    }
}

/// Groups for the action chooser of the button editor.
enum ActionCategory: CaseIterable {
    case files, transfer, selecting, navigation, listers, other

    var title: String {
        switch self {
        case .files: return tr("Files and folders")
        case .transfer: return tr("Copy, move and compare")
        case .selecting: return tr("Select, filter and find")
        case .navigation: return tr("Navigation")
        case .listers: return tr("Listers")
        case .other: return tr("Other")
        }
    }
}

extension ListerAction {
    var category: ActionCategory {
        switch self {
        case .newFolder, .newTextFile, .delete, .open, .rename, .eject, .revealInFinder, .duplicateFile, .makeAlias, .makeSymlink, .batchRename, .attributes, .info, .checksums, .extract, .calcSizes:
            return .files
        case .copy, .move, .copyAs, .moveAs, .compare, .synchronize, .showInDestination, .destinationHere, .undo, .showLog:
            return .transfer
        case .selectPattern, .deselectPattern, .selectAll, .selectNone, .invertSelection, .selectByAttributes,
             .filter, .clearFilter, .find, .findDuplicates, .flatView, .toggleHidden, .refresh:
            return .selecting
        case .parent, .back, .toggleTree, .addBookmark, .snapshot, .forgetSnapshot, .showRecents, .showShared, .showDevices, .goToFolder, .toggleIconView, .groupBy, .connectToServer:
            return .navigation
        case .newLister, .duplicateLister, .setSource, .setDestination, .swapSourceDestination, .toggleRoleLock, .nameLister,
             .nextLister, .previousLister, .bringAllToFront, .gatherListers,
             .newTab, .nextTab, .previousTab, .moveTabToNewLister, .mergeListers,
             .newTwoPanel, .joinTwoPanel, .splitTwoPanel, .expandToTwoPanel, .collapseToSinglePanel:
            return .listers
        case .terminalHere, .shell, .separator:
            return .other
        }
    }
}

/// Pictures chosen as button icons. They are copied (scaled down to at most 128 points, as PNG) into the
/// ButtonIcons folder, so a button keeps its icon when the original is moved or deleted.
enum ButtonIcons {
    static var directory: URL { AppSupport.directory.appendingPathComponent("ButtonIcons", isDirectory: true) }
    private static var cache: [String: NSImage] = [:]

    /// The picture of a file name, or nil when there is none or it cannot be read.
    static func image(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }
        if let cached = cache[name] { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        cache[name] = image
        return image
    }

    /// Copies `source` into the folder and returns the new file name; nil when it is not a readable picture.
    static func importImage(from source: URL) -> String? {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 128 / max(image.size.width, image.size.height))
        let target = NSSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        // twice the points: sharp on Retina displays
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width * 2), pixelsHigh: Int(target.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { return nil }
        return name
    }

    static func remove(_ name: String?) {
        guard let name, !name.contains("/") else { return }
        cache[name] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
