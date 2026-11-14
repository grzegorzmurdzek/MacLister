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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacLister", isDirectory: true)
            .appendingPathComponent("buttons.json")
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
