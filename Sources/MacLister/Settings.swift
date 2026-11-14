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

/// Small preferences layer on top of UserDefaults.
///
/// Hidden switches (set with `defaults write com.example.MacLister <key> ...`):
///   showStatusItem   (bool,   default true)  – menu bar icon
///   startDirectory   (string, default ~)     – folder a desktop double-click opens
///   terminalBundleID (string, default com.apple.Terminal) – app used by "Terminal Here"
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
            "desktopTrigger": DesktopTrigger.doubleClick.rawValue,
            "terminalBundleID": "com.apple.Terminal",
            "relativeDates": true,
            "dragSelectFromNames": true,
            "showDockIcon": true,
            "listersOnAllDesktops": false,
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

    static var showStatusItem: Bool { defaults.bool(forKey: "showStatusItem") }
    static var debugHitTest: Bool { defaults.bool(forKey: "debugHitTest") }
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
