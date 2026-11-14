import Foundation

struct ExtractResult {
    var outputs: [URL] = []        // created folders
    var failures: [String] = []
}

/// Unpacks archives into a fresh sub-folder named after the archive (like Archive Utility).
/// Uses the system's /usr/bin/bsdtar (libarchive: zip, tar.*, tgz, 7z, rar, cpio, xar, iso …) and
/// gzip/bzip2 for single compressed files. bsdtar refuses absolute paths and ".." members by default.
enum ArchiveExtractor {
    private enum Kind {
        case archive(suffix: String)   // handled by bsdtar
        case stream(suffix: String)    // one compressed file: .gz / .bz2
    }

    /// Longest suffixes first so "x.tar.gz" is not taken for a plain ".gz".
    private static let archiveSuffixes = [
        "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lzma", "tar.z",
        "tgz", "tbz2", "tbz", "txz", "tar", "zip", "7z", "rar", "cpio", "xar", "iso",
    ]
    private static let streamSuffixes = ["gz", "bz2"]

    private static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if let s = archiveSuffixes.first(where: { name.hasSuffix("." + $0) && name.count > $0.count + 1 }) { return .archive(suffix: s) }
        if let s = streamSuffixes.first(where: { name.hasSuffix("." + $0) && name.count > $0.count + 1 }) { return .stream(suffix: s) }
        return nil
    }

    static func isArchive(_ url: URL) -> Bool { kind(of: url) != nil }

    /// Runs on a background queue; `completion` is called on the main queue.
    static func extract(_ archives: [URL], into parent: URL, completion: @escaping (ExtractResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = extractSync(archives, into: parent)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func extractSync(_ archives: [URL], into parent: URL) -> ExtractResult {
        var result = ExtractResult()
        for archive in archives {
            switch extractOne(archive, into: parent) {
            case .success(let folder): result.outputs.append(folder)
            case .failure(let error):  result.failures.append("\(archive.lastPathComponent): \(error.message)")
            }
        }
        return result
    }

    // MARK: -

    struct ExtractError: Error { let message: String }

    private static func extractOne(_ archive: URL, into parent: URL) -> Result<URL, ExtractError> {
        guard let kind = kind(of: archive) else { return .failure(.init(message: tr("not a supported archive"))) }
        let fm = FileManager.default

        let suffix: String
        switch kind { case .archive(let s), .stream(let s): suffix = s }
        let name = archive.lastPathComponent
        let stem = String(name.dropLast(suffix.count + 1))

        let folder = freeURL(named: stem, in: parent)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { return .failure(.init(message: error.localizedDescription)) }

        let outcome: (status: Int32, error: String)
        switch kind {
        case .archive:
            outcome = run("/usr/bin/bsdtar", ["-xf", archive.path, "-C", folder.path], stdoutTo: nil)
        case .stream:
            let tool = suffix == "gz" ? "/usr/bin/gzip" : "/usr/bin/bzip2"
            let output = folder.appendingPathComponent(stem)
            outcome = run(tool, ["-dc", archive.path], stdoutTo: output)
        }

        if outcome.status != 0 {
            try? fm.removeItem(at: folder)    // never leave a half-empty folder behind
            let line = outcome.error.split(separator: "\n").last.map(String.init) ?? "exit \(outcome.status)"
            return .failure(.init(message: line))
        }
        return .success(folder)
    }

    private static func freeURL(named base: String, in parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private static func run(_ tool: String, _ arguments: [String], stdoutTo file: URL?) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        var outputHandle: FileHandle?
        if let file {
            // Without a file to write to, the tool would print the data into this app's own stdout.
            guard FileManager.default.createFile(atPath: file.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: file) else {
                return (-1, tr("Cannot create “%@”", file.lastPathComponent))
            }
            outputHandle = handle
            process.standardOutput = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        defer { try? outputHandle?.close() }

        do { try process.run() }
        catch { return (-1, error.localizedDescription) }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}
