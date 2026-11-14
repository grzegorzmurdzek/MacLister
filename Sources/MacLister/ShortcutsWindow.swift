import SwiftUI
import AppKit

/// Records a key combination for one row of the editor and applies the rules.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recordingID: String?
    @Published private(set) var messages: [String: String] = [:]

    var store: ShortcutStore = .shared
    /// Asked when a combination is already assigned to another action; tests replace it.
    var confirmReassign: (_ combo: KeyCombo, _ otherTitle: String, _ title: String) -> Bool = { combo, otherTitle, title in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(combo.display) is already assigned to “\(otherTitle)”"
        alert.informativeText = "Assign it to “\(title)” instead? “\(otherTitle)” will have no shortcut."
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var monitor: Any?

    static func title(for id: String) -> String {
        if let global = GlobalShortcutActions.all.first(where: { $0.id == id }) { return global.title }
        if id.hasPrefix("action."), let action = ListerAction(rawValue: String(id.dropFirst("action.".count))) { return action.title }
        return id
    }

    func begin(_ id: String) {
        stop()
        messages[id] = nil
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handle(event) }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
    }

    func clear(_ id: String) {
        stop()
        messages[id] = nil
        store.set(nil, for: id)
    }

    /// Esc cancels, Delete clears, anything else is tried as the new shortcut.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let id = recordingID else { return event }
        let plain = event.modifierFlags.intersection(KeyCombo.mask).isEmpty
        if event.keyCode == 53 && plain { stop(); return nil }
        if (event.keyCode == 51 || event.keyCode == 117) && plain { clear(id); return nil }
        apply(KeyCombo(event: event), for: id)
        return nil
    }

    func apply(_ combo: KeyCombo, for id: String) {
        guard let problem = ShortcutRules.validate(combo, for: id, store: store) else {
            store.set(combo, for: id)
            messages[id] = nil
            stop()
            return
        }
        if case .usedBy(let otherID) = problem {
            if confirmReassign(combo, Self.title(for: otherID), Self.title(for: id)) {
                store.set(nil, for: otherID)
                store.set(combo, for: id)
                messages[id] = nil
            } else {
                messages[id] = problem.message(for: combo, title: Self.title(for:))
            }
        } else {
            messages[id] = problem.message(for: combo, title: Self.title(for:))
        }
        stop()
    }
}

struct ShortcutsView: View {
    @ObservedObject private var store = ShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()

    private let actions: [ListerAction] = ListerAction.allCases.filter { $0 != .separator }.sorted { $0.title < $1.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard Shortcuts").font(.title3.bold())
                Text("Click a shortcut, then press the new keys. Esc cancels, Delete removes it. Keys that macOS, another application or MacLister already uses are refused.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            List {
                Section("Anywhere (works while another application is in front)") {
                    ForEach(GlobalShortcutActions.all, id: \.id) { row(id: $0.id, title: $0.title, builtIn: nil) }
                }
                Section("In listers") {
                    ForEach(actions) { action in
                        row(id: "action.\(action.rawValue)", title: action.title, builtIn: BuiltInShortcuts.byAction[action])
                    }
                }
            }

            HStack {
                Text("In listers a shortcut needs ⌘, ⌥ or ⌃ (function keys may stand alone).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove All") { store.bindings.keys.forEach { recorder.clear($0) } }.disabled(store.bindings.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onDisappear { recorder.stop() }
    }

    @ViewBuilder
    private func row(id: String, title: String, builtIn: String?) -> some View {
        let combo = store.combo(for: id)
        let recording = recorder.recordingID == id
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                if let builtIn { Text("also \(builtIn)").font(.caption).foregroundStyle(.tertiary) }
                Button { recording ? recorder.stop() : recorder.begin(id) } label: {
                    Text(recording ? "Press the keys…" : (combo?.display ?? "None"))
                        .frame(minWidth: 120)
                        .foregroundStyle(recording ? Color.white : (combo == nil ? Color.secondary : Color.primary))
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
                Button { recorder.clear(id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(combo == nil ? 0 : 1).disabled(combo == nil)
                    .help("Remove this shortcut")
            }
            if let message = recorder.messages[id] {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The standalone window (MacLister has no menu bar of its own, so this works with or without a lister).
final class ShortcutsWindowController {
    static let shared = ShortcutsWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: ShortcutsView())
            let created = NSWindow(contentViewController: host)
            created.title = "Keyboard Shortcuts"
            created.styleMask = [.titled, .closable, .resizable]
            created.setContentSize(NSSize(width: 620, height: 640))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.bringToFront()
        window?.makeKeyAndOrderFront(nil)
    }
}
