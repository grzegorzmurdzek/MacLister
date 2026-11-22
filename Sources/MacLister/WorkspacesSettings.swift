import SwiftUI
import AppKit

/// Settings → Workspaces: save the open listers under a name, open, update, rename, duplicate, reorder and delete them,
/// and choose what opens when the app starts.
struct WorkspacesSettingsView: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @AppStorage("startupWorkspaceID") private var startup = ""
    @AppStorage("restoreLayoutAtLaunch") private var restoreAtLaunch = true
    @AppStorage("autosaveLastSession") private var autosave = true
    @State private var selection: UUID?

    private var selected: Workspace? { store.workspace(id: selection) }
    private var hasOpenListers: Bool { ListerManager.shared.openCount > 0 }

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(store.workspaces) { workspace in
                        HStack {
                            Text(workspace.name)
                            if startup == workspace.id.uuidString && restoreAtLaunch {
                                Image(systemName: "power").foregroundStyle(.secondary).help(tr("Opens when MacLister starts"))
                            }
                            Spacer()
                            Text(summary(of: workspace)).foregroundStyle(.secondary)
                        }
                        .tag(workspace.id)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .frame(height: 150)
                .overlay {
                    if store.workspaces.isEmpty { Text("No workspaces yet").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Save Open Listers…") { saveNew() }.disabled(!hasOpenListers)
                    Button("Update") { if let selected { confirmUpdate(selected) } }.disabled(selected == nil || !hasOpenListers)
                    Spacer()
                    Button("Open") { if let selected { store.open(selected.id, replace: true) } }.disabled(selected == nil)
                }
                HStack {
                    Button("Rename…") { if let selected { rename(selected) } }.disabled(selected == nil)
                    Button("Duplicate") { if let selected { selection = store.duplicate(selected.id)?.id } }.disabled(selected == nil)
                    Button("Delete") { if let selected { confirmDelete(selected) } }.disabled(selected == nil)
                    Spacer()
                    Button("Add to Open Listers") { if let selected { store.open(selected.id, replace: false) } }.disabled(selected == nil)
                }
            } header: {
                Text("Workspaces")
            } footer: {
                Text("A workspace is a set of listers: their folders, windows, tabs, two-panel windows, positions, sizes, sorting and roles. Open one from the menu-bar icon, the Dock menu or the All Listers menu (hold ⌥ to add it to the open listers instead of replacing them). A workspace also keeps icons or list for each lister, the columns and the icon size. Servers are not saved. Drag to change the order.")
            }

            if let selected {
                Section("Folders in “\(selected.name)”") {
                    let missing = Set(selected.missingFolders)
                    ForEach(Array(selected.listers.enumerated()), id: \.offset) { _, lister in
                        HStack {
                            Text(PathText.short(lister.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if missing.contains(lister.path) {
                                Text("missing").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            Section {
                Picker("When MacLister starts", selection: $startup) {
                    Text("Open the last session").tag("")
                    ForEach(store.workspaces) { Text($0.name).tag($0.id.uuidString) }
                }
                .disabled(!restoreAtLaunch)
                Toggle("Save the open listers as the last session when MacLister quits", isOn: $autosave)
            } footer: {
                if restoreAtLaunch {
                    Text("The last session is also what Save Layout and Restore Layout keep. Turn off Restore layout at launch in General to start without listers.")
                } else {
                    Text("Restore layout at launch is off in General: MacLister starts without listers.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func summary(of workspace: Workspace) -> String {
        trCount("%d listers", workspace.listers.count)
    }

    private func saveNew() {
        guard let name = WorkspaceActions.askName(title: tr("Save Open Listers as Workspace"),
                                                  message: tr("The folders, windows, tabs and roles of the open listers are saved under this name."),
                                                  initial: store.suggestedName, button: tr("Save")) else { return }
        selection = store.addCurrent(name: name, from: ListerManager.shared).id
    }

    private func rename(_ workspace: Workspace) {
        guard let name = WorkspaceActions.askName(title: tr("Rename Workspace"), message: tr("Name of the workspace:"),
                                                  initial: workspace.name, button: tr("Rename")) else { return }
        if !store.rename(workspace.id, to: name) { NSSound.beep() }
    }

    private func confirmUpdate(_ workspace: Workspace) {
        let alert = NSAlert()
        alert.messageText = tr("Replace the workspace “%@” with the open listers?", workspace.name)
        alert.informativeText = tr("Its saved listers are replaced by the ones that are open now.")
        alert.addButton(withTitle: tr("Replace"))
        alert.addButton(withTitle: tr("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { store.update(workspace.id, from: ListerManager.shared) }
    }

    private func confirmDelete(_ workspace: Workspace) {
        let alert = NSAlert()
        alert.messageText = tr("Delete the workspace “%@”?", workspace.name)
        alert.informativeText = tr("The listers that are open are not affected.")
        alert.addButton(withTitle: tr("Delete"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            selection = nil
            store.remove(workspace.id)
        }
    }
}
