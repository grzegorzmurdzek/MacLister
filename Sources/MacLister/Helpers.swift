import Foundation

/// Wildcard matching for "select by pattern" and the filter. Case-insensitive.
/// Several patterns can be given, separated by spaces, commas, semicolons or "|".
/// Text without any wildcard matches names that merely contain it.
enum NamePattern {
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { " ,;|".contains($0) }).map(String.init)
    }

    static func matches(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let glob = pattern.contains(where: { "*?[".contains($0) }) ? pattern : "*\(pattern)*"
            return fnmatch(glob, name, FNM_CASEFOLD) == 0
        }
    }

    static func matches(_ name: String, text: String) -> Bool {
        matches(name, patterns: parse(text))
    }
}

enum PathText {
    /// "~/Documents/…" form, shortened in the middle when long.
    static func short(_ path: String) -> String {
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        if tilde == "~" { return tr("Home") + " (~)" }          // ~ is the shell's short name for the home folder
        return tilde.count > 60 ? String(tilde.prefix(25)) + "…" + String(tilde.suffix(32)) : tilde
    }
}

/// Recursive size of files and folders.
enum FolderSize {
    /// Logical size (what a file's "Size" says) and the space it takes on disk (whole allocation blocks).
    struct Measure: Equatable {
        var logical: Int64 = 0
        var onDisk: Int64 = 0
    }

    /// Bytes of all regular files below `url`; for a plain file its own size.
    static func total(of url: URL) -> Int64 {
        measure(url)?.logical ?? 0
    }

    /// Walks `url` and sums both sizes. Returns nil when `cancel` fired before the walk finished.
    static func measure(_ url: URL, cancel: CancelToken? = nil) -> Measure? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return Measure() }
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        func read(_ item: URL) -> Measure {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return Measure() }
            let logical = Int64(values.fileSize ?? 0)
            return Measure(logical: logical, onDisk: Int64(values.totalFileAllocatedSize ?? Int(logical)))
        }
        if !isDirectory.boolValue { return read(url) }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                         errorHandler: { _, _ in true }) else { return Measure() }
        var sum = Measure()
        var visited = 0
        for case let item as URL in walker {
            visited += 1
            if visited % 256 == 0, cancel?.isCancelled == true { return nil }
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let one = read(item)
            sum.logical += one.logical
            sum.onDisk += one.onDisk
        }
        return cancel?.isCancelled == true ? nil : sum
    }
}

/// Text for the Info panel (Magellan's "Information").
enum InfoText {
    static func make(for urls: [URL]) -> (title: String, body: String) {
        let fm = FileManager.default
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        func sizeText(_ bytes: Int64) -> String {
            tr("%@ (%@ bytes)", byteFormatter.string(fromByteCount: bytes), bytes.formatted())
        }

        guard urls.count == 1, let url = urls.first else {
            var files = 0, folders = 0
            var total: Int64 = 0
            for url in urls {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if isDirectory.boolValue { folders += 1 } else { files += 1 }
                total += FolderSize.total(of: url)
            }
            return (trCount("%d items", urls.count), tr("Files: %d", files) + "\n" + tr("Folders: %d", folders) + "\n" + tr("Total size: %@", sizeText(total)))
        }

        let attributes = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .medium
        func dateText(_ key: FileAttributeKey) -> String {
            (attributes[key] as? Date).map(dateFormatter.string(from:)) ?? "—"
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0

        let body = """
        \(tr("Where:")) \(url.deletingLastPathComponent().path)
        \(tr("Kind:")) \(values?.localizedTypeDescription ?? "—")
        \(tr("Size:")) \(sizeText(FolderSize.total(of: url)))
        \(tr("Created:")) \(dateText(.creationDate))
        \(tr("Modified:")) \(dateText(.modificationDate))
        \(tr("Permissions:")) \(permissionString(permissions)) (\(String(permissions, radix: 8)))
        \(tr("Owner:")) \(attributes[.ownerAccountName] as? String ?? "—") / \(attributes[.groupOwnerAccountName] as? String ?? "—")
        """
        return (url.lastPathComponent, body)
    }

    /// 0o755 → "rwxr-xr-x"
    static func permissionString(_ mode: Int) -> String {
        let symbols = ["r", "w", "x"]
        return (0..<9).map { bit in mode & (1 << (8 - bit)) != 0 ? symbols[bit % 3] : "-" }.joined()
    }
}

/// One clickable part of the breadcrumb path.
struct PathSegment: Equatable {
    let title: String
    let url: URL
}

enum PathSegments {
    /// "/Users/me/Docs" → [Macintosh HD, Users, me, Docs], each with the URL it leads to.
    static func make(for url: URL) -> [PathSegment] {
        if let title = VirtualPlace.title(for: url) { return [PathSegment(title: title, url: url)] }
        if let location = ArchiveBrowser.shared.location(of: url) {
            // the archive's own path; its last segment opens the top of the archive; then the folders inside
            var segments = make(for: location.archive)
            if let last = segments.popLast() { segments.append(PathSegment(title: last.title, url: location.root)) }
            var current = location.root
            for component in location.inner {
                current.appendPathComponent(component, isDirectory: true)
                segments.append(PathSegment(title: component, url: current))
            }
            return segments
        }
        if RemoteURL.isRemote(url) {
            // server first ("me@host"), then every folder of the path
            let root = RemoteURL.with(path: "/", on: url)
            var segments = [PathSegment(title: RemoteURL.serverLabel(of: url), url: root)]
            var path = ""
            for component in RemoteURL.path(of: url).split(separator: "/") {
                path += "/" + component
                segments.append(PathSegment(title: String(component), url: RemoteURL.with(path: path, on: url)))
            }
            return segments
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/")
        var segments = [PathSegment(title: fm.displayName(atPath: "/"), url: root)]
        var current = root
        for component in url.standardizedFileURL.path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            segments.append(PathSegment(title: fm.displayName(atPath: current.path), url: current))
        }
        return segments
    }
}

/// All running jobs in one line for the menu-bar icon.
struct ProgressSummary: Equatable {
    var fraction: Double?
    var text: String

    /// Listers that share a job show the same status, so statuses with equal text count once.
    static func make(from statuses: [TransferStatus]) -> ProgressSummary? {
        guard !statuses.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = statuses.filter { seen.insert($0.text).inserted }
        let fractions = unique.compactMap(\.fraction)
        let fraction = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
        let text = unique.count == 1 ? unique[0].text : tr("%d operations running", unique.count) + " · " + unique[0].text
        return ProgressSummary(fraction: fraction, text: text)
    }
}


/// Dates for the file list: raw ("Nov 14, 2026 at 10:05") or like Finder ("Today at 10:05", "Yesterday …").
enum DateText {
    private static func make(relative: Bool, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = relative
        return f
    }

    private static var cache: [String: DateFormatter] = [:]

    static func string(_ date: Date, relative: Bool = Settings.relativeDates, locale: Locale = .current) -> String {
        let key = "\(relative)-\(locale.identifier)"
        if let cached = cache[key] { return cached.string(from: date) }
        let made = make(relative: relative, locale: locale)
        cache[key] = made
        return made.string(from: date)
    }
}
