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
                            Image(systemName: button.symbol ?? "square").frame(width: 18).foregroundStyle(button.tint)
                            Text(tr(button.title.isEmpty ? button.action.title : button.title))
                        }
                        Spacer(minLength: 0)
                        if button.hasExtraClicks { Image(systemName: "cursorarrow.click.2").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(index)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { insert(ListerButton(title: tr("New Button"), symbol: "star.fill", action: .refresh)) } label: { Image(systemName: "plus") }
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

    private func form(for index: Int) -> some View {
        // SwiftUI may still call these once after the row is gone (Remove, Reset): never index blindly.
        let button = Binding(get: { buttons.indices.contains(index) ? buttons[index] : ListerButton(title: "", symbol: nil, action: .separator) },
                             set: { if buttons.indices.contains(index) { buttons[index] = $0 } })
        return Form {
            Section("Look") {
                TextField("Title", text: button.title)
                HStack {
                    TextField("Icon (SF Symbol)", text: Binding(get: { button.wrappedValue.symbol ?? "" }, set: { button.wrappedValue.symbol = $0.isEmpty ? nil : $0 }))
                    if let symbol = button.wrappedValue.symbol, !symbol.isEmpty { Image(systemName: symbol).foregroundStyle(button.wrappedValue.tint) }
                }
                Picker("Color", selection: Binding(get: { button.wrappedValue.color ?? "" }, set: { button.wrappedValue.color = $0.isEmpty ? nil : $0 })) {
                    ForEach(Self.colors, id: \.self) { name in
                        if name.isEmpty { Text("Neutral").tag(name) } else { Label(name.capitalized, systemImage: "circle.fill").foregroundStyle(LabelPalette.color(name) ?? .primary).tag(name) }
                    }
                }
                TextField("Tooltip", text: Binding(get: { button.wrappedValue.help ?? "" }, set: { button.wrappedValue.help = $0.isEmpty ? nil : $0 }))
            }
            Section("Mouse buttons") {
                actionRow("Left click", action: Binding(get: { button.wrappedValue.action }, set: { button.wrappedValue.action = $0 }),
                          command: button.command, optional: false)
                actionRow("Right click", action: button.rightAction, command: button.rightCommand, optional: true)
                actionRow("Middle click", action: button.middleAction, command: button.middleCommand, optional: true)
            }
        }
        .formStyle(.grouped)
    }

    private func actionRow(_ title: LocalizedStringKey, action: Binding<ListerAction>, command: Binding<String?>, optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: action) {
                ForEach(ListerAction.allCases.filter { $0 != .separator }) { Text($0.title).tag($0) }
            }
            if action.wrappedValue == .shell { commandField(command) }
        }
    }

    private func actionRow(_ title: LocalizedStringKey, action: Binding<ListerAction?>, command: Binding<String?>, optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: action) {
                Text("Nothing").tag(ListerAction?.none)
                ForEach(ListerAction.allCases.filter { $0 != .separator }) { Text($0.title).tag(ListerAction?.some($0)) }
            }
            if action.wrappedValue == .shell { commandField(command) }
        }
    }

    private func commandField(_ command: Binding<String?>) -> some View {
        TextField("Shell command (LISTER_DIR, LISTER_SELECTION)", text: Binding(get: { command.wrappedValue ?? "" }, set: { command.wrappedValue = $0.isEmpty ? nil : $0 }))
            .font(.system(.body, design: .monospaced))
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
