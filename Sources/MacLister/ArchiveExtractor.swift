import Foundation

/// A folder that Cancel left half filled.
struct IncompleteExtraction {
    let archive: URL
    let folder: URL
    /// Entries that were extracted completely.
    let items: Int
    /// The file that was being written when the job stopped; it was deleted because it is cut short.
    let removed: String?
}

struct ExtractResult {
    var outputs: [URL] = []        // created folders
    var failures: [String] = []
    var cancelled = false
    /// Set when Cancel stopped an archive after something was already unpacked: the user decides what happens to it.
    var incomplete: IncompleteExtraction?
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

    /// Archives with several files (not a single .gz / .bz2) can be shown as a folder.
    static func isBrowsable(_ url: URL) -> Bool {
        if case .archive? = kind(of: url) { return true }
        return false
    }

    /// Unpacks into exactly `folder` (which exists). Returns the problem, or nil when it worked.
    static func extractContents(of archive: URL, to folder: URL) -> String? {
        guard case .archive? = kind(of: archive) else { return tr("not a supported archive") }
        let outcome = ExtractProcess.run("/usr/bin/bsdtar", ["-xf", archive.path, "-C", folder.path], stdoutTo: nil)
        if outcome.status == 0 { return nil }
        return outcome.error.split(separator: "\n").last.map(String.init) ?? "exit \(outcome.status)"
    }

    // MARK: -

    struct ExtractError: Error { let message: String }

    /// What `ExtractJob` needs to run one archive.
    struct Plan {
        let tool: String
        let arguments: [String]
        let folder: URL
        let outputFile: URL?          // a single compressed file: where the tool's stdout goes
        let isStream: Bool
    }

    /// Creates the fresh folder for `archive` in `parent` and says how to unpack into it.
    static func plan(for archive: URL, into parent: URL) -> Result<Plan, ExtractError> {
        guard let kind = kind(of: archive) else { return .failure(.init(message: tr("not a supported archive"))) }
        let suffix: String
        switch kind { case .archive(let s), .stream(let s): suffix = s }
        let stem = String(archive.lastPathComponent.dropLast(suffix.count + 1))

        let folder = freeURL(named: stem, in: parent)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { return .failure(.init(message: error.localizedDescription)) }

        switch kind {
        case .archive:
            // -v: bsdtar names each entry on stderr just before it unpacks it; that is the progress.
            return .success(Plan(tool: "/usr/bin/bsdtar", arguments: ["-xvf", archive.path, "-C", folder.path],
                                 folder: folder, outputFile: nil, isStream: false))
        case .stream:
            return .success(Plan(tool: suffix == "gz" ? "/usr/bin/gzip" : "/usr/bin/bzip2", arguments: ["-dc", archive.path],
                                 folder: folder, outputFile: folder.appendingPathComponent(stem), isStream: true))
        }
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
}
