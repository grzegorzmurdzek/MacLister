import SwiftUI
import AppKit

/// Edits the button bar: order, look, and what the left, right and middle mouse buttons do.
struct ButtonEditorView: View {
    @State private var buttons: [ListerButton]
    @State private var selection: Int?
    let close: () -> Void

    init(initial: [ListerButton]? = nil, selection: Int? = 0, close: @escaping () -> Void) {
        _buttons = State(initialValue: initial ?? ButtonStore.shared.buttons)
        _selection = State(initialValue: selection)
        self.close = close
    }

    private static let colors = [""] + LabelPalette.names

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                detail.frame(minWidth: 340)
            }
            Divider()
            HStack {
                Button("Reset to Defaults…") {
                    buttons = ListerButton.defaults
                    selection = 0
                }
                Button("Open buttons.json") { ButtonEditorWindow.openJSON() }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                Button("Save") {
                    ButtonStore.shared.save(buttons)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 620, minHeight: 440)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                    HStack(spacing: 8) {
                        if button.action == .separator {
                            Image(systemName: "minus").frame(width: 18).foregroundStyle(.secondary)
                            Text("Separator").foregroundStyle(.secondary)
                        } else {
                            if let picture = ButtonIcons.image(named: button.iconFile) {
                                Image(nsImage: picture).resizable().scaledToFit().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: button.symbol ?? "square").frame(width: 18).foregroundStyle(button.tint)
                            }
                            Text(tr(button.title.isEmpty ? button.action.title : button.title))
                        }
                        Spacer(minLength: 0)
                        if button.hasMenu { Image(systemName: "chevron.down.circle").font(.caption).foregroundStyle(.secondary) }
                        if button.hasExtraClicks { Image(systemName: "cursorarrow.click.2").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(index)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { insert(ListerButton(title: ListerAction.refresh.title, symbol: ListerAction.refresh.suggestedSymbol, action: .refresh)) } label: { Image(systemName: "plus") }
                    .help("Add a button")
                Button { insert(ListerButton(title: "", symbol: nil, action: .separator)) } label: { Image(systemName: "minus.rectangle") }
                    .help("Add a separator")
                Button { remove() } label: { Image(systemName: "trash") }.disabled(selection == nil).help("Remove")
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(!canMove(-1)).help("Move up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(!canMove(1)).help("Move down")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func insert(_ button: ListerButton) {
        let index = (selection ?? (buttons.count - 1)) + 1
        buttons.insert(button, at: min(index, buttons.count))
        selection = min(index, buttons.count - 1)
    }

    private func remove() {
        guard let index = selection, buttons.indices.contains(index) else { return }
        buttons.remove(at: index)
        selection = buttons.isEmpty ? nil : min(index, buttons.count - 1)
    }

    private func canMove(_ delta: Int) -> Bool {
        guard let index = selection else { return false }
        return buttons.indices.contains(index + delta)
    }

    private func move(_ delta: Int) {
        guard let index = selection, canMove(delta) else { return }
        buttons.swapAt(index, index + delta)
        selection = index + delta
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let index = selection, buttons.indices.contains(index) {
            if buttons[index].action == .separator {
                Text("A thin divider between groups of buttons.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form(for: index)
            }
        } else {
            Text("Choose a button").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @State private var choosingIcon = false
    @State private var imageProblem: String?

    /// Asks for a picture and makes it the icon of the button.
    private func chooseImage(for button: Binding<ListerButton>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = tr("Choose a picture for the button")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let name = ButtonIcons.importImage(from: url) else {
            imageProblem = tr("This file is not a picture macOS can read")
            return
        }
        imageProblem = nil
        replaceImage(of: button, with: name)
    }

    /// Sets (or clears) the picture; the old file goes away unless another button still uses it.
    private func replaceImage(of button: Binding<ListerButton>, with name: String?) {
        let old = button.wrappedValue.iconFile
        button.wrappedValue.iconFile = name
        if let old, old != name, !buttons.contains(where: { $0.iconFile == old }) { ButtonIcons.remove(old) }
    }

    private func form(for index: Int) -> some View {
        // SwiftUI may still call these once after the row is gone (Remove, Reset): never index blindly.
        let button = Binding(get: { buttons.indices.contains(index) ? buttons[index] : ListerButton(title: "", symbol: nil, action: .separator) },
                             set: { if buttons.indices.contains(index) { buttons[index] = $0 } })
        // Choosing another action also updates the title and the icon, as long as they are still the old action's.
        let leftAction = Binding<ListerAction>(get: { button.wrappedValue.action }, set: { new in
            var edited = button.wrappedValue
            let old = edited.action
            let titles = [old.title, tr(old.title), tr("New Button"), "New Button", ""]
            if titles.contains(where: { edited.title.caseInsensitiveCompare($0) == .orderedSame }) { edited.title = tr(new.title) }
            if edited.symbol == nil || edited.symbol == old.suggestedSymbol || edited.symbol == "star.fill" { edited.symbol = new.suggestedSymbol }
            if edited.help == nil || edited.help?.isEmpty == true || edited.help == old.defaultHelp { edited.help = new.defaultHelp }
            edited.action = new
            button.wrappedValue = edited
        })
        return Form {
            Section("What the button does") {
                actionRow("Left click", action: leftAction, command: button.command, optional: false)
                actionRow("Right click", action: button.rightAction, command: button.rightCommand, optional: true)
                actionRow("Middle click", action: button.middleAction, command: button.middleCommand, optional: true)
            }
            Section("Menu") {
                MenuEntriesEditor(entries: Binding(get: { button.wrappedValue.menu ?? [] },
                                                   set: { button.wrappedValue.menu = $0.isEmpty ? nil : $0 }))
            }
            Section("Look") {
                TextField("Title", text: button.title)
                HStack {
                    TextField("Icon", text: Binding(get: { button.wrappedValue.symbol ?? "" }, set: { button.wrappedValue.symbol = $0.isEmpty ? nil : $0 }))
                    if let symbol = button.wrappedValue.symbol, !symbol.isEmpty { Image(systemName: symbol).foregroundStyle(button.wrappedValue.tint) }
                    Button("Choose…") { choosingIcon = true }
                        .popover(isPresented: $choosingIcon) {
                            SymbolGrid { name in
                                button.wrappedValue.symbol = name
                                choosingIcon = false
                            }
                        }
                }
                Text("The icon is an SF Symbol, one of the icons that come with macOS. Choose one from the list, or type the name of any symbol (the free SF Symbols app from Apple shows them all).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Your own picture")
                    if let picture = ButtonIcons.image(named: button.wrappedValue.iconFile) {
                        Image(nsImage: picture).resizable().scaledToFit().frame(width: 22, height: 22)
                    }
                    Spacer()
                    Button(button.wrappedValue.iconFile == nil ? "Choose Image…" : "Change Image…") { chooseImage(for: button) }
                    if button.wrappedValue.iconFile != nil {
                        Button("Remove") { replaceImage(of: button, with: nil) }
                    }
                }
                if let problem = imageProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                Text("A picture (PNG, JPEG, PDF, icns …) replaces the symbol and is shown as it is, without the colour.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Color", selection: Binding(get: { button.wrappedValue.color ?? "" }, set: { button.wrappedValue.color = $0.isEmpty ? nil : $0 })) {
                    ForEach(Self.colors, id: \.self) { name in
                        if name.isEmpty { Text("Neutral").tag(name) } else { Label(name.capitalized, systemImage: "circle.fill").foregroundStyle(LabelPalette.color(name) ?? .primary).tag(name) }
                    }
                }
                TextField("Tooltip", text: Binding(get: { button.wrappedValue.help ?? "" }, set: { button.wrappedValue.help = $0.isEmpty ? nil : $0 }))
            }
        }
        .formStyle(.grouped)
    }

    private func actionRow(_ title: LocalizedStringKey, action: Binding<ListerAction>, command: Binding<String?>, optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                ActionPicker(selection: Binding(get: { action.wrappedValue }, set: { if let value = $0 { action.wrappedValue = value } }), allowNone: false)
            }
            if action.wrappedValue == .shell { commandField(command) }
        }
    }

    private func actionRow(_ title: LocalizedStringKey, action: Binding<ListerAction?>, command: Binding<String?>, optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) { ActionPicker(selection: action, allowNone: true) }
            if action.wrappedValue == .shell { commandField(command) }
        }
    }

    private func commandField(_ command: Binding<String?>) -> some View {
        TextField("Shell command (LISTER_DIR, LISTER_SELECTION)", text: Binding(get: { command.wrappedValue ?? "" }, set: { command.wrappedValue = $0.isEmpty ? nil : $0 }))
            .font(.system(.body, design: .monospaced))
    }
}

/// The entries of a button's menu: which actions it offers, in which order.
struct MenuEntriesEditor: View {
    @Binding var entries: [ListerButton]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if entry.action == .separator {
                            Image(systemName: "minus").frame(width: 18).foregroundStyle(.secondary)
                            Text("Separator").foregroundStyle(.secondary)
                        } else {
                            ActionPicker(selection: Binding(get: { entries.indices.contains(index) ? entries[index].action : .refresh },
                                                            set: { if let action = $0 { choose(action, at: index) } }),
                                         allowNone: false)
                        }
                        Spacer(minLength: 0)
                        Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move up")
                        Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == entries.count - 1).help("Move down")
                        Button { if entries.indices.contains(index) { entries.remove(at: index) } } label: { Image(systemName: "trash") }.help("Remove")
                    }
                    if entry.action == .shell {
                        TextField("Title", text: Binding(get: { entries.indices.contains(index) ? entries[index].title : "" },
                                                         set: { if entries.indices.contains(index) { entries[index].title = $0 } }))
                        TextField("Shell command (LISTER_DIR, LISTER_SELECTION)",
                                  text: Binding(get: { entries.indices.contains(index) ? entries[index].command ?? "" : "" },
                                                set: { if entries.indices.contains(index) { entries[index].command = $0.isEmpty ? nil : $0 } }))
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            HStack {
                Button("Add Action") { entries.append(ListerButton(title: "", symbol: nil, action: .refresh)) }
                Button("Add Separator") { entries.append(ListerButton(title: "", symbol: nil, action: .separator)) }
            }
            Text("Hold the button down for a moment and these actions open as a menu. A plain click still does the button's own action. With \"Show an arrow on buttons that have a menu\" (Settings → Buttons) a click on the arrow opens the menu at once.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    private func choose(_ action: ListerAction, at index: Int) {
        guard entries.indices.contains(index) else { return }
        let old = entries[index]
        // Only a shell entry has a title and a command of its own.
        entries[index] = ListerButton(title: action == .shell ? old.title : "", symbol: nil, action: action,
                                      command: action == .shell ? old.command : nil)
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard entries.indices.contains(index), entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }
}

enum ButtonEditorWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { NSApp.bringToFront(); window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: ButtonEditorView(close: { window?.close() }))
        let created = NSWindow(contentViewController: host)
        created.styleMask = [.titled, .closable, .resizable]
        created.title = tr("Edit Buttons")
        created.isReleasedWhenClosed = false
        created.setContentSize(NSSize(width: 700, height: 480))
        created.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in window = nil }
        window = created
        NSApp.bringToFront()
        created.makeKeyAndOrderFront(nil)
    }

    /// The raw file, for people who prefer a text editor.
    static func openJSON() {
        ButtonStore.shared.ensureConfigFileExists()
        let file = ButtonStore.configURL
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

/// A grid of common SF Symbols to pick an icon from.
struct SymbolGrid: View {
    var onPick: (String) -> Void

    static let names = [
        "folder.fill", "folder.fill.badge.plus", "doc.fill", "doc.on.doc.fill", "trash.fill", "archivebox.fill", "tray.full.fill", "externaldrive.fill",
        "arrow.up.circle.fill", "arrow.down.circle.fill", "arrow.left.circle.fill", "arrow.right.circle.fill", "arrow.clockwise.circle.fill", "arrow.triangle.2.circlepath.circle.fill",
        "arrowshape.turn.up.right.fill", "arrow.left.arrow.right.circle.fill", "square.and.arrow.up.fill", "square.and.arrow.down.fill", "link.circle.fill", "network",
        "magnifyingglass", "line.3.horizontal.decrease.circle.fill", "checkmark.circle.fill", "xmark.circle.fill", "plus.circle.fill", "minus.circle.fill",
        "star.fill", "heart.fill", "bookmark.fill", "tag.fill", "flag.fill", "pin.fill",
        "terminal.fill", "gearshape.fill", "wrench.and.screwdriver.fill", "hammer.fill", "bolt.fill", "wand.and.stars",
        "info.circle.fill", "questionmark.circle.fill", "exclamationmark.triangle.fill", "lock.fill", "key.fill", "eye.circle.fill",
        "photo.fill", "music.note", "film.fill", "text.alignleft", "pencil.circle.fill", "paintbrush.fill",
        "clock.fill", "calendar", "house.fill", "globe", "icloud.fill", "cpu.fill",
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.names, id: \.self) { name in
                    Button { onPick(name) } label: { Image(systemName: name).font(.system(size: 16)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain)
                        .help(name)
                }
            }
            .padding(10)
        }
        .frame(width: 8 * 38 + 24, height: 260)
    }
}

/// Chooses an action: the current one on a button; a popover with a search field and the actions grouped and sorted
/// by name (there are too many for a plain pop-up menu).
struct ActionPicker: View {
    @Binding var selection: ListerAction?
    var allowNone: Bool

    @State private var open = false
    @State private var query = ""
    @FocusState private var searching: Bool

    /// Actions shown for `query`, by group, sorted by (translated) name inside each group.
    static func groups(matching query: String) -> [(category: ActionCategory, actions: [ListerAction])] {
        let words = query.split(separator: " ").map(String.init)
        func matches(_ action: ListerAction) -> Bool {
            let haystack = [action.title, action.rawValue, action.category.title].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return ActionCategory.allCases.compactMap { category in
            let actions = ListerAction.allCases
                .filter { $0 != .separator && $0.category == category && matches($0) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    var body: some View {
        Button { query = ""; open = true } label: {
            HStack(spacing: 6) {
                if let current = selection { Image(systemName: current.suggestedSymbol).frame(width: 16) }
                Text(selection?.title ?? tr("Nothing"))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 200, alignment: .leading)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) { chooser }
    }

    private func pick(_ action: ListerAction?) {
        selection = action
        open = false
    }

    private var chooser: some View {
        let groups = Self.groups(matching: query)
        return VStack(spacing: 0) {
            TextField("Search actions", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .padding(8)
                .onSubmit { if let first = groups.first?.actions.first { pick(first) } }
            Divider()
            List {
                if allowNone, query.isEmpty {
                    row(nil)
                }
                ForEach(groups, id: \.category) { group in
                    Section(group.category.title) {
                        ForEach(group.actions) { row($0) }
                    }
                }
                if groups.isEmpty { Text("No action matches").foregroundStyle(.secondary) }
            }
            .listStyle(.plain)
        }
        .frame(width: 300, height: 380)
        .onAppear { searching = true }
    }

    private func row(_ action: ListerAction?) -> some View {
        Button { pick(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action?.suggestedSymbol ?? "nosign").frame(width: 18).foregroundStyle(.secondary)
                Text(action?.title ?? tr("Nothing"))
                Spacer()
                if selection == action { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
