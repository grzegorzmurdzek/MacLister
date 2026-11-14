import SwiftUI

/// Toolbar look: borderless icon, tinted when enabled, soft rounded highlight on hover and press.
struct ToolbarIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var iconSize: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, tint: tint, iconSize: iconSize)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let iconSize: CGFloat
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
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.20 : (hovering && isEnabled ? 0.10 : 0)))
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
        switch color?.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "teal": return .teal
        case "pink": return .pink
        case "yellow": return .yellow
        case "brown": return .brown
        case "gray", "grey": return .gray
        default: return .primary
        }
    }

    static let knownColors = ["blue", "green", "orange", "red", "purple", "teal", "pink", "yellow", "brown", "gray"]
}

/// Top bar: Back, Parent and an editable path field.
struct PathBarView: View {
    @ObservedObject var model: ListerModel
    var onToggleRole: (ListerRole) -> Void
    var onConnect: (ServerProfile?) -> Void
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
                    .help("Back")

                Button { model.goParent() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(ToolbarIconButtonStyle(iconSize: 14))
                    .disabled(!model.canGoParent)
                    .help("Go to the enclosing folder")

                goMenu

                pathField

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

    /// Magellan's hotlist and path history in one menu.
    fileprivate var goMenu: some View {
        Menu {
            Section("Go to") {
                ForEach(Self.places, id: \.title) { place in
                    Button { model.navigate(to: place.url) } label: { Label(place.title, systemImage: place.symbol) }
                }
                ForEach(Self.volumes, id: \.path) { volume in
                    Button { model.navigate(to: volume) } label: { Label(volume.lastPathComponent, systemImage: "externaldrive") }
                }
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
                Button { bookmarks.add(model.url) } label: { Label("Add This Folder", systemImage: "star") }
                    .disabled(bookmarks.contains(model.url))
                if !bookmarks.paths.isEmpty {
                    Menu("Remove Bookmark") {
                        ForEach(bookmarks.paths, id: \.self) { path in
                            Button(Self.short(path)) { bookmarks.remove(path) }
                        }
                    }
                }
            }
            if !history.recent.isEmpty {
                Section("Recent") {
                    ForEach(history.recent, id: \.self) { path in
                        Button { model.navigate(to: BookmarkStore.url(forKey: path)) } label: { Text(Self.short(path)) }
                    }
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
        var result: [(String, String, URL)] = [("Home", "house", fm.homeDirectoryForCurrentUser)]
        if let u = user(.desktopDirectory) { result.append(("Desktop", "menubar.dock.rectangle", u)) }
        if let u = user(.documentDirectory) { result.append(("Documents", "doc", u)) }
        if let u = user(.downloadsDirectory) { result.append(("Downloads", "arrow.down.circle", u)) }
        result.append(("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications")))
        result.append(("Root /", "internaldrive", URL(fileURLWithPath: "/")))
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
        Button { onToggleRole(role) } label: {
            HStack(spacing: 3) {
                Text(title)
                if active && model.roleLocked { Image(systemName: "lock.fill").imageScale(.small) }
            }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? Color.white : tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? tint : tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(help)
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
    private var atBottom: Bool { position == ButtonBarPosition.bottom.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            if atBottom { Divider() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.buttons.enumerated()), id: \.offset) { _, button in
                        if button.action == .separator {
                            Divider().frame(height: 18).padding(.horizontal, 4)
                        } else {
                            Button { onAction(button) } label: { label(for: button) }
                                .buttonStyle(ToolbarIconButtonStyle(tint: button.tint))
                                .disabled(button.needsSelection && model.selectedURLs.isEmpty)
                                .help(button.help.map { "\(button.title) – \($0)" } ?? button.title)
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

    @ViewBuilder
    private func label(for button: ListerButton) -> some View {
        if let symbol = button.symbol, !symbol.isEmpty {
            if showLabels { Label(button.title, systemImage: symbol) } else { Image(systemName: symbol) }
        } else {
            Text(button.title)
        }
    }
}

/// Thin status line at the bottom: item count, selection size, filter, progress and errors.
struct StatusBarView: View {
    @ObservedObject var model: ListerModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if let progress = model.progress {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(width: 150)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(progress.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button { progress.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
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
            let filterText = model.filter.isEmpty ? "" : " · filter: \(model.filter)"
            Text((selected > 0 ? "\(selected) of \(model.items.count) selected\(sizeText)" : "\(model.items.count) items") + filterText)
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                        }
                        SegmentButton(title: segment.title, isCurrent: index == segments.count - 1) { onSelect(segment.url) }
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
            }
            .onAppear { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
            .onChange(of: url) { _ in
                DispatchQueue.main.async { proxy.scrollTo(PathSegments.make(for: url).count - 1, anchor: .trailing) }
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
