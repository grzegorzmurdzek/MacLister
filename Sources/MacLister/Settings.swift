import AppKit

enum ButtonBarPosition: String, CaseIterable {
    case abovePath, belowPath, bottom

    var menuTitle: String {
        switch self {
        case .abovePath: return "Above the Path (like Ambient)"
        case .belowPath: return "Below the Path"
        case .bottom:    return "At the Bottom"
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
            "terminalBundleID": "com.apple.Terminal",
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
