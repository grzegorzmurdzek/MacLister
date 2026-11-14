import Foundation

/// What a bottom-bar button does.
enum ListerAction: String, Codable {
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
    /// Runs `command` with /bin/zsh in the current folder.
    /// Environment: LISTER_DIR (current folder), LISTER_SELECTION (selected paths, newline separated).
    case shell

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

    var needsSelection: Bool { requiresSelection ?? action.needsSelection }

    static let defaults: [ListerButton] = [
        ListerButton(title: "New Folder", symbol: "folder.badge.plus", action: .newFolder, help: "Create a folder here"),
        ListerButton(title: "Terminal Here", symbol: "terminal", action: .terminalHere, help: "Open a terminal in this folder"),
        ListerButton(title: "Copy", symbol: "doc.on.doc", action: .copy, help: "Copy the source selection to the destination lister (F5)"),
        ListerButton(title: "Move", symbol: "folder", action: .move, help: "Move the source selection to the destination lister (F6)"),
        ListerButton(title: "Extract", symbol: "archivebox", action: .extract, help: "Unpack the selected archives (⌘E)"),
        ListerButton(title: "Select", symbol: "checkmark.circle", action: .selectPattern, help: "Select files by pattern (+)"),
        ListerButton(title: "Filter", symbol: "line.3.horizontal.decrease.circle", action: .filter, help: "Show only files matching a pattern (⌘F)"),
        ListerButton(title: "Sizes", symbol: "sum", action: .calcSizes, help: "Calculate folder sizes"),
        ListerButton(title: "Compare", symbol: "arrow.triangle.2.circlepath", action: .compare, help: "Select differences between source and destination"),
        ListerButton(title: "Info", symbol: "info.circle", action: .info, help: "Size, dates, permissions (⌘I)"),
        ListerButton(title: "Duplicate", symbol: "square.on.square", action: .duplicateLister, help: "Open another lister on this folder (⌥⌘D)"),
        ListerButton(title: "Swap", symbol: "arrow.left.arrow.right", action: .swapSourceDestination, help: "Swap source and destination"),
        ListerButton(title: "Reveal", symbol: "magnifyingglass", action: .revealInFinder, help: "Show in Finder"),
        ListerButton(title: "Delete", symbol: "trash", action: .delete, help: "Move the selection to the Trash"),
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
