import AppKit

/// Columns of the file list. Name is always shown; the others can be switched on and off by
/// right-clicking the column header.
enum ListerColumn: String, CaseIterable {
    case name, size, bytes, date, created, kind, ext, permissions, tags, comment, folder
    /// Only in the Devices and Places list, which always shows them; the column menu does not offer them.
    case used, free, usage

    var isForDevicesOnly: Bool { self == .used || self == .free || self == .usage }

    var title: String {
        switch self {
        case .name: return tr("Name")
        case .size: return tr("Size")
        case .bytes: return tr("Size in Bytes")
        case .date: return tr("Modified")
        case .created: return tr("Created")
        case .kind: return tr("Kind")
        case .ext: return tr("Extension")
        case .permissions: return tr("Permissions")
        case .tags: return tr("Tags")
        case .comment: return tr("Comment")
        case .folder: return tr("Where")
        case .used: return tr("Used")
        case .free: return tr("Free")
        case .usage: return tr("Usage")
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 260
        case .size: return 76
        case .bytes: return 110
        case .date, .created: return 176
        case .kind: return 150
        case .ext: return 80
        case .permissions: return 96
        case .tags: return 150
        case .comment: return 220
        case .folder: return 200
        case .used, .free: return 76
        case .usage: return 130
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 110
        case .size: return 60
        case .bytes: return 70
        case .date, .created: return 120
        case .kind: return 90
        case .ext: return 50
        case .permissions: return 80
        case .tags: return 70
        case .comment: return 80
        case .folder: return 100
        case .used, .free: return 60
        case .usage: return 80
        }
    }

    var rightAligned: Bool { self == .size || self == .bytes || self == .used || self == .free }
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
        return [.name] + ListerColumn.allCases.filter { $0 != .name && !$0.isForDevicesOnly && chosen.contains($0) }
    }

    // The Devices list has three columns of its own (how full each disk is); they are on until switched off there.
    private static let deviceKey = "deviceColumns"

    static var deviceColumns: [ListerColumn] {
        let stored = UserDefaults.standard.stringArray(forKey: deviceKey)
        let chosen = stored.map { $0.compactMap(ListerColumn.init(rawValue:)) } ?? [.used, .free, .usage]
        return ListerColumn.allCases.filter { $0.isForDevicesOnly && chosen.contains($0) }
    }

    static func set(_ column: ListerColumn, visible on: Bool) {
        guard column != .name else { return }
        if column.isForDevicesOnly {
            var chosen = Set(deviceColumns)
            if on { chosen.insert(column) } else { chosen.remove(column) }
            UserDefaults.standard.set(chosen.map(\.rawValue), forKey: deviceKey)
            NotificationCenter.default.post(name: .columnsChanged, object: nil)
            return
        }
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
        UserDefaults.standard.removeObject(forKey: deviceKey)
        NotificationCenter.default.post(name: .columnsChanged, object: nil)
    }

    // MARK: Widths the user dragged. Name is not stored: it always takes what the others leave.

    private static let widthsKey = "columnWidths"

    private static var storedWidths: [String: Double] {
        UserDefaults.standard.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
    }

    /// The dragged widths as they are stored (a workspace keeps them) and put back.
    static var widths: [String: Double] {
        get { storedWidths }
        set { UserDefaults.standard.set(newValue, forKey: widthsKey); NotificationCenter.default.post(name: .columnsChanged, object: nil) }
    }

    /// The remembered width of a column, or its default; never below the column's minimum.
    static func width(of column: ListerColumn) -> CGFloat {
        // A width at the very minimum is not a choice: earlier versions squeezed columns to it in a narrow window and
        // remembered that as if it were dragged, so every list stayed cramped. Those entries are ignored.
        guard column != .name, let stored = storedWidths[column.rawValue], CGFloat(stored) > column.minWidth + 0.5 else { return column.defaultWidth }
        return max(column.minWidth, CGFloat(stored))
    }

    /// The width you gave the Name column by dragging it, in a folder or in the Devices list (which has room for long
    /// disk names). Without one, Name takes what the other columns leave.
    static func nameWidth(devices: Bool) -> CGFloat? {
        guard let stored = storedWidths[devices ? "name.devices" : "name"], CGFloat(stored) > nameMinWidth(devices: devices) + 0.5 else { return nil }
        return CGFloat(stored)
    }

    static func setNameWidth(_ width: CGFloat, devices: Bool) {
        var widths = storedWidths
        widths[devices ? "name.devices" : "name"] = Double(max(nameMinWidth(devices: devices), width))
        UserDefaults.standard.set(widths, forKey: widthsKey)
    }

    /// Disk names are longer than file names, and the Devices list has fewer other columns that need the room.
    static func nameMinWidth(devices: Bool) -> CGFloat { devices ? 220 : ListerColumn.name.minWidth }

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
