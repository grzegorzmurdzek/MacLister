import AppKit
import UniformTypeIdentifiers

// MARK: - Compress

/// "Compress" like Finder: one item → "name.zip", several → "Archive.zip", numbered when taken.
enum Compressor {
    struct Result {
        var output: URL?
        var error: String?
    }

    static func outputURL(for items: [URL]) -> URL? {
        guard let first = items.first else { return nil }
        let directory = first.deletingLastPathComponent()
        let name = items.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
        let wanted = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: wanted.path) ? FileTransfer.uniqueURL(for: wanted) : wanted
    }

    /// Runs on a background queue; `completion` is called on the main queue.
    static func compress(_ items: [URL], completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = compressSync(items)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func compressSync(_ items: [URL]) -> Result {
        guard let output = outputURL(for: items) else { return Result(output: nil, error: "Nothing to compress") }
        // One item: ditto, the tool Archive Utility itself uses (keeps resource forks and permissions).
        // Several items: ditto takes only one source, bsdtar writes them side by side.
        let outcome: (status: Int32, stderr: String)
        if items.count == 1 {
            outcome = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", items[0].path, output.path])
        } else {
            let folder = items[0].deletingLastPathComponent().path
            outcome = run("/usr/bin/bsdtar", ["--format", "zip", "-cf", output.path, "-C", folder] + items.map(\.lastPathComponent))
        }
        if outcome.status != 0 {
            try? FileManager.default.removeItem(at: output)      // never leave a broken archive behind
            let detail = outcome.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(outcome.status)"
            return Result(output: nil, error: detail)
        }
        return Result(output: output, error: nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Finder tags (colours)

/// Finder tags live in the extended attribute com.apple.metadata:_kMDItemUserTags as "Name\nN", where N is
/// the colour label (1 gray … 7 orange). Reading and writing them here keeps the colour, which the
/// plain tag-name resource value would lose.
enum FinderTags {
    struct Entry: Hashable {
        var name: String
        var label: Int          // 0: no colour

        var encoded: String { label > 0 ? "\(name)\n\(label)" : name }
    }

    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Finder's order of the colour dots.
    static let menuOrder = [6, 7, 5, 2, 4, 3, 1]
    private static let englishNames = [1: "Gray", 2: "Green", 3: "Purple", 4: "Blue", 5: "Yellow", 6: "Red", 7: "Orange"]

    /// System colour name in the user's language ("Red", "Czerwony" …).
    static func name(for label: Int) -> String {
        let labels = NSWorkspace.shared.fileLabels
        return labels.indices.contains(label) ? labels[label] : (englishNames[label] ?? "Tag")
    }

    static func color(for label: Int) -> NSColor {
        let colors = NSWorkspace.shared.fileLabelColors
        return colors.indices.contains(label) ? colors[label] : .gray
    }

    /// The colour label an entry stands for (by its number, or by the system name when it has none).
    static func label(of entry: Entry) -> Int {
        if entry.label > 0 { return entry.label }
        for label in 1...7 where entry.name == name(for: label) || entry.name == englishNames[label] { return label }
        return 0
    }

    static func entries(of url: URL) -> [Entry] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0, let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [] }
        return list.map(parse)
    }

    static func parse(_ text: String) -> Entry {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let label = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        return Entry(name: String(parts.first ?? ""), label: max(0, min(7, label)))
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        if entries.isEmpty {
            if getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0,
               removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: entries.map(\.encoded), format: .binary, options: 0)
        let status = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// True when every URL carries the colour.
    static func allHave(label: Int, in urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { url in entries(of: url).contains { self.label(of: $0) == label } }
    }

    /// Like Finder: when every item already has the colour it is removed from all, otherwise added to all.
    @discardableResult
    static func toggle(label: Int, on urls: [URL]) -> [String] {
        let remove = allHave(label: label, in: urls)
        var failures: [String] = []
        for url in urls {
            var list = entries(of: url).filter { self.label(of: $0) != label }
            if !remove { list.append(Entry(name: name(for: label), label: label)) }
            do { try write(list, to: url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return failures
    }

    /// Adds and removes whole tags (by name) on every URL.
    @discardableResult
    static func apply(add: [Entry], remove: [Entry], to urls: [URL]) -> [String] {
        var failures: [String] = []
        for url in urls {
            var list = entries(of: url).filter { existing in
                !remove.contains { $0.name == existing.name || (label(of: $0) > 0 && label(of: $0) == label(of: existing)) }
            }
            for entry in add where !list.contains(where: { $0.name == entry.name }) { list.append(entry) }
            do { try write(list, to: url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return failures
    }
}

// MARK: - Quick Actions

/// Quick Actions in the context menu: the image actions Finder offers (rotate, PDF, convert), done
/// with the system's sips, and the user's Automator "Quick Action" workflows from ~/Library/Services.
enum QuickActions {
    static func allImages(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { url in
            guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
            return type.conforms(to: .image) && !type.conforms(to: .svg)
        }
    }

    struct ImageFormat {
        let title: String
        let sipsName: String
        let ext: String
    }
    static let formats = [ImageFormat(title: "JPEG", sipsName: "jpeg", ext: "jpg"),
                          ImageFormat(title: "PNG", sipsName: "png", ext: "png"),
                          ImageFormat(title: "HEIF", sipsName: "heic", ext: "heic")]

    private static func sips(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "sips failed"
    }

    /// Rotates in place (Finder does too). Returns failures.
    static func rotate(_ urls: [URL], degrees: Int) -> [String] {
        urls.compactMap { url in sips(["-r", String(degrees), url.path]).map { "\(url.lastPathComponent): \($0)" } }
    }

    /// Writes "name.ext" next to each image (numbered when taken).
    static func convert(_ urls: [URL], to format: ImageFormat) -> (outputs: [URL], failures: [String]) {
        var outputs: [URL] = [], failures: [String] = []
        for url in urls {
            var target = url.deletingPathExtension().appendingPathExtension(format.ext)
            if FileManager.default.fileExists(atPath: target.path) { target = FileTransfer.uniqueURL(for: target) }
            if let problem = sips(["-s", "format", format.sipsName, url.path, "--out", target.path]) {
                failures.append("\(url.lastPathComponent): \(problem)")
            } else { outputs.append(target) }
        }
        return (outputs, failures)
    }

    /// "Create PDF": one PDF per image.
    static func createPDFs(_ urls: [URL]) -> (outputs: [URL], failures: [String]) {
        var outputs: [URL] = [], failures: [String] = []
        for url in urls {
            var target = url.deletingPathExtension().appendingPathExtension("pdf")
            if FileManager.default.fileExists(atPath: target.path) { target = FileTransfer.uniqueURL(for: target) }
            if let problem = sips(["-s", "format", "pdf", url.path, "--out", target.path]) {
                failures.append("\(url.lastPathComponent): \(problem)")
            } else { outputs.append(target) }
        }
        return (outputs, failures)
    }

    // MARK: Automator workflows

    struct Workflow {
        let title: String
        let url: URL
    }

    /// Quick Action workflows that accept files, from the user's and the system's Services folders.
    static func workflows(directories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services"),
        URL(fileURLWithPath: "/Library/Services"),
    ]) -> [Workflow] {
        var found: [Workflow] = []
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "workflow" {
                let info = url.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: info),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let services = plist["NSServices"] as? [[String: Any]] else { continue }
                for service in services {
                    guard let types = service["NSSendFileTypes"] as? [String], !types.isEmpty,
                          let menu = service["NSMenuItem"] as? [String: Any], let title = menu["default"] as? String else { continue }
                    found.append(Workflow(title: title, url: url))
                }
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Runs the workflow with the paths as input, one per line. Returns an error text, nil on success.
    static func run(_ workflow: Workflow, on urls: [URL]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/automator")
        process.arguments = ["-i", "-", workflow.url.path]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        input.fileHandleForWriting.write(Data(urls.map(\.path).joined(separator: "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
    }
}
