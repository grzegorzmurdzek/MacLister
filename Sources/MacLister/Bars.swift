import SwiftUI

/// Top bar: Back, Parent and an editable path field.
struct PathBarView: View {
    @ObservedObject var model: ListerModel
    var onToggleRole: (ListerRole) -> Void
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var history = PathHistory.shared
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back")

                Button { model.goParent() } label: { Label("Parent", systemImage: "arrow.up") }
                    .disabled(!model.canGoParent)
                    .help("Go to the enclosing folder")

                goMenu

                TextField("Path", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit {
                        if !model.navigate(toPath: text) { text = model.url.path }
                    }

                roleButton(.source, title: "SRC", tint: .blue, help: "Make this lister the source of Copy / Move")
                roleButton(.destination, title: "DST", tint: .orange, help: "Make this lister the destination of Copy / Move")
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)

            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(model.$url) { text = $0.path }
    }
}

extension PathBarView {
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
            Section("Bookmarks") {
                ForEach(bookmarks.paths, id: \.self) { path in
                    Button { model.navigate(to: URL(fileURLWithPath: path)) } label: { Text(Self.short(path)) }
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
                        Button { model.navigate(to: URL(fileURLWithPath: path)) } label: { Text(Self.short(path)) }
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
            Text(title)
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

/// Bottom bar: configurable buttons (buttons.json) and a status line.
struct ButtonBarView: View {
    @ObservedObject var model: ListerModel
    @ObservedObject var store: ButtonStore
    var onAction: (ListerButton) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(store.buttons.enumerated()), id: \.offset) { _, button in
                            Button { onAction(button) } label: { label(for: button) }
                                .disabled(button.needsSelection && model.selectedURLs.isEmpty)
                                .help(button.help ?? button.title)
                        }
                    }
                }
                status.layoutPriority(1)
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func label(for button: ListerButton) -> some View {
        if let symbol = button.symbol, !symbol.isEmpty {
            Label(button.title, systemImage: symbol)
        } else {
            Text(button.title)
        }
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
