import SwiftUI

/// Toolbar look: borderless icon, tinted when enabled, soft rounded highlight on hover and press.
struct ToolbarIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var iconSize: CGFloat = 16
    /// Draw the button pressed although the system button never saw the press (a button with a menu answers the mouse itself).
    var forcePressed = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, tint: tint, iconSize: iconSize, forcePressed: forcePressed)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let iconSize: CGFloat
        let forcePressed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: iconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.45))
                .padding(.horizontal, 6)
                .frame(minWidth: 34, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed || forcePressed ? 0.20 : (hovering && isEnabled ? 0.10 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ListerButton {
    /// Icon colour from the `color` field; neutral when unset or unknown.
    var tint: Color {
        LabelPalette.color(color) ?? .primary
    }

    static let knownColors = ["blue", "green", "orange", "red", "purple", "teal", "pink", "yellow", "brown", "gray"]
}

/// Top bar: Back, Parent and an editable path field.
struct PathBarView: View {
    @ObservedObject var model: ListerModel
    var onToggleRole: (ListerRole) -> Void
    /// Locks / unlocks the role of this lister (taking the role first when it does not hold it): ⌥-click or right-click.
    var onToggleRoleLock: (ListerRole) -> Void = { _ in }
    var onConnect: (ServerProfile?) -> Void
    var onEditLabel: () -> Void = {}
    /// Icon size chosen in the view button's menu.
    var onIconSize: (CGFloat) -> Void = { Settings.iconSize = $0 }
    @ObservedObject private var servers = ServerStore.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var history = PathHistory.shared
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(ToolbarIconButtonStyle(iconSize: 14))
                    .disabled(!model.canGoBack)
                    .help("Back (right-click for the folders you came from)")
                    .contextMenu {
                        ForEach(Array(model.backHistory.prefix(20).enumerated()), id: \.offset) { index, url in
                            Button(Self.historyTitle(url)) { model.goBack(steps: index + 1) }
                        }
                    }

                Button { model.goParent() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(ToolbarIconButtonStyle(iconSize: 14))
                    .disabled(!model.canGoParent)
                    .help("Go to the enclosing folder")

                goMenu

                pathField

                if !model.label.isEmpty || model.labelColor != nil { labelBadge }

                Button { model.setShowAsIcons(!model.showAsIcons) } label: {
                    Image(systemName: model.showAsIcons ? "list.bullet" : "square.grid.2x2")
                }
                .buttonStyle(ToolbarIconButtonStyle(iconSize: 14))
                .help(model.showAsIcons ? "Show as a list (⌘2); right-click: sort order, icon size" : "Show as icons (⌘1); right-click: sort order, icon size")
                .contextMenu { viewMenuItems }

                roleButton(.source, title: "SRC", tint: .blue, help: "Make this lister the source of Copy / Move")
                roleButton(.destination, title: "DST", tint: .orange, help: "Make this lister the destination of Copy / Move")
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)

            Divider()
        }
        .background(.bar)
        .onReceive(model.$url) { text = ListerModel.displayPath($0) }
    }
}

extension PathBarView {
    /// "Documents — ~/Documents" for the Back menu.
    static func historyTitle(_ url: URL) -> String {
        if let title = VirtualPlace.title(for: url) { return title }
        if ArchiveBrowser.shared.location(of: url) != nil { return ListerModel.displayPath(url) }
        if RemoteURL.isRemote(url) { return RemoteURL.serverLabel(of: url) + RemoteURL.path(of: url) }
        let name = FileManager.default.displayName(atPath: url.path)
        return url.path == "/" ? name : "\(name) — \(PathText.short(url.path))"
    }

    /// The name the user gave this lister, as a coloured tag; click to change it.
    fileprivate var labelBadge: some View {
        let tint = LabelPalette.color(model.labelColor) ?? Color.secondary
        return Button(action: onEditLabel) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 7, height: 7)
                if !model.label.isEmpty { Text(model.label).lineLimit(1).truncationMode(.tail) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
            .frame(maxWidth: 140)
        }
        .buttonStyle(.plain)
        .help("Name of this lister (click to change)")
    }

    /// Clickable breadcrumb; clicking the empty part (or ⌘L) switches to an editable text field.
    @ViewBuilder
    fileprivate var pathField: some View {
        if model.editingPath {
            TextField("Path", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit {
                    if model.navigate(toPath: text) { model.editingPath = false } else { text = ListerModel.displayPath(model.url) }
                }
                .onExitCommand { model.editingPath = false }
                .onAppear {
                    text = ListerModel.displayPath(model.url)
                    DispatchQueue.main.async { fieldFocused = true }
                }
                .onChange(of: fieldFocused) { focused in if !focused { model.editingPath = false } }
        } else {
            BreadcrumbView(url: model.url, onSelect: { model.navigate(to: $0) }, onEdit: { model.editingPath = true })
        }
    }

    /// Under a right-click on the view button: icons or list, the size of the icons, and the sort order.
    @ViewBuilder
    fileprivate var viewMenuItems: some View {
        Toggle(tr("as Icons"), isOn: Binding(get: { model.showAsIcons }, set: { _ in model.setShowAsIcons(true) }))
        Toggle(tr("as List"), isOn: Binding(get: { !model.showAsIcons }, set: { _ in model.setShowAsIcons(false) }))
        if model.showAsIcons {
            Menu(tr("Icon Size")) {
                ForEach(IconGridMetrics.sizes, id: \.self) { size in
                    Toggle("\(Int(size)) pt", isOn: Binding(get: { Settings.iconSize == size }, set: { _ in onIconSize(size) }))
                }
            }
        }
        Menu(tr("Sort By")) {
            ForEach(Self.iconSortKeys, id: \.self) { key in
                Toggle(ListerColumn(rawValue: key.rawValue)?.title ?? key.rawValue,
                       isOn: Binding(get: { model.sortKey == key }, set: { _ in model.setSort(key, ascending: model.ascending) }))
            }
            Divider()
            Toggle(tr("Ascending"), isOn: Binding(get: { model.ascending }, set: { _ in model.setSort(model.sortKey, ascending: true) }))
            Toggle(tr("Descending"), isOn: Binding(get: { !model.ascending }, set: { _ in model.setSort(model.sortKey, ascending: false) }))
        }
    }

    fileprivate static let iconSortKeys: [ListerModel.SortKey] = [.name, .size, .date, .created, .kind, .ext]

    /// Magellan's hotlist and path history in one menu.
    fileprivate var goMenu: some View {
        Menu {
            Section("Go to") {
                Button { model.navigate(to: VirtualPlace.recents.url) } label: { Label(VirtualPlace.recents.title, systemImage: VirtualPlace.recents.symbol) }
                ForEach(Self.places, id: \.title) { place in
                    Button { model.navigate(to: place.url) } label: { Label(place.title, systemImage: place.symbol) }
                }
                Button { model.navigate(to: VirtualPlace.devices.url) } label: { Label(VirtualPlace.devices.title, systemImage: VirtualPlace.devices.symbol) }
                ForEach(Self.volumes, id: \.path) { volume in
                    Button { model.navigate(to: volume) } label: { Label(volume.lastPathComponent, systemImage: "externaldrive") }
                }
                Button { model.navigate(to: VirtualPlace.shared.url) } label: { Label(VirtualPlace.shared.title, systemImage: VirtualPlace.shared.symbol) }
            }
            Section("Servers") {
                ForEach(servers.servers) { server in
                    Button { onConnect(server) } label: {
                        Label(server.displayName, systemImage: server.scheme.isEncrypted ? "lock" : "network")
                    }
                }
                Button { onConnect(nil) } label: { Label("Connect to Server…", systemImage: "server.rack") }
                if !servers.servers.isEmpty {
                    Menu("Remove Server") {
                        ForEach(servers.servers) { server in Button(server.displayName) { servers.remove(server) } }
                    }
                }
                if model.isRemote {
                    Button {
                        RemoteSessions.shared.disconnect(model.url)
                        model.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                    } label: { Label("Disconnect from \(RemoteURL.serverLabel(of: model.url))", systemImage: "eject") }
                }
            }
            Section("Bookmarks") {
                ForEach(bookmarks.paths, id: \.self) { path in
                    Button { model.navigate(to: BookmarkStore.url(forKey: path)) } label: { Text(Self.short(path)) }
                }
                if bookmarks.contains(model.url) {
                    Button {} label: { Label("This Folder Is Bookmarked", systemImage: "star.fill") }.disabled(true)
                } else {
                    Button { bookmarks.add(model.url) } label: { Label("Add This Folder", systemImage: "star") }
                        .disabled(model.isVirtual)
                }
                if !bookmarks.paths.isEmpty {
                    Menu("Remove Bookmark") {
                        ForEach(bookmarks.paths, id: \.self) { path in
                            Button(Self.short(path)) { bookmarks.remove(path) }
                        }
                    }
                }
            }
            if !history.recent.isEmpty {
                Section("Recent Folders") {
                    ForEach(history.recent, id: \.self) { path in
                        Button { model.navigate(to: BookmarkStore.url(forKey: path)) } label: { Text(Self.short(path)) }
                    }
                    Divider()
                    Button("Clear Recent Folders…") { HistoryClearing.confirmAndClear(.recentFolders) }
                }
            }
        } label: {
            Text("Go")
        }
        .fixedSize()
        .help("Places, bookmarks and recent folders")
    }

    fileprivate static var places: [(title: String, symbol: String, url: URL)] {
        let fm = FileManager.default
        func user(_ dir: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: dir, in: .userDomainMask).first }
        var result: [(String, String, URL)] = [(tr("Home"), "house", fm.homeDirectoryForCurrentUser)]
        if let u = user(.desktopDirectory) { result.append((tr("Desktop"), "menubar.dock.rectangle", u)) }
        if let u = user(.documentDirectory) { result.append((tr("Documents"), "doc", u)) }
        if let u = user(.downloadsDirectory) { result.append((tr("Downloads"), "arrow.down.circle", u)) }
        result.append((tr("Applications"), "square.grid.2x2", URL(fileURLWithPath: "/Applications")))
        result.append((tr("Root /"), "internaldrive", URL(fileURLWithPath: "/")))
        return result
    }

    fileprivate static var volumes: [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?
            .filter { $0.path != "/" } ?? []
    }

    fileprivate static func short(_ path: String) -> String { PathText.short(path) }

    @ViewBuilder
    fileprivate func roleButton(_ role: ListerRole, title: String, tint: Color, help: String) -> some View {
        let active = model.role == role
        Button {
            if NSEvent.modifierFlags.contains(.option) { onToggleRoleLock(role) } else { onToggleRole(role) }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if active && model.roleLocked { Image(systemName: "lock.fill").imageScale(.small) }
            }
                .font(.system(size: 11, weight: .bold))
                // the lister that holds the role stands out; the other badge is muted, so the active one reads at a glance
                .foregroundStyle(active ? Color.white : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? tint : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .overlay(MiddleClickCatcher { onToggleRoleLock(role) })
        .help(tr(help) + "\n" + tr("⌥-click, middle-click or right-click: lock the role so no other lister can take it"))
        .contextMenu {
            Button(active && model.roleLocked ? tr("Unlock Role") : tr("Lock Role")) { onToggleRoleLock(role) }
        }
    }
}

/// Configurable buttons (buttons.json). Sits under the path bar (like Magellan's button banks) or at the
/// bottom of the window; the divider follows the position.
struct ButtonBarView: View {
    @ObservedObject var model: ListerModel
    @ObservedObject var store: ButtonStore
    var onAction: (ListerButton) -> Void
    /// Off by default: icons only, the title is in the tooltip. Toggled from the menu-bar icon.
    @AppStorage("showButtonLabels") private var showLabels = false
    @AppStorage("buttonBarPosition") private var position = ButtonBarPosition.abovePath.rawValue
    @AppStorage("showButtonMenuArrows") private var showArrows = false
    /// The button (by position) that is held down right now; drawn pressed.
    @State private var pressedIndex: Int?
    private var atBottom: Bool { position == ButtonBarPosition.bottom.rawValue }

    private func canRun(_ button: ListerButton) -> Bool { !(button.needsSelection && model.selectedURLs.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            if atBottom { Divider() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.buttons.enumerated()), id: \.offset) { index, button in
                        if button.action == .separator {
                            Divider().frame(height: 18).padding(.horizontal, 4)
                        } else {
                            Button { onAction(button) } label: { face(for: button) }
                                .buttonStyle(ToolbarIconButtonStyle(tint: button.tint, forcePressed: pressedIndex == index))
                                .disabled(button.needsSelection && model.selectedURLs.isEmpty)
                                .help(help(for: button))
                                .overlay {
                                    // A button with a menu answers the left mouse button itself: click, hold, arrow.
                                    if button.hasMenu {
                                        ButtonMenuTrigger(button: button, showsArrow: showArrows, canRun: canRun, run: onAction) { down in
                                            if down { pressedIndex = index } else if pressedIndex == index { pressedIndex = nil }
                                        }
                                    }
                                }
                                .overlay {
                                    if button.hasExtraClicks {
                                        MouseButtonCatcher { click in
                                            guard let variant = button.variant(for: click) else { return }
                                            if variant.needsSelection && model.selectedURLs.isEmpty { NSSound.beep(); return }
                                            onAction(variant)
                                        }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
            }
            .controlSize(.regular)
            if !atBottom { Divider() }
        }
        .background(.bar)
    }

    private func help(for button: ListerButton) -> String {
        let base = (button.help ?? button.action.defaultHelp).map { "\(tr(button.title)) – \(tr($0))" } ?? tr(button.title)
        return button.hasExtraClicks || button.hasMenu ? base + "\n" + button.clickHelp : base
    }

    /// The button's face; with the arrow setting on, a button that has a menu gets a small arrow.
    @ViewBuilder
    private func face(for button: ListerButton) -> some View {
        if button.hasMenu && showArrows {
            HStack(spacing: 3) {
                label(for: button)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.75)
            }
        } else {
            label(for: button)
        }
    }

    /// Your own picture, shown as it is (no tint) at the size of the symbols.
    private func pictureView(_ picture: NSImage) -> some View {
        Image(nsImage: picture).resizable().scaledToFit().frame(width: 18, height: 18)
    }

    @ViewBuilder
    private func label(for button: ListerButton) -> some View {
        if let picture = ButtonIcons.image(named: button.iconFile) {
            if showLabels {
                HStack(spacing: 5) { pictureView(picture); Text(tr(button.title)) }
            } else {
                pictureView(picture)
            }
        } else if let symbol = button.symbol, !symbol.isEmpty {
            if showLabels { Label(tr(button.title), systemImage: symbol) } else { Image(systemName: symbol) }
        } else {
            Text(tr(button.title))
        }
    }
}

/// Thin status line at the bottom: item count, selection size, filter, progress and errors.
struct StatusBarView: View {
    @ObservedObject var model: ListerModel
    @ObservedObject private var queue = TransferQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if let progress = model.progress {
                    // The bar and the Cancel button come first and have a fixed size, so Cancel stays where it is
                    // whatever the file name or the text after it is; the text takes what is left.
                    // Clicking the bar or its text opens the details window (speed, graph, Pause).
                    let showDetails = { if let details = progress.details { TransferDetailsWindows.show(details) } }
                    Button(action: showDetails) {
                        Group {
                            if let fraction = progress.fraction {
                                ProgressView(value: min(max(fraction, 0), 1))
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }
                        .frame(width: 150, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show details: speed, graph, pause")
                    Button { progress.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
                    if !queue.waiting.isEmpty { queueMenu }
                    Button(action: showDetails) {
                        Text(progress.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show details: speed, graph, pause")
                } else {
                    status
                }
                Spacer(minLength: 0)
            }
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Operations waiting for the running one; each can be removed from the queue.
    private var queueMenu: some View {
        Menu {
            ForEach(queue.waiting) { item in
                Button { TransferQueue.shared.cancelWaiting(item.id) } label: {
                    Label(tr("Remove from queue: %@", item.detail), systemImage: "xmark.circle")
                }
            }
        } label: {
            Text(tr("In queue: %d", queue.waiting.count)).font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Operations that wait for the running one. Choose one to remove it from the queue.")
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption)
                .help(error)
        } else if let message = model.statusMessage {
            Text(message)
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
        } else {
            let selected = model.selectedURLs.count
            let bytes = model.selectedBytes
            let sizeText = bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
            let filterText = model.filter.isEmpty ? "" : " · " + tr("filter: %@", model.filter)
            Text((selected > 0 ? tr("%d of %d selected", selected, model.items.count) + sizeText : trCount("%d items", model.items.count)) + filterText)
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

/// Path as clickable segments (Ambient style). Long paths scroll to keep the current folder visible.
struct BreadcrumbView: View {
    let url: URL
    var onSelect: (URL) -> Void
    var onEdit: () -> Void

    var body: some View {
        let segments = PathSegments.make(for: url)
        let path = HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
                SegmentButton(title: segment.title, isCurrent: index == segments.count - 1) { onSelect(segment.url) }
            }
        }
        .fixedSize()
        .padding(.horizontal, 4)
        // A path that fits starts at the left, like a path field. A long one shows its tail (the folder you are in)
        // and fades out at the left; the Go menu and the Parent button lead to the earlier folders.
        GeometryReader { geometry in
            ViewThatFits(in: .horizontal) {
                path.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)      // its own width decides whether it fits
                path
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)   // centred vertically, tail of the path at the right
                    .clipShape(Rectangle())
                    .contentShape(Rectangle())          // the part of a long path that is cut off must not take clicks meant for Back and Up
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                            Color.black
                        }
                    )
            }
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.14)))
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)
        )
        .help("Click a folder to go there; click the empty part (or press ⌘L) to type a path")
    }

    private struct SegmentButton: View {
        let title: String
        let isCurrent: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.10 : 0)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}


/// Sits on top of a toolbar button and answers only the right and the middle mouse button; the left one
/// passes through to the button underneath.
struct MouseButtonCatcher: NSViewRepresentable {
    var onClick: (ListerButton.Click) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onClick = onClick }

    final class CatcherView: NSView {
        var onClick: (ListerButton.Click) -> Void = { _ in }

        /// Only right and middle button events are ours; everything else falls through to the button.
        static func accepts(_ type: NSEvent.EventType?) -> Bool {
            switch type {
            case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: return true
            default: return false
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.accepts(NSApp.currentEvent?.type) ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { onClick(.right) }
        override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { onClick(.middle) } }
    }
}

/// Reports a click with the middle mouse button on the view it sits over. SwiftUI buttons only know the left button;
/// this transparent view takes part in hit testing for the middle button alone, so every other click passes through.
struct MiddleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseDown(with event: NSEvent) {}
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        }
    }
}
