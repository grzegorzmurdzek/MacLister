import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Presenting SwiftUI forms as sheets

/// Shows a SwiftUI view as a sheet on a window. The closure given to `content` ends the sheet.
final class SheetPresenter {
    private var panel: NSPanel?

    func present<V: View>(on window: NSWindow, size: NSSize, content: (@escaping () -> Void) -> V) {
        // The closure keeps `self` alive while the sheet is open; closing clears `panel` and breaks the cycle.
        let close: () -> Void = { [self] in
            if let panel { window.endSheet(panel) }
            panel = nil
        }
        let host = NSHostingController(rootView: content(close))
        let panel = NSPanel(contentViewController: host)
        panel.setContentSize(size)
        self.panel = panel
        window.beginSheet(panel)
    }
}

// MARK: - Select by attributes

/// Name, kind, size and date conditions; an item must satisfy every condition that is set.
struct AttributeFilter {
    enum Category: String, CaseIterable, Identifiable {
        case any = "Any", folders = "Folders", files = "Files", images = "Images", audio = "Audio",
             video = "Video", documents = "Documents", archives = "Archives"
        var id: String { rawValue }
    }

    var namePattern = ""
    var category: Category = .any
    var minBytes: Int64?
    var maxBytes: Int64?
    var modifiedWithinDays: Int?
    var modifiedOlderThanDays: Int?

    func matches(_ item: FileItem, now: Date = Date()) -> Bool {
        if !namePattern.isEmpty, !NamePattern.matches(item.name, text: namePattern) { return false }
        if !categoryMatches(item) { return false }
        if let minBytes { guard let size = item.size, size >= minBytes else { return false } }
        if let maxBytes { guard let size = item.size, size <= maxBytes else { return false } }
        if let days = modifiedWithinDays {
            guard let date = item.modified, date >= now.addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        if let days = modifiedOlderThanDays {
            guard let date = item.modified, date < now.addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        return true
    }

    private func categoryMatches(_ item: FileItem) -> Bool {
        switch category {
        case .any: return true
        case .folders: return item.isDirectory
        case .files: return !item.isDirectory
        default:
            guard !item.isDirectory || item.isPackage, let type = UTType(filenameExtension: item.url.pathExtension) else { return false }
            switch category {
            case .images: return type.conforms(to: .image)
            case .audio: return type.conforms(to: .audio)
            case .video: return type.conforms(to: .movie)
            case .archives: return type.conforms(to: .archive)
            case .documents:
                return [UTType.pdf, .text, .rtf, .spreadsheet, .presentation].contains { type.conforms(to: $0) }
            default: return true
            }
        }
    }
}

struct SelectByAttributesView: View {
    var onSelect: (AttributeFilter) -> Void
    var close: () -> Void

    @State private var pattern = ""
    @State private var category = AttributeFilter.Category.any
    @State private var useMin = false
    @State private var minValue = "1"
    @State private var minUnit = 1
    @State private var useMax = false
    @State private var maxValue = "100"
    @State private var maxUnit = 1
    @State private var dateMode = 0            // 0 any, 1 within last, 2 older than
    @State private var days = "7"

    private static let units: [(name: String, bytes: Int64)] = [("KB", 1_000), ("MB", 1_000_000), ("GB", 1_000_000_000)]

    private var filter: AttributeFilter {
        var f = AttributeFilter()
        f.namePattern = pattern.trimmingCharacters(in: .whitespaces)
        f.category = category
        if useMin, let v = Double(minValue.replacingOccurrences(of: ",", with: ".")) { f.minBytes = Int64(v * Double(Self.units[minUnit].bytes)) }
        if useMax, let v = Double(maxValue.replacingOccurrences(of: ",", with: ".")) { f.maxBytes = Int64(v * Double(Self.units[maxUnit].bytes)) }
        if let d = Int(days) {
            if dateMode == 1 { f.modifiedWithinDays = d }
            if dateMode == 2 { f.modifiedOlderThanDays = d }
        }
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Select by Attributes").font(.headline)
            Text("Adds every item that satisfies all the conditions you set to the selection.")
                .font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("e.g. *.jpg IMG_*", text: $pattern).textFieldStyle(.roundedBorder).gridCellColumns(3)
                }
                GridRow {
                    Text("Kind")
                    Picker("", selection: $category) {
                        ForEach(AttributeFilter.Category.allCases) { Text(tr($0.rawValue)).tag($0) }
                    }.labelsHidden().gridCellColumns(3)
                }
                GridRow {
                    Toggle("Larger than", isOn: $useMin)
                    TextField("", text: $minValue).textFieldStyle(.roundedBorder).frame(width: 70).disabled(!useMin)
                    Picker("", selection: $minUnit) { ForEach(0..<3) { Text(Self.units[$0].name).tag($0) } }
                        .labelsHidden().frame(width: 70).disabled(!useMin)
                    Spacer()
                }
                GridRow {
                    Toggle("Smaller than", isOn: $useMax)
                    TextField("", text: $maxValue).textFieldStyle(.roundedBorder).frame(width: 70).disabled(!useMax)
                    Picker("", selection: $maxUnit) { ForEach(0..<3) { Text(Self.units[$0].name).tag($0) } }
                        .labelsHidden().frame(width: 70).disabled(!useMax)
                    Spacer()
                }
                GridRow {
                    Text("Modified")
                    Picker("", selection: $dateMode) {
                        Text("Any time").tag(0)
                        Text("Within the last").tag(1)
                        Text("Older than").tag(2)
                    }.labelsHidden().frame(width: 150)
                    TextField("", text: $days).textFieldStyle(.roundedBorder).frame(width: 60).disabled(dateMode == 0)
                    Text("days").foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Select") { onSelect(filter); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Batch rename

struct BatchRenameView: View {
    let items: [URL]
    var onApply: ([RenameEntry]) -> Void
    var close: () -> Void

    @State private var options: BatchRenameOptions

    init(items: [URL], initial: BatchRenameOptions = BatchRenameOptions(), onApply: @escaping ([RenameEntry]) -> Void, close: @escaping () -> Void) {
        self.items = items
        self.onApply = onApply
        self.close = close
        _options = State(initialValue: initial)
    }

    var body: some View {
        let plan = BatchRename.plan(for: items, options: options)
        let canApply = plan.contains { $0.changes } && plan.allSatisfy { $0.problem == nil }

        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? tr("Rename 1 Item") : trCount("Rename %d Items", items.count)).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Find")
                    TextField("text or pattern", text: $options.find).textFieldStyle(.roundedBorder)
                    Toggle("Regex", isOn: $options.useRegex)
                }
                GridRow {
                    Text("Replace with")
                    TextField(options.useRegex ? tr("use $1, $2 for groups") : "", text: $options.replace).textFieldStyle(.roundedBorder)
                    Toggle("Match case", isOn: $options.caseSensitive)
                }
                GridRow {
                    Text("New name")
                    TextField("e.g. Trip [C]", text: $options.template).textFieldStyle(.roundedBorder)
                    HStack(spacing: 4) {
                        Text("from").foregroundStyle(.secondary)
                        TextField("", value: $options.counterStart, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                        Text("digits").foregroundStyle(.secondary)
                        TextField("", value: $options.counterDigits, format: .number).frame(width: 34).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Letters")
                    Picker("", selection: $options.caseMode) {
                        ForEach(BatchRenameOptions.CaseMode.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    Toggle("Set extension", isOn: $options.changeExtension)
                }
                GridRow {
                    Text("")
                    Text("[N] name · [C] counter · [D] date · [E] extension").font(.caption).foregroundStyle(.secondary)
                    TextField("ext", text: $options.newExtension).textFieldStyle(.roundedBorder).frame(width: 70)
                        .disabled(!options.changeExtension)
                }
            }

            List {
                ForEach(Array(plan.prefix(300).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        Text(entry.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(entry.newName).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(entry.problem != nil ? Color.red : (entry.changes ? Color.primary : Color.secondary))
                        if let problem = entry.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 200)

            HStack {
                Text(canApply ? tr("%d will be renamed", plan.filter(\.changes).count) : (plan.contains { $0.problem != nil } ? tr("Fix the problems in red") : tr("Nothing to rename yet")))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Rename") { onApply(plan); close() }.keyboardShortcut(.defaultAction).disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

// MARK: - Attributes

/// Starting values for the attribute form, taken from the first selected item.
struct AttributeFormState {
    var permissions = 0o644
    var modified = Date()
    var created = Date()
    var hidden = false
    var tags = ""
    var comment = ""
    var anyFolder = false

    static func initial(for urls: [URL]) -> AttributeFormState {
        var state = AttributeFormState()
        let fm = FileManager.default
        if let first = urls.first, let attributes = try? fm.attributesOfItem(atPath: first.path) {
            state.permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            state.modified = (attributes[.modificationDate] as? Date) ?? Date()
            state.created = (attributes[.creationDate] as? Date) ?? Date()
            let values = try? first.resourceValues(forKeys: [.isHiddenKey, .tagNamesKey])
            state.hidden = values?.isHidden ?? false
            state.tags = (values?.tagNames ?? []).joined(separator: ", ")
            state.comment = FinderMetadata.comment(of: first) ?? ""
        }
        state.anyFolder = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        return state
    }
}

struct AttributesView: View {
    let title: String
    let initial: AttributeFormState
    var onApply: (AttributeChange) -> Void
    var close: () -> Void

    @State private var changePermissions = false
    @State private var bits: [Bool] = []
    @State private var recursive = false
    @State private var changeModified = false
    @State private var modified = Date()
    @State private var changeCreated = false
    @State private var created = Date()
    @State private var hiddenChoice = 0            // 0 unchanged, 1 hidden, 2 visible
    @State private var changeTags = false
    @State private var tags = ""
    @State private var changeComment = false
    @State private var comment = ""

    private var mode: Int {
        zip(bits, (0..<9).reversed()).reduce(0) { $0 | ($1.0 ? 1 << $1.1 : 0) }
    }

    private var change: AttributeChange {
        var c = AttributeChange()
        if changePermissions { c.permissions = mode; c.recursive = recursive }
        if changeModified { c.modified = modified }
        if changeCreated { c.created = created }
        if hiddenChoice == 1 { c.hidden = true }
        if hiddenChoice == 2 { c.hidden = false }
        if changeTags { c.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if changeComment { c.comment = comment }
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text("Only the groups you switch on are changed.").font(.callout).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Permissions", isOn: $changePermissions)
                    if bits.count == 9 {
                        Grid(horizontalSpacing: 18, verticalSpacing: 4) {
                            GridRow {
                                Text(""); Text("Read"); Text("Write"); Text("Execute")
                            }.font(.caption).foregroundStyle(.secondary)
                            ForEach(0..<3) { row in
                                GridRow {
                                    Text(tr(["Owner", "Group", "Others"][row]))
                                    ForEach(0..<3) { column in
                                        Toggle("", isOn: $bits[row * 3 + column]).labelsHidden()
                                    }
                                }
                            }
                        }
                        .disabled(!changePermissions)
                        HStack {
                            Text(tr("Mode %@", String(mode, radix: 8))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            if initial.anyFolder {
                                Toggle("Apply to everything inside folders", isOn: $recursive).disabled(!changePermissions)
                            }
                        }
                    }
                }
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Toggle("Modified", isOn: $changeModified)
                        DatePicker("", selection: $modified).labelsHidden().disabled(!changeModified)
                    }
                    GridRow {
                        Toggle("Created", isOn: $changeCreated)
                        DatePicker("", selection: $created).labelsHidden().disabled(!changeCreated)
                    }
                    GridRow {
                        Text("Hidden")
                        Picker("", selection: $hiddenChoice) {
                            Text("Unchanged").tag(0); Text("Hidden").tag(1); Text("Visible").tag(2)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    }
                    GridRow {
                        Toggle("Tags", isOn: $changeTags)
                        TextField("comma separated", text: $tags).textFieldStyle(.roundedBorder).disabled(!changeTags)
                    }
                    GridRow {
                        Toggle("Comment", isOn: $changeComment)
                        TextField("empty removes it", text: $comment).textFieldStyle(.roundedBorder).disabled(!changeComment)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(change); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            bits = (0..<9).map { initial.permissions & (1 << (8 - $0)) != 0 }
            modified = initial.modified
            created = initial.created
            tags = initial.tags
            comment = initial.comment
        }
    }
}

// MARK: - Connect to Server

struct ConnectToServerView: View {
    var initial: ServerProfile?
    var initialSecret: String
    /// `report(nil)` means the connection works (the sheet closes); a message keeps the sheet open.
    var onConnect: (_ profile: ServerProfile, _ secret: String, _ remember: Bool, _ savePassword: Bool,
                    _ report: @escaping (String?) -> Void) -> Void
    var close: () -> Void

    @State private var scheme = RemoteScheme.sftp
    @State private var host = ""
    @State private var portText = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var keyPath = ""
    @State private var acceptInvalid = false
    @State private var name = ""
    @State private var remember = true
    @State private var savePassword = true
    @State private var busy = false
    @State private var error: String?
    @State private var profileID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Server").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Protocol")
                    Picker("", selection: $scheme) {
                        ForEach(RemoteScheme.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 220)
                    Spacer()
                }
                GridRow {
                    Text("Server")
                    TextField("host name or address", text: $host).textFieldStyle(.roundedBorder)
                    HStack(spacing: 4) {
                        Text("port").foregroundStyle(.secondary)
                        TextField("", text: $portText).textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                }
                GridRow {
                    Text("User")
                    TextField(scheme == .sftp ? tr("login name") : tr("empty = anonymous"), text: $user).textFieldStyle(.roundedBorder).gridCellColumns(2)
                }
                GridRow {
                    Text(scheme == .sftp && !keyPath.isEmpty ? tr("Key passphrase") : tr("Password"))
                    SecureField(scheme == .sftp ? tr("empty = use ssh-agent or an unprotected key") : "", text: $password)
                        .textFieldStyle(.roundedBorder).gridCellColumns(2)
                }
                if scheme == .sftp {
                    GridRow {
                        Text("Key file")
                        TextField("optional, e.g. ~/.ssh/id_ed25519", text: $keyPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseKey() }
                    }
                }
                GridRow {
                    Text("Name")
                    TextField("optional", text: $name).textFieldStyle(.roundedBorder).gridCellColumns(2)
                }
            }

            if scheme == .ftp {
                Label("FTP sends the password and the files unencrypted. Prefer SFTP or FTPS.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if scheme == .ftpes || scheme == .ftps {
                Toggle("Accept an untrusted certificate (unsafe)", isOn: $acceptInvalid)
                if acceptInvalid {
                    Label("Anyone between you and the server could read and change what you transfer.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
            }

            Toggle("Remember this server in the Go menu", isOn: $remember)
            Toggle("Save the password in the Keychain", isOn: $savePassword).disabled(!remember)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }.keyboardShortcut(.defaultAction).disabled(busy || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { prefill() }
        .onChange(of: scheme) { newScheme in
            // keep a custom port, follow the protocol when the port is still a default one
            if portText.isEmpty || RemoteScheme.allCases.map({ String($0.defaultPort) }).contains(portText) { portText = String(newScheme.defaultPort) }
        }
    }

    private func prefill() {
        guard let p = initial else { return }
        profileID = p.id
        scheme = p.scheme; host = p.host; portText = String(p.port); user = p.user
        keyPath = p.keyPath ?? ""; acceptInvalid = p.acceptInvalidCertificate; name = p.name
        password = initialSecret
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.message = tr("Choose your private key file")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    private func connect() {
        var profile = ServerProfile()
        profile.id = profileID
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.scheme = scheme
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = Int(portText) ?? scheme.defaultPort
        profile.user = user.trimmingCharacters(in: .whitespaces)
        profile.keyPath = scheme == .sftp && !keyPath.isEmpty ? keyPath : nil
        profile.acceptInvalidCertificate = (scheme == .ftpes || scheme == .ftps) && acceptInvalid
        busy = true
        error = nil
        onConnect(profile, password, remember, savePassword) { message in
            busy = false
            if let message { error = message } else { close() }
        }
    }
}
