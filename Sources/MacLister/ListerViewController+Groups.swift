import AppKit

/// Groups in the lister, as in Finder: a header above each run of files (the title, how many), in the list and in the
/// icon view. `rows` stays the plain list of files in the order shown, so everything that works on files (selection,
/// menus, drag, Quick Look) is unaffected; the headers only add rows to the table (`tableEntries`) or sections to the
/// grid (`ListerCollectionView.sectionStarts`). Where the files are not grouped, all of the mappings here are the identity.
extension ListerViewController {
    var isGrouped: Bool { !groups.isEmpty }

    /// Works out the groups of the rows that were just set (`rows` is already in order).
    func updateGroups() {
        groups = Grouping.layout(of: rows, by: model.effectiveGroup)
        tableEntries = []
        itemTableRows = []
        if !groups.isEmpty {
            tableEntries.reserveCapacity(rows.count + groups.count)
            itemTableRows = Array(repeating: 0, count: rows.count)
            for (index, group) in groups.enumerated() {
                tableEntries.append(-(index + 1))
                for row in group.range {
                    itemTableRows[row] = tableEntries.count
                    tableEntries.append(row)
                }
            }
        }
        collectionView.sectionStarts = groups.map(\.range.lowerBound)
        if let flow = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            flow.headerReferenceSize = NSSize(width: 0, height: isGrouped ? GroupHeaderView.height : 0)
        }
        tableView.isGroupHeader = { [weak self] in self?.isHeaderTableRow($0) ?? false }
    }

    /// Reloads the icon view. Headers left over from before (a grid that was hidden while the grouping changed keeps
    /// them, and they would show through the new ones) are taken away first.
    func reloadGrid() {
        for header in collectionView.subviews where header is GroupHeaderView { header.removeFromSuperview() }
        collectionView.reloadData()
    }

    func isHeaderTableRow(_ tableRow: Int) -> Bool { groupIndex(forTableRow: tableRow) != nil }

    /// The group a table row is the header of.
    func groupIndex(forTableRow tableRow: Int) -> Int? {
        guard tableEntries.indices.contains(tableRow), tableEntries[tableRow] < 0 else { return nil }
        return -tableEntries[tableRow] - 1
    }

    /// The table row a file is shown in.
    func tableRow(forRow row: Int) -> Int {
        guard isGrouped else { return row }
        return itemTableRows.indices.contains(row) ? itemTableRows[row] : -1
    }

    /// The file a table row shows; nil for a group header and for no row at all.
    func row(forTableRow tableRow: Int) -> Int? {
        guard isGrouped else { return tableRow >= 0 ? tableRow : nil }
        guard tableEntries.indices.contains(tableRow), tableEntries[tableRow] >= 0 else { return nil }
        return tableEntries[tableRow]
    }

    /// What a drop on a table row means: on a group header, or between rows, it goes into the folder shown.
    func dropTarget(forTableRow tableRow: Int, operation: NSTableView.DropOperation) -> (row: Int, operation: NSTableView.DropOperation) {
        guard isGrouped else { return (tableRow, operation) }
        guard let row = row(forTableRow: tableRow) else { return (-1, .above) }
        return (row, operation)
    }
}

/// The header of a group: its title and how many files it holds. The list shows it as a group row (it floats at the
/// top while the group scrolls), the icon view as a header of a section, with a line under it.
final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")
    static let height: CGFloat = 34

    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let line = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        line.boxType = .separator
        for view in [title, count, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ group: RowGroup) {
        title.stringValue = group.title
        count.stringValue = trCount("%d items", group.range.count)
    }

    /// The text on show (self-tests).
    var shownTitle: String { title.stringValue }
}
