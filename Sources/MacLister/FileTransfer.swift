import Foundation

enum TransferKind {
    case copy, move

    var verb: String { self == .copy ? tr("Copy") : tr("Move") }
    var progressVerb: String { self == .copy ? tr("Copying") : tr("Moving") }
}

/// One top-level item of an operation: enough to take it back.
struct TransferPair: Codable, Equatable {
    var source: URL
    var target: URL
    /// An existing item that was moved to the Trash to make room (Replace); put back by Undo.
    var replaced: URL?
    /// false when Undo could not be done safely (a folder merge, a half-moved folder).
    var undoable = true
}

struct TransferResult {
    var done: [URL] = []          // resulting URLs in the destination
    var pairs: [TransferPair] = []
    var skipped = 0
    var failures: [String] = []
    var cancelled = false
}

/// Copy / move between folders. Pure FileManager logic, no UI.
enum FileTransfer {

    /// Duplicates items next to the originals: "report.txt" → "report copy.txt", "report copy 2.txt", …
    static func duplicate(_ items: [URL]) -> TransferResult {
        let fm = FileManager.default
        var result = TransferResult()
        for source in items {
            let directory = source.deletingLastPathComponent()
            let ext = source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            var n = 1
            var target: URL
            repeat {
                let suffix = n == 1 ? " copy" : " copy \(n)"
                target = directory.appendingPathComponent(ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)")
                n += 1
            } while fm.fileExists(atPath: target.path)
            do {
                try fm.copyItem(at: source, to: target)
                result.done.append(target)
                result.pairs.append(TransferPair(source: source, target: target))
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: helpers

    /// "report.txt" → "report 2.txt", "report 3.txt", …
    static func uniqueURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

/// Finder aliases and symbolic links.
enum LinkMaker {
    /// "report.txt" → "report.txt alias" / "report.txt link", numbered when taken.
    static func make(symbolic: Bool, items: [URL], in folder: URL?) -> TransferResult {
        let fm = FileManager.default
        var result = TransferResult()
        for source in items {
            let directory = folder ?? source.deletingLastPathComponent()
            let suffix = symbolic ? "link" : "alias"
            var n = 1
            var target: URL
            repeat {
                target = directory.appendingPathComponent(n == 1 ? "\(source.lastPathComponent) \(suffix)" : "\(source.lastPathComponent) \(suffix) \(n)")
                n += 1
            } while fm.fileExists(atPath: target.path) || (try? target.checkResourceIsReachable()) == true
            do {
                if symbolic {
                    try fm.createSymbolicLink(at: target, withDestinationURL: source)
                } else {
                    let data = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try URL.writeBookmarkData(data, to: target)
                }
                result.done.append(target)
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }
}
