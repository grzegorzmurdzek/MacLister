import SwiftUI
import AppKit

/// Small helpers of the filetype editor (kept apart from the views so that the self-test can reach them).
enum FiletypeEditing {
    /// "md, txt  .PNG *.jpg" → ["md", "txt", "png", "jpg"]; "*" stays.
    static func parseExtensions(_ text: String) -> [String] {
        text.split(whereSeparator: { ",; \n".contains($0) })
            .map { piece -> String in
                var name = piece.trimmingCharacters(in: .whitespaces).lowercased()
                if name.hasPrefix("*.") { name.removeFirst(2) }
                while name.hasPrefix(".") { name.removeFirst() }
                return name
            }
            .filter { !$0.isEmpty }
    }

    /// What the list shows for a rule.
    static func title(of rule: FiletypeRule) -> String {
        if let name = rule.name, !name.isEmpty { return name }
        let list = rule.extensions.prefix(4).joined(separator: ", ")
        if list.isEmpty { return tr("New Filetype") }
        return rule.extensions.count > 4 ? list + "…" : list
    }

    /// The codes of a shell command with a short explanation (see FiletypeCommand).
    static let codes: [(code: String, help: String)] = [
        ("{f}", tr("the full path of the file (one command for each file)")),
        ("{F}", tr("the full paths of all selected files")),
        ("{o}", tr("the name of the file (one command for each file)")),
        ("{O}", tr("the names of all selected files")),
        ("{f-}", tr("the full path without the extension")),
        ("{d}", tr("the folder of the destination lister")),
        ("{s}", tr("the folder of this lister")),
        ("{df}", tr("the full path of a file selected in the destination lister")),
        ("{dF}", tr("the full paths of the files selected in the destination lister")),
    ]

    /// An application as it is stored: the bundle identifier when it has one, else the path.
    static func applicationSpec(for url: URL) -> String {
        Bundle(url: url)?.bundleIdentifier ?? url.path
    }
}

/// The Filetypes tab of the Settings window: edits filetypes.json (what a double-click does, what ⌥ + double-click
/// does, and the context-menu entries of every type). Every change is saved at once, as in the other tabs.
struct FiletypeEditorView: View {
    @State private var rules: [FiletypeRule]
    @State private var selection: Int?
    @State private var confirmReset = false

    init(initial: [FiletypeRule]? = nil, selection: Int? = 0) {
        _rules = State(initialValue: initial ?? FiletypeStore.shared.currentRules())
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list.frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
                detail.frame(minWidth: 380)
            }
            Divider()
            HStack {
                Button("Reset to Defaults…") { confirmReset = true }
                Button("Open filetypes.json") { FiletypeStore.openInEditor() }
                Spacer()
                Text("Changes are saved at once.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(width: 700, height: 500)
        .onChange(of: rules) { FiletypeStore.shared.save($0) }
        .onAppear {
            // the file may have been edited by hand since this tab was made
            let current = FiletypeStore.shared.currentRules()
            if current != rules { rules = current; selection = rules.isEmpty ? nil : min(selection ?? 0, rules.count - 1) }
        }
        .confirmationDialog("Reset the filetypes to the defaults?", isPresented: $confirmReset) {
            Button("Reset Filetypes", role: .destructive) {
                rules = FiletypeStore.defaults
                selection = rules.isEmpty ? nil : 0
            }
        } message: {
            Text("Your own filetypes are replaced by the standard ones.")
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    HStack(spacing: 8) {
                        Image(systemName: rule.menu?.isEmpty == false ? "contextualmenu.and.cursorarrow" : "doc")
                            .frame(width: 18).foregroundStyle(.secondary)
                        Text(FiletypeEditing.title(of: rule)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .tag(index)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { insert() } label: { Image(systemName: "plus") }.help("Add a filetype")
                Button { remove() } label: { Image(systemName: "trash") }.disabled(selection == nil).help("Remove")
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(!canMove(-1)).help("Move up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(!canMove(1)).help("Move down")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func insert() {
        let index = (selection ?? (rules.count - 1)) + 1
        rules.insert(FiletypeRule(extensions: []), at: min(index, rules.count))
        selection = min(index, rules.count - 1)
    }

    private func remove() {
        guard let index = selection, rules.indices.contains(index) else { return }
        rules.remove(at: index)
        selection = rules.isEmpty ? nil : min(index, rules.count - 1)
    }

    private func canMove(_ delta: Int) -> Bool {
        guard let index = selection else { return false }
        return rules.indices.contains(index + delta)
    }

    private func move(_ delta: Int) {
        guard let index = selection, canMove(delta) else { return }
        rules.swapAt(index, index + delta)
        selection = index + delta
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let index = selection, rules.indices.contains(index) {
            form(for: index).id(index)
        } else {
            Text("Choose a filetype").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(for index: Int) -> some View {
        // SwiftUI may still call these once after the row is gone (Remove, Reset): never index blindly.
        let rule = Binding(get: { rules.indices.contains(index) ? rules[index] : FiletypeRule(extensions: []) },
                           set: { if rules.indices.contains(index) { rules[index] = $0 } })
        let doubleClick = Binding<FiletypeStep?>(
            get: { rule.wrappedValue.action == nil ? nil : rule.wrappedValue.doubleClick },
            set: { step in
                var edited = rule.wrappedValue
                edited.action = step?.action
                edited.app = step?.app
                edited.command = step?.command
                edited.lister = step?.lister
                rule.wrappedValue = edited
            })
        let optionDoubleClick = Binding<FiletypeStep?>(get: { rule.wrappedValue.optionDoubleClick },
                                                       set: { rule.wrappedValue.optionDoubleClick = $0 })
        return Form {
            Section("Which files") {
                TextField("Name", text: Binding(get: { rule.wrappedValue.name ?? "" }, set: { rule.wrappedValue.name = $0.isEmpty ? nil : $0 }))
                ExtensionsField(extensions: Binding(get: { rule.wrappedValue.extensions }, set: { rule.wrappedValue.extensions = $0 }))
                Text("Extensions without the dot, separated by commas or spaces: md, txt, tar.gz. A * stands for every file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Opening") {
                FiletypeStepEditor(title: "Double-click", step: doubleClick, noneLabel: "None (another filetype or the system decides)")
                FiletypeStepEditor(title: "⌥ + double-click", step: optionDoubleClick, noneLabel: "Same as double-click")
                Text("The first filetype in the list that fits the file and has a double-click decides.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Context menu") {
                MenuStepsEditor(steps: Binding(get: { rule.wrappedValue.menu ?? [] },
                                               set: { rule.wrappedValue.menu = $0.isEmpty ? nil : $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

/// The extensions of a rule as one line of text. The text is kept here while it is typed, so that a comma or a space
/// at the end does not vanish before the next word.
private struct ExtensionsField: View {
    @Binding var extensions: [String]
    @State private var text: String

    init(extensions: Binding<[String]>) {
        _extensions = extensions
        _text = State(initialValue: extensions.wrappedValue.joined(separator: ", "))
    }

    var body: some View {
        TextField("Extensions", text: $text, prompt: Text("md, txt, tar.gz"))
            .onChange(of: text) { extensions = FiletypeEditing.parseExtensions($0) }
    }
}

/// One thing a filetype does: pick the action, then what it needs (an application, a command, a lister action).
struct FiletypeStepEditor: View {
    var title: LocalizedStringKey
    @Binding var step: FiletypeStep?
    /// The text for "no step"; nil when a step is required.
    var noneLabel: LocalizedStringKey?
    var allowSeparator = false

    private static let kinds: [FiletypeStep.Action] = [.open, .extract, .quicklook, .app, .shell, .lister]

    private static func label(_ action: FiletypeStep.Action) -> LocalizedStringKey {
        switch action {
        case .open: return "Open (system default)"
        case .extract: return "Extract"
        case .quicklook: return "Quick Look"
        case .app: return "Open with application"
        case .shell: return "Run shell command"
        case .lister: return "Lister action"
        case .separator: return "Separator"
        }
    }

    /// Choosing another action keeps the title but drops what only the old one needed.
    private var action: Binding<FiletypeStep.Action?> {
        Binding(get: { step?.action },
                set: { new in
                    guard let new else { step = nil; return }
                    var edited = step ?? FiletypeStep(action: new)
                    edited.action = new
                    if new != .app { edited.app = nil }
                    if new != .shell { edited.command = nil }
                    if new != .lister { edited.lister = nil }
                    step = edited
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: action) {
                if let noneLabel { Text(noneLabel).tag(Optional<FiletypeStep.Action>.none) }
                ForEach(Self.kinds, id: \.self) { Text(Self.label($0)).tag(Optional($0)) }
                if allowSeparator { Text(Self.label(.separator)).tag(Optional(FiletypeStep.Action.separator)) }
            }
            if let current = step {
                switch current.action {
                case .app: applicationRow
                case .shell: commandRow
                case .lister: listerRow
                default: EmptyView()
                }
            }
        }
    }

    private var applicationRow: some View {
        HStack {
            TextField("Application (bundle identifier or path)", text: Binding(get: { step?.app ?? "" },
                                                                               set: { step?.app = $0.isEmpty ? nil : $0 }))
            Button("Choose…") { chooseApplication() }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose an Application")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        step?.app = FiletypeEditing.applicationSpec(for: url)
    }

    private var commandRow: some View {
        HStack {
            TextField("Shell command", text: Binding(get: { step?.command ?? "" }, set: { step?.command = $0.isEmpty ? nil : $0 }))
                .font(.system(.body, design: .monospaced))
            Menu {
                ForEach(FiletypeEditing.codes, id: \.code) { entry in
                    Button("\(entry.code)  \(entry.help)") {
                        let old = step?.command ?? ""
                        step?.command = old + (old.isEmpty || old.hasSuffix(" ") ? "" : " ") + entry.code
                    }
                }
            } label: {
                Text(verbatim: "{ }")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Insert a code for the selected files")
        }
    }

    private var listerRow: some View {
        LabeledContent("Action") {
            ActionPicker(selection: Binding(get: { step?.lister.flatMap(ListerAction.init(rawValue:)) },
                                            set: { step?.lister = $0?.rawValue }),
                         allowNone: false)
        }
    }
}

/// The entries of the context menu of a filetype: order, title and what each one does.
struct MenuStepsEditor: View {
    @Binding var steps: [FiletypeStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if step.action == .separator {
                            Image(systemName: "minus").frame(width: 18).foregroundStyle(.secondary)
                            Text("Separator").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        } else {
                            TextField("Title", text: Binding(get: { steps.indices.contains(index) ? steps[index].title ?? "" : "" },
                                                             set: { if steps.indices.contains(index) { steps[index].title = $0.isEmpty ? nil : $0 } }),
                                      prompt: Text(ListerViewController.title(of: step)))
                        }
                        Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move up")
                        Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == steps.count - 1).help("Move down")
                        Button { if steps.indices.contains(index) { steps.remove(at: index) } } label: { Image(systemName: "trash") }.help("Remove")
                    }
                    if step.action != .separator {
                        FiletypeStepEditor(title: "Action", step: Binding(get: { steps.indices.contains(index) ? steps[index] : nil },
                                                                        set: { if steps.indices.contains(index), let value = $0 { steps[index] = value } }),
                                           noneLabel: nil)
                    }
                }
                if index < steps.count - 1 { Divider() }
            }
            HStack {
                Button("Add Entry") { steps.append(FiletypeStep(action: .shell, title: nil)) }
                Button("Add Separator") { steps.append(FiletypeStep(action: .separator)) }
            }
            Text("These entries are added to the context menu of files of this type, after Open With. The entries of every filetype that fits the file are shown. With several files selected, only those of filetypes that fit all of them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard steps.indices.contains(index), steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }
}
