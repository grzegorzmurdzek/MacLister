import AppKit
import CryptoKit

/// The notes of one published version.
struct ReleaseEntry: Equatable {
    var version: String
    var notes: String
}

/// The newest published version, as the GitHub release feed describes it.
struct ReleaseInfo: Equatable {
    var version: String
    var notes: String
    var pageURL: URL
    var zipURL: URL?
    var checksumURL: URL?
    /// Releases between the running version and this one (newest first), so nobody who skipped a few misses their notes.
    var earlier: [ReleaseEntry] = []
}

enum UpdateError: LocalizedError {
    case badAnswer, http(Int), checksum, badPackage(String), notInstallable

    var errorDescription: String? {
        switch self {
        case .badAnswer: return tr("The update server sent an answer MacLister does not understand.")
        case .http(let code): return tr("The update server answered with an error (%d).", code)
        case .checksum: return tr("The downloaded file does not match its checksum, so it was not installed.")
        case .badPackage(let why): return tr("The downloaded update is not valid: %@", why)
        case .notInstallable: return tr("This copy of MacLister cannot replace itself.")
        }
    }
}

enum UpdateChecker {
    /// Where new versions are announced: Info.plist (MacListerUpdateFeed) unless the defaults say otherwise.
    static var feedURL: URL? {
        if let custom = UserDefaults.standard.string(forKey: "updateFeedURL"), let url = URL(string: custom) { return url }
        return (Bundle.main.object(forInfoDictionaryKey: "MacListerUpdateFeed") as? String).flatMap(URL.init(string:))
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "1.10.0" > "1.9.2"; a leading "v" and missing parts are fine.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads the feed: one GitHub release document, or the list of releases. From a list the newest published
    /// version (drafts and pre-releases ignored) is returned, and `earlier` holds the other versions newer than `current`.
    static func parse(_ data: Data, current: String = currentVersion) throws -> ReleaseInfo {
        let json = try JSONSerialization.jsonObject(with: data)
        if let one = json as? [String: Any] { return try release(from: one) }
        guard let list = json as? [[String: Any]] else { throw UpdateError.badAnswer }
        let published = list.filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }.compactMap { try? release(from: $0) }
        var sorted = published.sorted { isNewer($0.version, than: $1.version) }
        guard var latest = sorted.first else { throw UpdateError.badAnswer }
        sorted.removeFirst()
        latest.earlier = sorted.filter { isNewer($0.version, than: current) }.map { ReleaseEntry(version: $0.version, notes: $0.notes) }
        return latest
    }

    private static func release(from json: [String: Any]) throws -> ReleaseInfo {
        guard let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.badAnswer }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ matches: (String) -> Bool) -> URL? {
            assets.first { matches(($0["name"] as? String) ?? "") }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        return ReleaseInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")),
                           notes: (json["body"] as? String) ?? "", pageURL: page,
                           zipURL: asset { $0.hasSuffix(".zip") },
                           checksumURL: asset { $0.hasSuffix(".sha256") })
    }

    /// Asks the feed for the latest release. `completion` (main queue): nil means "you are up to date".
    static func check(feed: URL? = feedURL, completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        guard let feed else { completion(.failure(UpdateError.badAnswer)); return }
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacLister/\(currentVersion)", forHTTPHeaderField: "User-Agent")      // GitHub wants a User-Agent; this carries no personal data
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<ReleaseInfo?, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(UpdateError.http(http.statusCode))
            } else if let data {
                result = Result { let release = try parse(data); return isNewer(release.version, than: currentVersion) ? release : nil }
            } else {
                result = .failure(UpdateError.badAnswer)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: Installing

    /// Downloads the release, checks it and unpacks the new app into a fresh temp folder. Background thread.
    static func download(_ release: ReleaseInfo) throws -> URL {
        guard let zipURL = release.zipURL else { throw UpdateError.notInstallable }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacLister-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent("update.zip")
        try fetch(zipURL, to: zip)
        if let checksumURL = release.checksumURL {
            let sumFile = work.appendingPathComponent("update.sha256")
            try fetch(checksumURL, to: sumFile)
            let expected = (try String(contentsOf: sumFile, encoding: .utf8)).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
            guard expected == sha256(of: zip) else { throw UpdateError.checksum }
        }

        let unpacked = work.appendingPathComponent("new")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("MacLister.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.badPackage(tr("no application inside"))
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError.badPackage(tr("a different application")) }
        guard let version = info["CFBundleShortVersionString"] as? String, isNewer(version, than: currentVersion) else {
            throw UpdateError.badPackage(tr("not newer than this version"))
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fetch(_ url: URL, to file: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        URLSession.shared.downloadTask(with: url) { temp, response, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { failure = UpdateError.http(http.statusCode); return }
            guard let temp else { failure = UpdateError.badAnswer; return }
            do { try? FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: temp, to: file) } catch { failure = error }
        }.resume()
        semaphore.wait()
        if let failure { throw failure }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.badPackage(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Can this running copy be replaced? Only a real .app in a folder the user may write to.
    static var canReplaceRunningApp: Bool {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Swaps the new app in once this process has quit, then starts it. The old copy stays until the new
    /// one is in place, and comes back if the swap fails.
    static func installAfterQuit(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        BACKUP="$1.old"
        rm -rf "$BACKUP"
        if mv "$1" "$BACKUP" && mv "$2" "$1"; then
            rm -rf "$BACKUP"
        else
            [ -e "$BACKUP" ] && [ ! -e "$1" ] && mv "$BACKUP" "$1"
        fi
        open "$1"
        rm -rf "$(dirname "$(dirname "$2")")"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, target.path, newApp.path]
        try process.run()
    }
}

/// The user-facing side: questions, alerts and the daily check.
final class UpdateManager {
    static let shared = UpdateManager()
    private var busy = false

    /// Called a moment after launch: asks once whether to check automatically, then checks daily when allowed.
    func launchCheck() {
        if !Settings.updateQuestionAsked {
            askAboutAutomaticChecks()
        }
        guard Settings.autoUpdateCheck else { return }
        if let last = Settings.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        check(userInitiated: false)
    }

    /// The one-time question. The default answer is "no".
    func askAboutAutomaticChecks() {
        Settings.updateQuestionAsked = true
        NSApp.bringToFront()
        let alert = NSAlert()
        alert.messageText = tr("Check for updates automatically?")
        alert.informativeText = tr("MacLister can look once a day whether a new version has been published on GitHub. Nothing is installed without your confirmation, and no information about you or your files is sent. You can change this later in the menu-bar menu.")
        alert.addButton(withTitle: tr("Not Now"))
        alert.addButton(withTitle: tr("Check Automatically"))
        Settings.autoUpdateCheck = alert.runModal() == .alertSecondButtonReturn
    }

    /// "Check for Updates…" (always answers) or the daily background check (speaks only when there is news).
    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        UpdateChecker.check { [weak self] result in
            guard let self else { return }
            self.busy = false
            Settings.lastUpdateCheck = Date()
            NotificationCenter.default.post(name: .updateCheckFinished, object: nil)
            switch result {
            case .failure(let error):
                if userInitiated { self.show(title: tr("Could not check for updates"), text: error.localizedDescription) }
            case .success(nil):
                if userInitiated { self.show(title: tr("MacLister is up to date"), text: tr("You have the newest version (%@).", UpdateChecker.currentVersion)) }
            case .success(let release?):
                if !userInitiated, Settings.skippedUpdate == release.version { return }
                self.offer(release)
            }
        }
    }

    private func show(title: String, text: String) {
        NSApp.bringToFront()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func offer(_ release: ReleaseInfo) {
        NSApp.bringToFront()
        let alert = NSAlert()
        alert.messageText = tr("MacLister %@ is available", release.version)
        alert.informativeText = tr("You have version %@.", UpdateChecker.currentVersion)
        let notes = ReleaseNotes.combined(release, polish: (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("pl"))
        if !notes.isEmpty { alert.accessoryView = ReleaseNotes.accessoryView(for: notes) }
        let canInstall = release.zipURL != nil && UpdateChecker.canReplaceRunningApp
        if canInstall { alert.addButton(withTitle: tr("Install and Restart")) }
        alert.addButton(withTitle: tr("View Release"))
        alert.addButton(withTitle: tr("Later"))
        alert.addButton(withTitle: tr("Skip This Version"))
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = canInstall ? response : response + 1
        switch choice {
        case 0: install(release)
        case 1: NSWorkspace.shared.open(release.pageURL)
        case 3: Settings.skippedUpdate = release.version
        default: break
        }
    }

    private func install(_ release: ReleaseInfo) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try UpdateChecker.download(release) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .failure(let error):
                    self.show(title: tr("The update was not installed"), text: error.localizedDescription)
                case .success(let app):
                    do {
                        try UpdateChecker.installAfterQuit(app)
                        NSApp.terminate(nil)
                    } catch {
                        self.show(title: tr("The update was not installed"), text: error.localizedDescription)
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted on the main queue when an update check has ended, with or without a result.
    static let updateCheckFinished = Notification.Name("MacListerUpdateCheckFinished")
}
