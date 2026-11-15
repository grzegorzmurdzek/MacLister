import AppKit

/// Columns of the file list. Name is always shown; the others can be switched on and off by
/// right-clicking the column header.
enum ListerColumn: String, CaseIterable {
    case name, size, date, created, kind, ext, permissions, tags, comment, folder

    var title: String {
        switch self {
        case .name: return tr("Name")
        case .size: return tr("Size")
        case .date: return tr("Modified")
        case .created: return tr("Created")
        case .kind: return tr("Kind")
        case .ext: return tr("Extension")
        case .permissions: return tr("Permissions")
        case .tags: return tr("Tags")
        case .comment: return tr("Comment")
        case .folder: return tr("Where")
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 260
        case .size: return 76
        case .date, .created: return 176
        case .kind: return 150
        case .ext: return 80
        case .permissions: return 96
        case .tags: return 150
        case .comment: return 220
        case .folder: return 200
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 110
        case .size: return 60
        case .date, .created: return 120
        case .kind: return 90
        case .ext: return 50
        case .permissions: return 80
        case .tags: return 70
        case .comment: return 80
        case .folder: return 100
        }
    }

    var rightAligned: Bool { self == .size }
}

extension Notification.Name {
    static let columnsChanged = Notification.Name("MacListerColumnsChanged")
}

enum ColumnSettings {
    private static let key = "visibleColumns"
    static let defaultVisible: [ListerColumn] = [.size, .date]

    /// Visible columns in display order; Name first.
    static var visible: [ListerColumn] {
        let stored = UserDefaults.standard.stringArray(forKey: key)
        let chosen = stored.map { $0.compactMap(ListerColumn.init(rawValue:)) } ?? defaultVisible
        return [.name] + ListerColumn.allCases.filter { $0 != .name && chosen.contains($0) }
    }

    static func set(_ column: ListerColumn, visible on: Bool) {
        guard column != .name else { return }
        var chosen = Set(visible)
        if on { chosen.insert(column) } else { chosen.remove(column) }
        setVisible(Array(chosen))
    }

    static func setVisible(_ columns: [ListerColumn]) {
        UserDefaults.standard.set(columns.filter { $0 != .name }.map(\.rawValue), forKey: key)
        NotificationCenter.default.post(name: .columnsChanged, object: nil)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: widthsKey)
        NotificationCenter.default.post(name: .columnsChanged, object: nil)
    }

    // MARK: Widths the user dragged. Name is not stored: it always takes what the others leave.

    private static let widthsKey = "columnWidths"

    private static var storedWidths: [String: Double] {
        UserDefaults.standard.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
    }

    /// The remembered width of a column, or its default; never below the column's minimum.
    static func width(of column: ListerColumn) -> CGFloat {
        guard column != .name, let stored = storedWidths[column.rawValue] else { return column.defaultWidth }
        return max(column.minWidth, CGFloat(stored))
    }

    static func setWidth(_ width: CGFloat, of column: ListerColumn) {
        guard column != .name else { return }
        var widths = storedWidths
        widths[column.rawValue] = Double(max(column.minWidth, width))
        UserDefaults.standard.set(widths, forKey: widthsKey)
    }
}

/// Finder comment (Spotlight comment) kept in an extended attribute.
enum FinderMetadata {
    private static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    static func comment(of url: URL) -> String? {
        let size = getxattr(url.path, commentAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, commentAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String
    }

    /// An empty or nil comment removes the attribute.
    static func setComment(_ text: String?, on url: URL) throws {
        if let text, !text.isEmpty {
            let data = try PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)
            let status = data.withUnsafeBytes { setxattr(url.path, commentAttribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
            if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else if comment(of: url) != nil {
            if removexattr(url.path, commentAttribute, XATTR_NOFOLLOW) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}
