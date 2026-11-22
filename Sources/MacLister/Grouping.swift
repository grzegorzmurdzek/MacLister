import AppKit
import CoreServices
import UniformTypeIdentifiers

/// What the files of a folder are grouped by (Finder's View → Use Groups / Group By). Under each group's title the
/// files stay in the order of the sort column.
enum GroupKey: String, CaseIterable {
    case none, name, kind, application, lastOpened, added, modified, created, size, tags

    var title: String {
        switch self {
        case .none: return tr("None")
        case .name: return tr("Name")
        case .kind: return tr("Kind")
        case .application: return tr("Application")
        case .lastOpened: return tr("Date Last Opened")
        case .added: return tr("Date Added")
        case .modified: return tr("Date Modified")
        case .created: return tr("Date Created")
        case .size: return tr("Size")
        case .tags: return tr("Tags")
        }
    }

    /// The data a file has to carry for this grouping (read from disk only while it is used).
    var needsKind: Bool { self == .kind }
    var needsCreated: Bool { self == .created }
    var needsTags: Bool { self == .tags }
}

/// The group a file belongs to: `order` puts the groups in a row (Today before Yesterday, "A" before "B"), the
/// title tells groups of the same order apart and is what the header shows.
struct GroupBucket: Comparable, Hashable {
    let order: Int
    let title: String

    static func < (a: GroupBucket, b: GroupBucket) -> Bool {
        a.order != b.order ? a.order < b.order : a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

/// A run of rows under one header: `range` indexes the lister's rows.
struct RowGroup: Equatable {
    let title: String
    let range: Range<Int>
}

enum Grouping {
    /// Which group a file goes into.
    static func bucket(for item: FileItem, by key: GroupKey, now: Date = Date(), calendar: Calendar = .current) -> GroupBucket {
        switch key {
        case .none:
            return GroupBucket(order: 0, title: "")
        case .name:
            let first = item.name.first.map { String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased() } ?? ""
            return first.first?.isLetter == true ? GroupBucket(order: 1, title: first) : GroupBucket(order: 0, title: "#")
        case .kind:
            return GroupBucket(order: 0, title: item.kind ?? (item.isDirectory ? tr("Folder") : tr("Unknown")))
        case .application:
            return item.application.map { GroupBucket(order: 0, title: $0) } ?? GroupBucket(order: 1, title: tr("None"))
        case .lastOpened:
            return dateBucket(item.lastOpened, missing: tr("Never"), now: now, calendar: calendar)
        case .added:
            return dateBucket(item.added, missing: tr("Unknown"), now: now, calendar: calendar)
        case .modified:
            return dateBucket(item.modified, missing: tr("Unknown"), now: now, calendar: calendar)
        case .created:
            return dateBucket(item.created, missing: tr("Unknown"), now: now, calendar: calendar)
        case .size:
            return sizeBucket(item)
        case .tags:
            let first = item.tags.min { $0.localizedStandardCompare($1) == .orderedAscending }     // a file with several tags is under the first
            return first.map { GroupBucket(order: 0, title: $0) } ?? GroupBucket(order: 1, title: tr("No Tag"))
        }
    }

    /// Today, Yesterday, the last 7 and 30 days, then a month for each of the rest of this year, then a year each.
    static func dateBucket(_ date: Date?, missing: String, now: Date, calendar: Calendar) -> GroupBucket {
        guard let date else { return GroupBucket(order: 100_000, title: missing) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return GroupBucket(order: 0, title: tr("Today"))
        case 1: return GroupBucket(order: 1, title: tr("Yesterday"))
        case 2...7: return GroupBucket(order: 2, title: tr("Previous 7 Days"))
        case 8...30: return GroupBucket(order: 3, title: tr("Previous 30 Days"))
        default:
            let (then, today) = (calendar.dateComponents([.year, .month], from: date), calendar.dateComponents([.year, .month], from: now))
            if let year = then.year, let month = then.month, year == today.year, let thisMonth = today.month {
                let name = monthName(month, calendar: calendar)
                return GroupBucket(order: 10 + max(thisMonth - month, 0), title: name)
            }
            let year = then.year ?? 0
            return GroupBucket(order: 100 + max((today.year ?? year) - year, 0), title: String(year))
        }
    }

    private static func monthName(_ month: Int, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        let name = formatter.standaloneMonthSymbols[(month - 1) % 12]
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Folders first, then from the largest files down.
    static func sizeBucket(_ item: FileItem) -> GroupBucket {
        if item.isDirectory { return GroupBucket(order: 0, title: tr("Folders")) }
        guard let size = item.size else { return GroupBucket(order: 100, title: tr("Unknown")) }
        switch size {
        case 1_000_000_000...: return GroupBucket(order: 1, title: tr("1 GB or more"))
        case 100_000_000...: return GroupBucket(order: 2, title: "100 MB – 1 GB")
        case 10_000_000...: return GroupBucket(order: 3, title: "10 – 100 MB")
        case 1_000_000...: return GroupBucket(order: 4, title: "1 – 10 MB")
        case 100_000...: return GroupBucket(order: 5, title: "100 KB – 1 MB")
        case 1_000...: return GroupBucket(order: 6, title: "1 – 100 KB")
        case 1...: return GroupBucket(order: 7, title: tr("Under 1 KB"))
        default: return GroupBucket(order: 8, title: tr("Empty"))
        }
    }

    /// The runs of equal groups in a list that is already in order.
    static func layout(of items: [FileItem], by key: GroupKey) -> [RowGroup] {
        guard key != .none, !items.isEmpty else { return [] }
        var groups: [RowGroup] = []
        var start = 0
        var current = bucket(for: items[0], by: key)
        for index in 1..<items.count {
            let next = bucket(for: items[index], by: key)
            if next != current {
                groups.append(RowGroup(title: current.title, range: start..<index))
                (start, current) = (index, next)
            }
        }
        groups.append(RowGroup(title: current.title, range: start..<items.count))
        return groups
    }
}

/// The data the grouping needs that listing a folder does not give: the application a file opens with, and when it
/// was last opened.
enum GroupingData {
    private static var applicationNames: [String: String] = [:]      // content type → application ("" : none)

    /// The name of the application that opens this kind of file, nil for folders and files nothing opens.
    static func applicationName(for url: URL, type: UTType?, isDirectory: Bool) -> String? {
        guard !isDirectory, let type else { return nil }
        if let known = applicationNames[type.identifier] { return known.isEmpty ? nil : known }
        let name = NSWorkspace.shared.urlForApplication(toOpen: type).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        } ?? ""
        applicationNames[type.identifier] = name
        return name.isEmpty ? nil : name
    }

    /// Spotlight's "last opened", the date Finder shows as Date Last Opened.
    static func lastOpened(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
