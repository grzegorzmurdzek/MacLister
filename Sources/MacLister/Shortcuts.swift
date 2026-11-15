import AppKit
import Carbon

// MARK: - A key combination

struct KeyCombo: Codable, Hashable {
    var keyCode: Int
    var modifiers: Int          // raw NSEvent.ModifierFlags, limited to ⌘ ⌥ ⌃ ⇧
    var label: String           // "L", "F5", "Space": stored, so it does not depend on the current keyboard layout

    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, label: String) {
        self.keyCode = keyCode
        self.modifiers = Int(modifiers.intersection(Self.mask).rawValue)
        self.label = label
    }

    init(event: NSEvent) {
        self.init(keyCode: Int(event.keyCode), modifiers: event.modifierFlags, label: KeyLabels.label(for: event))
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(modifiers)) }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + label
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == Int(event.keyCode) && flags == event.modifierFlags.intersection(Self.mask)
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    /// Function keys and arrows work without a modifier; letters, digits and punctuation need one.
    var isFunctionKey: Bool { KeyLabels.functionKeyCodes.contains(keyCode) }
    var hasMainModifier: Bool { !flags.intersection([.command, .option, .control]).isEmpty }
}

enum KeyLabels {
    static let special: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 71: "Clear", 76: "Enter",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static func label(for event: NSEvent) -> String {
        if let name = special[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

// MARK: - What the user has assigned

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("MacListerShortcutsChanged")
}

/// ids: "action.<ListerAction>" for shortcuts inside listers, "global.<name>" for shortcuts that work in any app.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var bindings: [String: KeyCombo] = [:]
    private var file: URL { AppSupport.directory.appendingPathComponent("shortcuts.json") }

    private init() { load() }

    func combo(for id: String) -> KeyCombo? { bindings[id] }

    func id(using combo: KeyCombo) -> String? { bindings.first { $0.value == combo }?.key }

    /// The action bound to a key press inside a lister.
    func action(for event: NSEvent) -> ListerAction? {
        for (id, combo) in bindings where id.hasPrefix("action.") && combo.matches(event) {
            return ListerAction(rawValue: String(id.dropFirst("action.".count)))
        }
        return nil
    }

    func set(_ combo: KeyCombo?, for id: String) {
        if let combo { bindings[id] = combo } else { bindings[id] = nil }
        save()
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    func reload() { load(); NotificationCenter.default.post(name: .shortcutsChanged, object: nil) }

    private func load() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            bindings = saved
        } else {
            bindings = [:]
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(bindings).write(to: file, options: .atomic)
    }
}

// MARK: - What is already taken

/// A shortcut that macOS itself uses (System Settings → Keyboard → Keyboard Shortcuts).
struct SystemShortcut: Equatable {
    var keyCode: Int
    var modifiers: Int
    var name: String
}

enum SystemShortcuts {
    /// The enabled "symbolic hot keys" of the current user: Spotlight, Mission Control, screenshots,
    /// switching Spaces, input sources and so on, with their current (possibly customised) keys.
    static func enabled() -> [SystemShortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var found: [SystemShortcut] = []
        for entry in list {
            guard entry["kHISymbolicHotKeyEnabled"] as? Bool == true,
                  let code = entry["kHISymbolicHotKeyCode"] as? Int, code != 65535 else { continue }
            let raw = (entry["kHISymbolicHotKeyModifiers"] as? Int) ?? 0
            let modifiers = Int(NSEvent.ModifierFlags(rawValue: UInt(raw)).intersection(KeyCombo.mask).rawValue)
            found.append(SystemShortcut(keyCode: code, modifiers: modifiers, name: name(code: code, modifiers: modifiers)))
        }
        return found
    }

    /// The system does not name its shortcuts in this list; these are the well-known defaults.
    private static func name(code: Int, modifiers: Int) -> String {
        let f = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        let cmd = f.contains(.command), opt = f.contains(.option), ctl = f.contains(.control), shift = f.contains(.shift)
        switch (code, cmd, opt, ctl, shift) {
        case (49, true, false, false, false): return tr("Spotlight")
        case (49, true, true, false, false): return tr("Finder search (Spotlight)")
        case (49, false, false, true, false): return tr("Select the previous input source")
        case (49, false, true, true, false): return tr("Select the next input source")
        case (20, true, false, false, true): return tr("Screenshot of the screen")
        case (21, true, false, false, true): return tr("Screenshot of a selection")
        case (23, true, false, false, true): return tr("Screenshot and recording options")
        case (126, false, false, true, false): return tr("Mission Control")
        case (125, false, false, true, false): return tr("Application windows")
        case (123, false, false, true, false): return tr("Move left a space")
        case (124, false, false, true, false): return tr("Move right a space")
        case (53, true, true, false, false): return tr("Force Quit")
        case (12, true, false, true, false): return tr("Lock Screen")
        case (50, true, false, false, false): return tr("Move focus to the next window")
        case (2, true, true, false, false): return tr("Turn Dock hiding on or off")
        default: return tr("a macOS system shortcut")
        }
    }
}

/// Keys MacLister already uses for itself; they cannot be taken.
enum BuiltInShortcuts {
    struct Entry { let combo: KeyCombo; let name: String }

    private static func e(_ code: Int, _ mods: NSEvent.ModifierFlags, _ label: String, _ name: String) -> Entry {
        Entry(combo: KeyCombo(keyCode: code, modifiers: mods, label: label), name: name)
    }

    static let all: [Entry] = [
        e(49, [], "Space", tr("Quick Look")), e(36, [], "Return", tr("Open")), e(76, [], "Enter", tr("Open")),
        e(125, .command, "↓", tr("Open")), e(126, .command, "↑", tr("Parent folder")), e(51, [], "Delete", tr("Parent folder")),
        e(51, .command, "Delete", tr("Move to Trash")), e(47, [.command, .shift], ".", tr("Show hidden files")),
        e(120, [], "F2", tr("Rename")), e(96, [], "F5", tr("Copy")), e(97, [], "F6", tr("Move")),
        e(96, .shift, "⇧F5", tr("Copy As")), e(97, .shift, "⇧F6", tr("Move As")),
        e(14, .command, "E", tr("Extract")), e(34, .command, "I", tr("Info")), e(34, [.command, .option], "I", tr("Attributes")),
        e(2, .command, "D", tr("Duplicate files")), e(2, [.command, .option], "D", tr("Duplicate lister")),
        e(3, .command, "F", tr("Filter")), e(3, [.command, .shift], "F", tr("Find")), e(17, [.command, .option], "T", tr("Folder tree")), e(11, .command, "B", tr("Bookmark")), e(37, [.command, .shift], "L", tr("Bring all listers to front")),
        e(37, .command, "L", tr("Type a path")), e(40, .command, "K", tr("Connect to Server")),
        e(48, [], "Tab", tr("Next lister")), e(48, .shift, "⇧Tab", tr("Previous lister")),
        e(17, .command, "T", tr("New tab")), e(48, .control, "⌃Tab", tr("Next tab")), e(48, [.control, .shift], "⌃⇧Tab", tr("Previous tab")),
        e(30, [.command, .shift], "]", tr("Next tab")), e(33, [.command, .shift], "[", tr("Previous tab")),
    ]

    /// Built-in key of an action, for display next to the custom one.
    static let byAction: [ListerAction: String] = [
        .copy: "F5", .move: "F6", .copyAs: "⇧F5", .moveAs: "⇧F6", .extract: "⌘E", .info: "⌘I", .attributes: "⌥⌘I", .duplicateFile: "⌘D", .duplicateLister: "⌥⌘D",
        .filter: "⌘F", .find: "⇧⌘F", .toggleTree: "⌥⌘T", .addBookmark: "⌘B", .bringAllToFront: "⇧⌘L", .connectToServer: "⌘K", .parent: "Delete", .open: "Return",
        .nextLister: "Tab", .previousLister: "⇧Tab", .newTab: "⌘T", .nextTab: "⌃Tab", .previousTab: "⌃⇧Tab", .undo: "⌘Z", .toggleHidden: "⇧⌘.", .delete: "⌘Delete", .selectPattern: "+", .deselectPattern: "-", .invertSelection: "*",
    ]

    /// Menu and window commands that are handled before a lister sees the key.
    static let reserved: [(combo: KeyCombo, name: String)] = [
        (KeyCombo(keyCode: 12, modifiers: .command, label: "Q"), tr("Quit")),
        (KeyCombo(keyCode: 13, modifiers: .command, label: "W"), tr("Close window")),
        (KeyCombo(keyCode: 45, modifiers: .command, label: "N"), tr("New Lister")),
        (KeyCombo(keyCode: 43, modifiers: .command, label: ","), tr("Settings…")),
        (KeyCombo(keyCode: 46, modifiers: .command, label: "M"), tr("Minimize")),
        (KeyCombo(keyCode: 4, modifiers: .command, label: "H"), tr("Hide")),
        (KeyCombo(keyCode: 0, modifiers: .command, label: "A"), tr("Select all")),
        (KeyCombo(keyCode: 8, modifiers: .command, label: "C"), tr("Copy text")),
        (KeyCombo(keyCode: 9, modifiers: .command, label: "V"), tr("Paste")),
        (KeyCombo(keyCode: 7, modifiers: .command, label: "X"), tr("Cut")),
        (KeyCombo(keyCode: 6, modifiers: .command, label: "Z"), tr("Undo")),
        (KeyCombo(keyCode: 48, modifiers: .command, label: "Tab"), tr("Switch application")),
    ]
}

// MARK: - Checking a combination

enum ShortcutProblem: Equatable {
    case needsModifier(String)
    case reserved(String)
    case builtIn(String)
    case system(String)
    case usedBy(id: String)
    case otherApplication

    func message(for combo: KeyCombo, title: (String) -> String = { $0 }) -> String {
        switch self {
        case .needsModifier(let why): return why
        case .reserved(let name): return tr("%@ is “%@” in every macOS app. Choose another shortcut.", combo.display, tr(name))
        case .builtIn(let name): return tr("%@ is already used in listers for “%@”.", combo.display, tr(name))
        case .system(let name): return tr("%@ is a macOS shortcut (%@). Choose another, or change it in System Settings → Keyboard → Shortcuts.", combo.display, tr(name))
        case .usedBy(let id): return tr("%@ is already assigned to “%@”.", combo.display, title(id))
        case .otherApplication: return tr("%@ is already registered by another application.", combo.display)
        }
    }
}

enum ShortcutRules {
    /// The first problem with giving `combo` to `id`, or nil when it is free.
    /// `system` and `probeGlobal` are parameters so tests can supply their own answers.
    static func validate(_ combo: KeyCombo, for id: String, store: ShortcutStore = .shared,
                         system: [SystemShortcut] = SystemShortcuts.enabled(),
                         probeGlobal: (KeyCombo) -> Bool = GlobalHotKeys.canRegister) -> ShortcutProblem? {
        let isGlobal = id.hasPrefix("global.")

        if isGlobal {
            if !combo.hasMainModifier { return .needsModifier(tr("A shortcut that works in every app needs ⌘, ⌥ or ⌃, otherwise it would block normal typing.")) }
        } else if !combo.hasMainModifier && !combo.isFunctionKey {
            return .needsModifier(tr("Use ⌘, ⌥ or ⌃ with the key (function keys and arrows may stand alone). Plain keys are for typing and type-select."))
        }
        if let hit = BuiltInShortcuts.reserved.first(where: { $0.combo.keyCode == combo.keyCode && $0.combo.modifiers == combo.modifiers }) {
            return .reserved(hit.name)
        }
        if let hit = BuiltInShortcuts.all.first(where: { $0.combo.keyCode == combo.keyCode && $0.combo.modifiers == combo.modifiers }) {
            return .builtIn(hit.name)
        }
        if let hit = system.first(where: { $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers }) {
            return .system(hit.name)
        }
        if let other = store.bindings.first(where: { $0.key != id && $0.value.keyCode == combo.keyCode && $0.value.modifiers == combo.modifiers }) {
            return .usedBy(id: other.key)
        }
        if isGlobal, !(store.combo(for: id) == combo), !probeGlobal(combo) { return .otherApplication }
        return nil
    }
}

// MARK: - Shortcuts that work in every application

/// Carbon hot keys: they need no special permission and fire even while another app is in front.
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var references: [String: EventHotKeyRef] = [:]
    private var numbers: [String: UInt32] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextNumber: UInt32 = 1
    private var handlerInstalled = false

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let number = hotKeyID.id
            DispatchQueue.main.async { GlobalHotKeys.shared.actions[number]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers (or replaces) a shortcut; returns false when the system refuses it (already taken).
    @discardableResult
    func register(id: String, combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)
        let number = numbers[id] ?? { defer { nextNumber += 1 }; return nextNumber }()
        numbers[id] = number
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                         EventHotKeyID(signature: 0x4D434C53, id: number), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[id] = reference
        actions[number] = action
        return true
    }

    func unregister(id: String) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        if let number = numbers[id] { actions[number] = nil }
    }

    func isRegistered(_ id: String) -> Bool { references[id] != nil }

    /// Runs the action of a shortcut as if its keys had been pressed (used by the self-test).
    func trigger(_ id: String) {
        if let number = numbers[id] { actions[number]?() }
    }

    /// True when the system would accept this combination right now.
    static func canRegister(_ combo: KeyCombo) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                         EventHotKeyID(signature: 0x4D434C54, id: 9999), GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference { UnregisterEventHotKey(reference); return true }
        return false
    }
}

/// The global shortcuts and what they do.
enum GlobalShortcutActions {
    static let openLister = "global.openLister"
    static let bringAllToFront = "global.bringAllToFront"
    static let gatherListers = "global.gatherListers"

    static let all: [(id: String, title: String)] = [
        (openLister, tr("Open a lister (in any application)")),
        (bringAllToFront, tr("Bring all listers to the front (in any application)")),
        (gatherListers, tr("Move all listers to the desktop you are on (in any application)")),
    ]

    /// Registers whatever is assigned; called at launch and whenever the assignments change.
    static func apply(store: ShortcutStore = .shared) {
        for (id, _) in all {
            guard let combo = store.combo(for: id) else { GlobalHotKeys.shared.unregister(id: id); continue }
            let action: () -> Void
            switch id {
            case openLister:
                action = {
                    ListerManager.shared.openLister(directory: Settings.startDirectory,
                                                    anchor: .cursor(NSEvent.mouseLocation, centered: Settings.centerOnCursor))
                }
            case gatherListers:
                action = { ListerManager.shared.gatherOnThisDesktop() }
            default:
                action = { ListerManager.shared.bringAllToFront() }
            }
            if !GlobalHotKeys.shared.register(id: id, combo: combo, action: action) {
                DebugLog.write("global shortcut \(combo.display) for \(id) could not be registered (taken by another app?)")
            }
        }
    }
}

extension ListerAction {
    /// "swapSourceDestination" → "Swap source destination"
    var title: String {
        if let custom = Self.friendlyTitles[self] { return tr(custom) }
        var words = ""
        for character in rawValue {
            if character.isUppercase { words += " " + character.lowercased() } else { words.append(character) }
        }
        return tr(words.prefix(1).uppercased() + words.dropFirst())
    }
}

extension ListerAction {
    /// Names that read better than the one made from the action's code name.
    static let friendlyTitles: [ListerAction: String] = [.toggleTree: "Folder tree", .mergeListers: "Merge all listers into tabs"]

    /// What a button with this action shows as its tooltip when it has none of its own. English: like the texts in
    /// buttons.json it is translated when it is shown.
    var defaultHelp: String? {
        switch self {
        case .toggleTree: return "Show or hide the folder tree beside the list (⌥⌘T)"
        case .find: return "Search this folder and everything below it (⇧⌘F)"
        case .findDuplicates: return "Find files with the same content below this folder"
        case .checksums: return "MD5, SHA-1, SHA-256 and SHA-512 of the selected files"
        case .snapshot: return "Remember this window's size, position and sort order for this folder"
        case .forgetSnapshot: return "Forget the snapshot of this folder"
        case .synchronize: return "Compare the source and destination folders and copy what differs"
        case .flatView: return "Show every file below this folder as one list"
        case .newTextFile: return "Create a text file here and open it in your text editor"
        case .copyAs: return "Copy to the destination under new names (⇧F5)"
        case .moveAs: return "Move to the destination under new names (⇧F6)"
        case .newTab: return "Open this folder in a new tab (⌘T)"
        case .nextTab: return "Show the next tab (⌃Tab)"
        case .previousTab: return "Show the previous tab (⌃⇧Tab)"
        case .moveTabToNewLister: return "Take this tab out into a lister window of its own"
        case .mergeListers: return "Make every lister window a tab of this one"
        default: return nil
        }
    }
}
