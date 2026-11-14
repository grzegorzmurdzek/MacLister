import Foundation

/// What a bottom-bar button does.
enum ListerAction: String, Codable, CaseIterable, Identifiable {
    case newFolder, terminalHere, delete, parent, back, refresh
    case revealInFinder, open, newLister, toggleHidden
    /// Source → destination lister (see the SRC / DST toggles in the path bar).
    case copy, move, setSource, setDestination, swapSourceDestination
    /// Unpacks the selected archives (zip, tar.*, tgz, 7z, rar, gz, bz2 …) into a sub-folder of the
    /// destination lister's folder, or of the current folder when no destination is set.
    case extract
    /// Raises every open lister above all other windows.
    case bringAllToFront
    // Directory Opus style tools
    case duplicateLister, duplicateFile
    case selectPattern, deselectPattern, selectAll, selectNone, invertSelection
    case filter, clearFilter, calcSizes, compare, info
    case showInDestination, destinationHere, addBookmark
    case makeAlias, makeSymlink, selectByAttributes, toggleRoleLock, batchRename, attributes, connectToServer
    /// Gives this lister a name and colour of your own.
    case nameLister
    /// Show the lists of recently opened files and of what is shared on the network.
    case showRecents, showShared
    /// Takes back the last copy, move, duplicate or Move to Trash; shows the operation log.
    case undo, showLog
    /// Moves the keyboard focus to the next / previous lister (Tab / Shift-Tab).
    case nextLister, previousLister
    /// A thin divider between groups of buttons (no action).
    case separator
    /// Runs `command` with /bin/zsh in the current folder.
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
    var command: String?           // only for action == .shell
    var requiresSelection: Bool?   // overrides the action's default
    var help: String?              // tooltip
    var color: String?             // icon tint: blue green orange red purple teal pink yellow brown gray (default: neutral)
    /// What the right and the middle mouse button do on this button (Directory Opus 5 style); nothing when absent.
    var rightAction: ListerAction?
    var rightCommand: String?      // only for rightAction == .shell
    var middleAction: ListerAction?
    var middleCommand: String?     // only for middleAction == .shell

    enum Click { case left, right, middle }

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
        return parts.joined(separator: " · ")
    }

    var needsSelection: Bool { requiresSelection ?? action.needsSelection }

    /// Short on purpose: the rest (select, filter, sizes, duplicate lister, swap …) lives in the context and
    /// title-bar menus and in keyboard shortcuts, and can be added back through buttons.json.
    static let defaults: [ListerButton] = [
        ListerButton(title: "New Folder", symbol: "folder.fill.badge.plus", action: .newFolder, help: "Create a folder here", color: "blue"),
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

    /// Writes the default file if there is none yet.
    func ensureConfigFileExists() {
        let url = Self.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
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
