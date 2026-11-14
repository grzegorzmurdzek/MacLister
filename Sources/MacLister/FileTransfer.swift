import Foundation

enum TransferKind {
    case copy, move

    var verb: String { self == .copy ? "Copy" : "Move" }
    var progressVerb: String { self == .copy ? "Copying" : "Moving" }
}

/// What to do when an item with the same name already exists in the destination.
enum ConflictPolicy {
    case replace    // existing item goes to the Trash first
    case keepBoth   // new item gets "name 2.ext"
    case skip
}

struct TransferResult {
    var done: [URL] = []          // resulting URLs in the destination
    var skipped = 0
    var failures: [String] = []
}

/// Copy / move between folders. Pure FileManager logic, no UI.
enum FileTransfer {

    /// Items whose name is already taken in `directory`.
    static func conflicts(of items: [URL], in directory: URL) -> [URL] {
        items.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.lastPathComponent).path) }
    }

    /// Runs the transfer on a background queue; `completion` is called on the main queue.
    static func perform(_ kind: TransferKind, items: [URL], into directory: URL,
                        policy: ConflictPolicy, completion: @escaping (TransferResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(kind, items: items, into: directory, policy: policy)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous core (also used by the tests).
    static func run(_ kind: TransferKind, items: [URL], into directory: URL, policy: ConflictPolicy) -> TransferResult {
        let fm = FileManager.default
        var result = TransferResult()

        for source in items {
            var target = directory.appendingPathComponent(source.lastPathComponent)

            if samePath(source, target) {                       // already there
                result.skipped += 1
                continue
            }
            if isInside(directory, of: source) {                // folder into itself
                result.failures.append("\(source.lastPathComponent): cannot \(kind == .copy ? "copy" : "move") a folder into itself")
                continue
            }
            if fm.fileExists(atPath: target.path) {
                switch policy {
                case .skip:
                    result.skipped += 1
                    continue
                case .keepBoth:
                    target = uniqueURL(for: target)
                case .replace:
                    do { try fm.trashItem(at: target, resultingItemURL: nil) }
                    catch {
                        result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                        continue
                    }
                }
            }
            do {
                if kind == .copy { try fm.copyItem(at: source, to: target) }
                else { try fm.moveItem(at: source, to: target) }
                result.done.append(target)
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

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
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: helpers

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// true when `directory` is `folder` itself or lies somewhere below it.
    private static func isInside(_ directory: URL, of folder: URL) -> Bool {
        let d = directory.standardizedFileURL.path
        let f = folder.standardizedFileURL.path
        return d == f || d.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

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
