import AppKit

/// "Add to Dock": a lister on one folder as its own Dock icon.
///
/// The Dock can only hold apps, files and folders, and clicking the main MacLister icon opens the start
/// folder. So each folder gets a tiny app of its own (`~/Applications/MacLister Folders/<name>.app`) that
/// does nothing but ask MacLister to open that folder — through the `maclister://open?path=…` URL, which a
/// running MacLister answers by raising the lister that already shows the folder (or opening one) and a
/// closed one by starting up first. The app is then put among the Dock's applications.
enum DockShortcut {
    static let scheme = "maclister"
    static let bundleIdentifier = "com.example.MacLister"
    static let dockDomain = "com.apple.dock"
    private static let folderKey = "MacListerFolderPath"

    /// Where the little apps live, so they are easy to find (and delete) again.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MacLister Folders", isDirectory: true)
    }

    /// `~/Applications/MacLister Folders`, as the dialogs show it.
    static var defaultDirectoryLabel: String { (defaultDirectory.path as NSString).abbreviatingWithTildeInPath }

    // MARK: - The open URL

    /// `maclister://open?path=/Users/me/Downloads` (the path percent-encoded, so it is safe in a shell script too).
    static func openURL(for folder: URL) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let encoded = folder.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "\(scheme)://open?path=\(encoded)") ?? URL(string: "\(scheme)://open")!
    }

    /// The folder a `maclister://open?path=…` URL asks for; nil for any other URL.
    static func folder(from url: URL) -> URL? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - The little app

    /// Makes (or refreshes) the app for `folder` and returns its location. `name` is the Dock label.
    static func createApp(for folder: URL, name: String, in directory: URL = defaultDirectory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = folder.standardizedFileURL
        let app = appLocation(for: folder, name: name, in: directory)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }

        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let label = app.deletingPathExtension().lastPathComponent
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "launcher",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": "\(bundleIdentifier).folder.\(stableHash(folder.path))",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": label,
            "CFBundleDisplayName": label,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": true,              // no second Dock icon while it hands over to MacLister
            folderKey: folder.path,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let launcher = macOS.appendingPathComponent("launcher")
        try Data(launcherScript(for: folder).utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        // The folder's icon with a MacLister badge; MacLister's own icon if that cannot be drawn.
        let ownIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { try? Data(contentsOf: $0) }
        if let icon = iconData(for: folder) ?? ownIcon {
            try icon.write(to: resources.appendingPathComponent("AppIcon.icns"))
        }
        // Ad-hoc signature, so macOS treats the little app like any other app of this Mac.
        _ = run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    /// `<name>.app`, or `<name> 2.app`… when another folder already took the name; the same folder gets its app back.
    static func appLocation(for folder: URL, name: String, in directory: URL) -> URL {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Folder" }
        let mine = folder.standardizedFileURL.path
        var number = 1
        while true {
            let candidate = directory.appendingPathComponent((number == 1 ? base : "\(base) \(number)") + ".app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            if shortcutFolder(of: candidate) == mine { return candidate }
            number += 1
        }
    }

    /// The folder an app made by `createApp` opens.
    static func shortcutFolder(of app: URL) -> String? {
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return plist?[folderKey] as? String
    }

    /// Hands the folder over to MacLister: by bundle identifier first, by the path it was made from if that fails.
    private static func launcherScript(for folder: URL) -> String {
        let url = openURL(for: folder).absoluteString
        return """
        #!/bin/sh
        # Made by MacLister (Add to Dock): opens a lister on one folder.
        URL=\(shellQuote(url))
        /usr/bin/open -b \(bundleIdentifier) "$URL" 2>/dev/null || /usr/bin/open -a \(shellQuote(Bundle.main.bundlePath)) "$URL"

        """
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// FNV-1a: the same text always gives the same identifier (Swift's own hashing changes on every run).
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    // MARK: - The icon: the folder's own icon with a small MacLister badge

    static func iconData(for folder: URL) -> Data? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("maclister-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        guard (try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)) != nil else { return nil }
        let base = NSWorkspace.shared.icon(forFile: folder.path)
        let badge = NSApp.applicationIconImage
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            guard let png = renderIcon(base: base, badge: badge, pixels: points * scale) else { return nil }
            let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
            guard (try? png.write(to: file)) != nil else { return nil }
        }
        let out = work.appendingPathComponent("AppIcon.icns")
        guard run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.path]) else { return nil }
        return try? Data(contentsOf: out)
    }

    private static func renderIcon(base: NSImage, badge: NSImage?, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let side = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        base.draw(in: NSRect(x: 0, y: side * 0.06, width: side, height: side * 0.94), from: .zero, operation: .sourceOver, fraction: 1)
        badge?.draw(in: NSRect(x: side * 0.5, y: 0, width: side * 0.5, height: side * 0.5), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - The Dock

    enum DockResult { case added, alreadyThere, failed }

    /// Appends the app to the Dock's applications (unless it is there) and restarts the Dock so it shows up.
    /// `domain` and `restart` exist for the self-test, which must not touch the real Dock.
    static func addToDock(app: URL, label: String, domain: String = dockDomain, restart: Bool = true) -> DockResult {
        let cfDomain = domain as CFString
        let key = "persistent-apps" as CFString
        CFPreferencesAppSynchronize(cfDomain)
        // A Dock that never saved a layout has no list: writing one would drop the default icons.
        guard var apps = CFPreferencesCopyAppValue(key, cfDomain) as? [[String: Any]] else { return .failed }
        let location = URL(fileURLWithPath: app.path, isDirectory: true).absoluteString
        // the Dock writes the address with or without the closing slash, or as a plain path: compare the paths
        func path(of text: String) -> String {
            let url = text.hasPrefix("file:") ? URL(string: text) : URL(fileURLWithPath: text)
            return url?.standardizedFileURL.path ?? text
        }
        let ours = path(of: location)
        let present = apps.contains { tile in
            let data = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            return (data?["_CFURLString"] as? String).map(path(of:)) == ours
        }
        if present { return .alreadyThere }
        apps.append([
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": location, "_CFURLStringType": 15],
                "file-label": label,
                "file-type": 41,
            ] as [String: Any],
        ])
        CFPreferencesSetAppValue(key, apps as CFArray, cfDomain)
        guard CFPreferencesAppSynchronize(cfDomain) else { return .failed }
        if restart { _ = run("/usr/bin/killall", ["Dock"]) }
        return .added
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - The lister command

extension ListerViewController {
    /// Folders on this Mac only: a server, an archive's inside or a list like Recents has nothing to point a Dock icon at.
    var canAddToDock: Bool { model.url.isFileURL && !model.isVirtual && !model.isRemote && !model.isInArchive }

    /// "Add to Dock…": asks, makes the little app for this lister's folder and puts it in the Dock.
    func addToDock() {
        if remoteUnavailable(tr("Add to Dock")) { return }
        if refuseInList(tr("Add to Dock")) { return }
        if refuseInArchive(tr("Add to Dock")) { return }
        guard let window = view.window else { return }
        let folder = model.url
        let name = model.displayName

        let alert = NSAlert()
        alert.messageText = tr("Add “%@” to the Dock?", name)
        alert.informativeText = tr("MacLister makes a small app for this folder in %@ and puts it in the Dock. Clicking it opens a lister on the folder (or brings the open one forward). The Dock restarts for a moment.", DockShortcut.defaultDirectoryLabel)
        alert.addButton(withTitle: tr("Add to Dock"))
        alert.addButton(withTitle: tr("Only Create the App"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            self?.makeDockShortcut(folder: folder, name: name, putInDock: response == .alertFirstButtonReturn)
        }
    }

    private func makeDockShortcut(folder: URL, name: String, putInDock: Bool) {
        let app: URL
        do { app = try DockShortcut.createApp(for: folder, name: name) } catch {
            flash(tr("Could not make the Dock app: %@", error.localizedDescription))
            return
        }
        guard putInDock else {
            NSWorkspace.shared.activateFileViewerSelecting([app])
            flash(tr("Made “%@”: drag it into the Dock", app.deletingPathExtension().lastPathComponent))
            return
        }
        switch DockShortcut.addToDock(app: app, label: app.deletingPathExtension().lastPathComponent) {
        case .added: flash(tr("“%@” is in the Dock now", name))
        case .alreadyThere: flash(tr("“%@” is already in the Dock", name))
        case .failed:
            NSWorkspace.shared.activateFileViewerSelecting([app])
            flash(tr("The Dock could not be changed. Drag “%@” into it from the Finder window", app.deletingPathExtension().lastPathComponent))
        }
    }
}
