import AppKit

enum ButtonBarPosition: String, CaseIterable {
    case abovePath, belowPath, bottom

    var menuTitle: String {
        switch self {
        case .abovePath: return tr("Above the Path (like Ambient)")
        case .belowPath: return tr("Below the Path")
        case .bottom:    return tr("At the Bottom")
        }
    }
}

/// What on the empty desktop opens a lister.
enum DesktopTrigger: String, CaseIterable {
    case doubleClick, middleClick, both

    var menuTitle: String {
        switch self {
        case .doubleClick: return tr("Double-click (left button)")
        case .middleClick: return tr("Click the middle button")
        case .both:        return tr("Both")
        }
    }

    /// `button`: 0 left, 2 middle. A middle click counts only as a first click, so a quick double middle
    /// click does not open two listers.
    func accepts(button: Int, clickCount: Int) -> Bool {
        switch button {
        case 0: return self != .middleClick && clickCount == 2
        case 2: return self != .doubleClick && clickCount == 1
        default: return false
        }
    }
}

/// What a double-click on a tab in the tab bar does.
enum TabDoubleClickAction: String, CaseIterable {
    case nameTab, duplicateTab, closeTab, nothing

    var menuTitle: String {
        switch self {
        case .nameTab:      return tr("Name This Tab…")
        case .duplicateTab: return tr("New Tab on This Folder")
        case .closeTab:     return tr("Close Tab")
        case .nothing:      return tr("Do Nothing")
        }
    }
}

/// Small preferences layer on top of UserDefaults.
///
/// Hidden switches (set with `defaults write com.example.MacLister <key> ...`):
///   showStatusItem   (bool,   default true)  – menu bar icon
///   startDirectory   (string, default ~)     – folder a desktop double-click opens
///   terminalBundleID (string, default com.apple.Terminal) – app used by "Terminal Here"
///   textEditorBundleID (string, default com.apple.TextEdit) – app that opens a file made by "New Text File"
///   debugHitTest     (bool,   default false) – log every desktop hit-test decision (Console.app)
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            "centerOnCursor": false,
            "showStatusItem": true,
            "debugHitTest": false,
            "restoreLayoutAtLaunch": false,
            "showButtonLabels": false,
            "buttonBarPosition": ButtonBarPosition.abovePath.rawValue,
            "showButtonMenuArrows": false,
            "autoAssignRoles": true,
            "desktopTrigger": DesktopTrigger.doubleClick.rawValue,
            "terminalBundleID": "com.apple.Terminal",
            "textEditorBundleID": "com.apple.TextEdit",
            "browseArchives": true,
            "springLoadedFolders": true,
            "relativeDates": true,
            "dragSelectFromNames": true,
            "showDockIcon": true,
            "listersOnAllDesktops": false,
            "listerTabs": true,
            "tabDoubleClick": TabDoubleClickAction.nameTab.rawValue,
            "foldersFirst": true,
        ])
    }

    /// true: lister is centered on the cursor; false: its top-left corner sits exactly on the click.
    static var centerOnCursor: Bool {
        get { defaults.bool(forKey: "centerOnCursor") }
        set { defaults.set(newValue, forKey: "centerOnCursor") }
    }

    /// Reopen the layout saved with "Save Layout" when the app starts.
    static var restoreLayoutAtLaunch: Bool { defaults.bool(forKey: "restoreLayoutAtLaunch") }

    static var showButtonLabels: Bool {
        get { defaults.bool(forKey: "showButtonLabels") }
        set { defaults.set(newValue, forKey: "showButtonLabels") }
    }

    /// A small arrow on buttons that have a menu: a click on it opens the menu at once. Off: hold the button down.
    static var showButtonMenuArrows: Bool {
        get { defaults.bool(forKey: "showButtonMenuArrows") }
        set { defaults.set(newValue, forKey: "showButtonMenuArrows") }
    }

    /// A new lister becomes the source when there is none, else the destination when there is none (see ListerManager).
    static var autoAssignRoles: Bool {
        get { defaults.bool(forKey: "autoAssignRoles") }
        set { defaults.set(newValue, forKey: "autoAssignRoles") }
    }

    /// Which mouse gesture on the empty desktop opens a lister.
    static var desktopTrigger: DesktopTrigger {
        get { DesktopTrigger(rawValue: defaults.string(forKey: "desktopTrigger") ?? "") ?? .doubleClick }
        set { defaults.set(newValue.rawValue, forKey: "desktopTrigger") }
    }

    /// Where the button bar sits. Default: above the path bar, as in Ambient on MorphOS.
    static var buttonBarPosition: ButtonBarPosition {
        get { ButtonBarPosition(rawValue: defaults.string(forKey: "buttonBarPosition") ?? "") ?? .abovePath }
        set { defaults.set(newValue.rawValue, forKey: "buttonBarPosition") }
    }

    static let minListerSize = NSSize(width: 360, height: 240)

    /// Content size of new listers: the size the user last gave a lister by dragging its edge.
    static var listerContentSize: NSSize {
        get {
            let w = defaults.double(forKey: "listerWidth"), h = defaults.double(forKey: "listerHeight")
            return w >= minListerSize.width && h >= minListerSize.height ? NSSize(width: w, height: h) : NSSize(width: 560, height: 400)
        }
        set {
            defaults.set(Double(newValue.width), forKey: "listerWidth")
            defaults.set(Double(newValue.height), forKey: "listerHeight")
        }
    }

    /// Dates in the file list as Finder shows them: Today, Yesterday, (in Polish also Przedwczoraj).
    static var relativeDates: Bool {
        get { defaults.bool(forKey: "relativeDates") }
        set { defaults.set(newValue, forKey: "relativeDates") }
    }

    /// Dragging from an unselected file name selects the rows it passes over (Directory Opus); off: it drags the file.
    static var dragSelectFromNames: Bool {
        get { defaults.bool(forKey: "dragSelectFromNames") }
        set { defaults.set(newValue, forKey: "dragSelectFromNames") }
    }

    /// Look for a new version once a day. Off until the user agrees (see UpdateManager.askAboutAutomaticChecks).
    static var autoUpdateCheck: Bool {
        get { defaults.bool(forKey: "autoUpdateCheck") }
        set { defaults.set(newValue, forKey: "autoUpdateCheck") }
    }
    static var updateQuestionAsked: Bool {
        get { defaults.bool(forKey: "updateQuestionAsked") }
        set { defaults.set(newValue, forKey: "updateQuestionAsked") }
    }
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }
    /// A version the user chose to ignore ("Skip This Version").
    static var skippedUpdate: String? {
        get { defaults.string(forKey: "skippedUpdate") }
        set { defaults.set(newValue, forKey: "skippedUpdate") }
    }

    /// A Dock icon (right-click it for the open listers and New Lister). The menu-bar icon stays either way.
    static var showDockIcon: Bool {
        get { defaults.bool(forKey: "showDockIcon") }
        set { defaults.set(newValue, forKey: "showDockIcon") }
    }

    /// Listers stay visible on every macOS desktop (Space) instead of only the one they were opened on.
    static var listersOnAllDesktops: Bool {
        get { defaults.bool(forKey: "listersOnAllDesktops") }
        set { defaults.set(newValue, forKey: "listersOnAllDesktops") }
    }

    /// Listers can hold several folders as tabs (⌘T), like Finder and web browsers (on by default; new listers still
    /// open as windows). Off: one folder per window.
    static var listerTabs: Bool {
        get { defaults.bool(forKey: "listerTabs") }
        set { defaults.set(newValue, forKey: "listerTabs") }
    }

    /// What a double-click on a tab does (Name This Tab… unless you choose otherwise).
    static var tabDoubleClick: TabDoubleClickAction {
        get { TabDoubleClickAction(rawValue: defaults.string(forKey: "tabDoubleClick") ?? "") ?? .nameTab }
        set { defaults.set(newValue.rawValue, forKey: "tabDoubleClick") }
    }

    /// Folders stay above the files whatever the sort column is. Off: folders and files are sorted together.
    static var foldersFirst: Bool {
        get { defaults.bool(forKey: "foldersFirst") }
        set { defaults.set(newValue, forKey: "foldersFirst") }
    }

    static var showStatusItem: Bool { defaults.bool(forKey: "showStatusItem") }
    static var debugHitTest: Bool { defaults.bool(forKey: "debugHitTest") }
    /// The app that opens a file made by New Text File.
    static var textEditorBundleID: String {
        get { defaults.string(forKey: "textEditorBundleID") ?? "com.apple.TextEdit" }
        set { defaults.set(newValue, forKey: "textEditorBundleID") }
    }

    /// Dragging files over a folder for a moment opens it (spring-loaded folders).
    static var springLoadedFolders: Bool {
        get { defaults.bool(forKey: "springLoadedFolders") }
        set { defaults.set(newValue, forKey: "springLoadedFolders") }
    }

    /// Seconds a dragged file must rest on a folder before it opens (hidden setting).
    static var springLoadedDelay: TimeInterval {
        let value = defaults.double(forKey: "springLoadedDelay")
        return value >= 0.2 && value <= 5 ? value : 0.8
    }

    /// The directory tree beside the file list; new listers start with the state you last chose.
    static var showFolderTree: Bool {
        get { defaults.bool(forKey: "showFolderTree") }
        set { defaults.set(newValue, forKey: "showFolderTree") }
    }

    /// Height of Finder's sidebar part above the directory tree (points); 0: not set yet.
    static var sidebarHeight: CGFloat {
        get { let value = defaults.double(forKey: "sidebarHeight"); return value >= 80 ? CGFloat(value) : 0 }
        set { defaults.set(newValue, forKey: "sidebarHeight") }
    }

    /// Width of the directory tree (points).
    static var folderTreeWidth: CGFloat {
        get { let value = defaults.double(forKey: "folderTreeWidth"); return value >= 120 ? CGFloat(value) : 200 }
        set { defaults.set(Double(newValue), forKey: "folderTreeWidth") }
    }

    /// A double-click on an archive shows its contents like a folder (read-only) instead of handing it to the system.
    static var browseArchives: Bool {
        get { defaults.bool(forKey: "browseArchives") }
        set { defaults.set(newValue, forKey: "browseArchives") }
    }

    static var terminalBundleID: String {
        get { defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal" }
        set { defaults.set(newValue, forKey: "terminalBundleID") }
    }

    static var startDirectory: URL {
        if let path = defaults.string(forKey: "startDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Diagnostics go to ~/Library/Logs/MacLister.log (and NSLog). Unified-log lines from an
/// ad-hoc signed agent are easy to miss, a plain file is not.
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacLister.log")

    static func write(_ message: String) {
        NSLog("[MacLister] %@", message)
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
