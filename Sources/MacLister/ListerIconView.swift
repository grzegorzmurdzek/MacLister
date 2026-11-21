import AppKit

/// Sizes of the icon view.
enum IconGridMetrics {
    /// The sizes of the pictures the Icon Size menu offers (points).
    static let sizes: [CGFloat] = [32, 48, 64, 96, 128]
    static let defaultSize: CGFloat = 64

    /// The cell of one file: the picture with a margin, and room for two lines of name below it.
    static func cellSize(forIcon icon: CGFloat) -> NSSize {
        NSSize(width: max(icon + 40, 88), height: icon + 56)
    }
}

/// NSCollectionView for the icon view of a lister. Like the list it gives key presses to the lister first (Space,
/// Return, Backspace, ⌘↑ …), reports a double-click, knows the item under a right-click, takes part in Services,
/// and selects with a rubber band drawn from empty space (a collection view has none of its own).
final class ListerCollectionView: NSCollectionView, NSServicesMenuRequestor {
    var keyHandler: ((NSEvent) -> Bool)?
    /// The drag left the view or ended (spring-loaded folders stop waiting).
    var onDragEnd: (() -> Void)?
    /// A double-click on an item: its index.
    var onDoubleClick: ((Int) -> Void)?
    /// The selection was changed by code or by the rubber band (the collection view does not tell its delegate then).
    var onSelectionChange: (() -> Void)?
    var servicesURLs: () -> [URL] = { [] }
    /// The item under the last right-click, -1 for empty space.
    private(set) var clickedItem = -1

    // Only through super when NSCollectionView has the method (see ListerTableView: macOS 27 crashed on a missing one).
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragEnd?()
        if DragDestination.superHas(#selector(NSDraggingDestination.draggingExited(_:)), in: NSCollectionView.self) { super.draggingExited(sender) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragEnd?()
        if DragDestination.superHas(#selector(NSDraggingDestination.draggingEnded(_:)), in: NSCollectionView.self) { super.draggingEnded(sender) }
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let sendType, FinderServices.sendTypes.contains(sendType), !servicesURLs().isEmpty { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        FinderServices.write(servicesURLs(), to: pboard, types: types)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedItem = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item ?? -1
        return super.menu(for: event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) {                  // Control-click is a right-click
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { onDoubleClick?(path.item) }
        } else {
            rubberBand(from: point, event: event)
        }
    }

    /// Press on empty space and drag: the items the rectangle touches are selected (⌘ or ⇧ add to what was selected).
    private func rubberBand(from start: NSPoint, event: NSEvent) {
        let extend = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        let base = extend ? selectionIndexPaths : []
        let band = NSView()
        band.wantsLayer = true
        let accent = NSColor.controlAccentColor
        band.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        band.layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
        band.layer?.borderWidth = 1
        var moved = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !moved {
                let here = convert(next.locationInWindow, from: nil)
                if hypot(here.x - start.x, here.y - start.y) < 3 { continue }
                moved = true
                addSubview(band)
            }
            autoscroll(with: next)
            let here = convert(next.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, here.x), y: min(start.y, here.y), width: abs(here.x - start.x), height: abs(here.y - start.y))
            band.frame = rect
            let hit = collectionViewLayout?.layoutAttributesForElements(in: rect)
                .filter { $0.representedElementCategory == .item }.compactMap(\.indexPath) ?? []
            selectionIndexPaths = base.union(hit)
            onSelectionChange?()
        }
        band.removeFromSuperview()
        if !moved, !extend, !selectionIndexPaths.isEmpty {
            selectionIndexPaths = []
            onSelectionChange?()
        }
    }
}

/// The view of one cell: tells its item when the interface turns light or dark (layer colours do not follow it).
private final class IconCellView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// One file in the icon view: a picture, with a grey plate behind it when selected, and the name under it (two lines,
/// on the accent colour when selected, as Finder does).
final class IconGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconGridItem")

    private let plate = NSView()
    private let namePlate = NSView()
    private let picture = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var iconConstraints: [NSLayoutConstraint] = []
    private var hidden = false

    /// The field the name is edited in (Rename).
    var nameField: NSTextField { label }

    override func loadView() {
        let cell = IconCellView()
        cell.onAppearanceChange = { [weak self] in self?.refreshLook() }
        view = cell

        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        namePlate.wantsLayer = true
        namePlate.layer?.cornerRadius = 4
        picture.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = .systemFont(ofSize: 11.5)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byCharWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        label.drawsBackground = false

        for v in [plate, picture, namePlate, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        imageView = picture
        textField = label
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            plate.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            picture.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            picture.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            namePlate.topAnchor.constraint(equalTo: plate.bottomAnchor, constant: 2),
            namePlate.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            namePlate.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: namePlate.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: namePlate.bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: namePlate.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: namePlate.trailingAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -10),
        ])
    }

    func configure(with file: FileItem, iconSize: CGFloat) {
        picture.image = ListerViewController.icon(for: file)
        label.stringValue = file.name
        label.toolTip = file.name
        hidden = file.isHidden
        NSLayoutConstraint.deactivate(iconConstraints)
        iconConstraints = [
            picture.widthAnchor.constraint(equalToConstant: iconSize),
            picture.heightAnchor.constraint(equalToConstant: iconSize),
            plate.widthAnchor.constraint(equalToConstant: iconSize + 12),
            plate.heightAnchor.constraint(equalToConstant: iconSize + 12),
        ]
        NSLayoutConstraint.activate(iconConstraints)
        refreshLook()
    }

    override var isSelected: Bool { didSet { refreshLook() } }

    override var highlightState: NSCollectionViewItem.HighlightState { didSet { refreshLook() } }

    private func refreshLook() {
        guard isViewLoaded else { return }
        let dropTarget = highlightState == .asDropTarget
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            plate.layer?.backgroundColor = (isSelected || dropTarget ? NSColor.unemphasizedSelectedContentBackgroundColor : .clear).cgColor
            plate.layer?.borderColor = NSColor.controlAccentColor.cgColor
            plate.layer?.borderWidth = dropTarget ? 2 : 0
            namePlate.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor : .clear).cgColor
        }
        label.textColor = isSelected ? .alternateSelectedControlTextColor : (hidden ? .secondaryLabelColor : .labelColor)
        picture.alphaValue = hidden ? 0.5 : 1
    }
}
