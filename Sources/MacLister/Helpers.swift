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
        return tilde.count > 60 ? String(tilde.prefix(25)) + "…" + String(tilde.suffix(32)) : tilde
    }
}

/// Recursive size of files and folders.
enum FolderSize {
    /// Bytes of all regular files below `url`; for a plain file its own size.
    static func total(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                         errorHandler: { _, _ in true }) else { return 0 }
        var sum: Int64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { sum += Int64(values?.fileSize ?? 0) }
        }
        return sum
    }
}

/// Text for the Info panel (Magellan's "Information").
enum InfoText {
    static func make(for urls: [URL]) -> (title: String, body: String) {
        let fm = FileManager.default
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        func sizeText(_ bytes: Int64) -> String {
            "\(byteFormatter.string(fromByteCount: bytes)) (\(bytes.formatted()) bytes)"
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
            return ("\(urls.count) items", "Files: \(files)\nFolders: \(folders)\nTotal size: \(sizeText(total))")
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
        Where: \(url.deletingLastPathComponent().path)
        Kind: \(values?.localizedTypeDescription ?? "—")
        Size: \(sizeText(FolderSize.total(of: url)))
        Created: \(dateText(.creationDate))
        Modified: \(dateText(.modificationDate))
        Permissions: \(permissionString(permissions)) (\(String(permissions, radix: 8)))
        Owner: \(attributes[.ownerAccountName] as? String ?? "—") / \(attributes[.groupOwnerAccountName] as? String ?? "—")
        """
        return (url.lastPathComponent, body)
    }

    /// 0o755 → "rwxr-xr-x"
    static func permissionString(_ mode: Int) -> String {
        let symbols = ["r", "w", "x"]
        return (0..<9).map { bit in mode & (1 << (8 - bit)) != 0 ? symbols[bit % 3] : "-" }.joined()
    }
}
