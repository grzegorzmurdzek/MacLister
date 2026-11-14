import Foundation

// MARK: - Batch rename

struct BatchRenameOptions {
    enum CaseMode: String, CaseIterable, Identifiable {
        case unchanged = "Unchanged", lower = "lowercase", upper = "UPPERCASE", title = "Title Case"
        var id: String { rawValue }
    }

    var find = ""
    var replace = ""
    var useRegex = false            // `replace` may use $1, $2 … for captured groups
    var caseSensitive = false
    /// Replaces the whole name: [N] original name, [C] counter, [D] modified date (yyyy-MM-dd), [E] extension.
    var template = ""
    var counterStart = 1
    var counterDigits = 3
    var caseMode = CaseMode.unchanged
    var changeExtension = false
    var newExtension = ""           // empty removes the extension
}

struct RenameEntry {
    let url: URL
    let newName: String
    var problem: String?
    var changes: Bool { newName != url.lastPathComponent }
}

enum BatchRename {
    /// The extension is kept apart from the name: find/replace, template and case act on the name only.
    static func plan(for items: [URL], options o: BatchRenameOptions) -> [RenameEntry] {
        let fm = FileManager.default
        var regex: NSRegularExpression?
        var regexInvalid = false
        if o.useRegex, !o.find.isEmpty {
            regex = try? NSRegularExpression(pattern: o.find, options: o.caseSensitive ? [] : [.caseInsensitive])
            regexInvalid = regex == nil
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var entries: [RenameEntry] = []
        for (index, url) in items.enumerated() {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isFolder = values?.isDirectory ?? false
            let ext = isFolder ? "" : url.pathExtension
            var base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent

            if !o.find.isEmpty, !regexInvalid {
                if let regex {
                    base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: o.replace)
                } else {
                    base = base.replacingOccurrences(of: o.find, with: o.replace, options: o.caseSensitive ? [] : .caseInsensitive)
                }
            }
            if !o.template.isEmpty {
                let counter = String(format: "%0\(max(1, o.counterDigits))d", o.counterStart + index)
                let date = values?.contentModificationDate.map(dateFormatter.string(from:)) ?? ""
                base = o.template
                    .replacingOccurrences(of: "[N]", with: base)
                    .replacingOccurrences(of: "[C]", with: counter)
                    .replacingOccurrences(of: "[D]", with: date)
                    .replacingOccurrences(of: "[E]", with: ext)
            }
            switch o.caseMode {
            case .unchanged: break
            case .lower: base = base.lowercased()
            case .upper: base = base.uppercased()
            case .title: base = base.capitalized
            }
            var finalExtension = ext
            if o.changeExtension { finalExtension = o.newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            let newName = finalExtension.isEmpty ? base : base + "." + finalExtension

            var problem: String?
            if regexInvalid { problem = "Invalid regular expression" }
            else if newName.isEmpty || base.isEmpty { problem = "Empty name" }
            else if newName.contains("/") || newName.contains(":") { problem = "A name cannot contain / or :" }
            entries.append(RenameEntry(url: url, newName: newName, problem: problem))
        }

        // Duplicates among the new names, and clashes with files that stay where they are.
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.newName.lowercased(), default: 0] += 1 }
        let renaming = Set(entries.map { $0.url.standardizedFileURL.path })
        var existingByFolder: [String: Set<String>] = [:]
        for i in entries.indices where entries[i].problem == nil {
            if counts[entries[i].newName.lowercased()] ?? 0 > 1 { entries[i].problem = "Duplicate name"; continue }
            guard entries[i].changes else { continue }
            let folder = entries[i].url.deletingLastPathComponent()
            if existingByFolder[folder.path] == nil {
                let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                existingByFolder[folder.path] = Set(names
                    .filter { !renaming.contains(folder.appendingPathComponent($0).standardizedFileURL.path) }
                    .map { $0.lowercased() })
            }
            if existingByFolder[folder.path]?.contains(entries[i].newName.lowercased()) == true {
                entries[i].problem = "A different item with this name already exists"
            }
        }
        return entries
    }

    /// Two phases (through temporary names), so swaps such as a→b, b→a work.
    static func apply(_ plan: [RenameEntry]) -> (renamed: [URL], failures: [String]) {
        let fm = FileManager.default
        var renamed: [URL] = []
        var failures: [String] = []
        var staged: [(temporary: URL, entry: RenameEntry)] = []

        for entry in plan where entry.changes && entry.problem == nil {
            let temporary = entry.url.deletingLastPathComponent().appendingPathComponent(".maclister-rename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: entry.url, to: temporary)
                staged.append((temporary, entry))
            } catch {
                failures.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (temporary, entry) in staged {
            let target = entry.url.deletingLastPathComponent().appendingPathComponent(entry.newName)
            do {
                try fm.moveItem(at: temporary, to: target)
                renamed.append(target)
            } catch {
                failures.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
                try? fm.moveItem(at: temporary, to: entry.url)      // put it back
            }
        }
        return (renamed, failures)
    }
}

// MARK: - Attribute editor

/// Only the fields that are set are changed.
struct AttributeChange {
    var permissions: Int?              // e.g. 0o644
    var recursive = false              // folders: also change what is inside
    var modified: Date?
    var created: Date?
    var hidden: Bool?
    var tags: [String]?
    var comment: String?               // "" removes the comment
}

enum AttributeEditor {
    /// Returns one message per failure.
    static func apply(_ change: AttributeChange, to urls: [URL]) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []

        func fail(_ url: URL, _ error: Error) { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }

        for url in urls {
            if let mode = change.permissions {
                setPermissions(mode, at: url, recursive: change.recursive, failures: &failures)
            }
            var dates: [FileAttributeKey: Any] = [:]
            if let modified = change.modified { dates[.modificationDate] = modified }
            if let created = change.created { dates[.creationDate] = created }
            if !dates.isEmpty {
                do { try fm.setAttributes(dates, ofItemAtPath: url.path) } catch { fail(url, error) }
            }
            if let hidden = change.hidden {
                var values = URLResourceValues()
                values.isHidden = hidden
                var target = url
                do { try target.setResourceValues(values) } catch { fail(url, error) }
            }
            if let tags = change.tags {
                do { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) } catch { fail(url, error) }
            }
            if let comment = change.comment {
                do { try FinderMetadata.setComment(comment, on: url) } catch { fail(url, error) }
            }
        }
        return failures
    }

    /// Folders keep search permission wherever read is allowed, otherwise a recursive 0644 would lock them.
    private static func setPermissions(_ mode: Int, at url: URL, recursive: Bool, failures: inout [String]) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        func set(_ url: URL, directory: Bool) {
            let effective = directory ? mode | ((mode & 0o444) >> 2) : mode
            do { try fm.setAttributes([.posixPermissions: effective], ofItemAtPath: url.path) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }

        set(url, directory: isDirectory.boolValue)
        guard recursive, isDirectory.boolValue, let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let child as URL in walker {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            set(child, directory: values?.isDirectory ?? false)
        }
    }
}
