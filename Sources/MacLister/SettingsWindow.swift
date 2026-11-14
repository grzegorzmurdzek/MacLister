import SwiftUI
import AppKit

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("desktopTrigger") private var trigger = DesktopTrigger.doubleClick.rawValue
    @AppStorage("centerOnCursor") private var center = false
    @AppStorage("startDirectory") private var startDirectory = ""
    @AppStorage("restoreLayoutAtLaunch") private var restoreLayout = false
    @AppStorage("terminalBundleID") private var terminal = "com.apple.Terminal"
    @State private var language = AppLanguage.current

    private var terminalChoices: [(name: String, id: String)] {
        var choices = AppDelegate.terminalChoices()
        // a custom bundle id set with `defaults write` stays visible
        if !choices.contains(where: { $0.id == terminal }) { choices.append((terminal, terminal)) }
        return choices
    }

    private var startFolderText: String {
        startDirectory.isEmpty ? tr("Home") : PathText.short((startDirectory as NSString).expandingTildeInPath)
    }

    var body: some View {
        Form {
            Section("Opening listers") {
                Picker("Open a lister with", selection: $trigger) {
                    ForEach(DesktopTrigger.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                Toggle("Center the lister on the pointer", isOn: $center)
                LabeledContent("Start folder") {
                    HStack {
                        Text(startFolderText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { chooseStartFolder() }
                        Button("Home") { startDirectory = "" }.disabled(startDirectory.isEmpty)
                    }
                }
                Toggle("Reopen the saved layout when MacLister starts", isOn: $restoreLayout)
            }
            Section("Terminal Here") {
                Picker("Terminal app", selection: $terminal) {
                    ForEach(terminalChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                Picker("Interface language", selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                }
                .onChange(of: language) { AppDelegate.switchLanguage($0) }
            } header: {
                Text("Language")
            } footer: {
                Text("A change takes effect after MacLister restarts.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseStartFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = Settings.startDirectory
        panel.prompt = tr("Choose")
        if panel.runModal() == .OK, let url = panel.url { startDirectory = url.path }
    }
}

// MARK: - Listers

private struct ListersSettingsView: View {
    @AppStorage("buttonBarPosition") private var position = ButtonBarPosition.abovePath.rawValue
    @AppStorage("showButtonLabels") private var labels = false
    @AppStorage("relativeDates") private var relativeDates = true
    @AppStorage("dragSelectFromNames") private var dragSelect = true
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Button bar") {
                Picker("Position", selection: $position) {
                    ForEach(ButtonBarPosition.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                Toggle("Show button names next to the icons", isOn: $labels)
                LabeledContent("Buttons") {
                    HStack {
                        Button("Edit Buttons…") { ButtonEditorWindow.show() }
                        Button("Reload") { ButtonStore.shared.reload() }.help("Read buttons.json again after editing it by hand")
                        Button("Reset…") { confirmReset = true }
                    }
                }
            }
            Section("File list") {
                Toggle("Show dates as Today and Yesterday", isOn: $relativeDates)
                    .onChange(of: relativeDates) { _ in NotificationCenter.default.post(name: .columnsChanged, object: nil) }
                Toggle("Drag a selection rectangle from file names", isOn: $dragSelect)
                Text("Dragging from empty space of a row always selects. With this on, an unselected file name does too; a selected file is always dragged as a file.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Window title") {
                    Button("Lister Title…") { TitleFormatWindow.show() }
                }
            }
            Section("Customize") {
                LabeledContent("Keyboard") { Button("Keyboard Shortcuts…") { ShortcutsWindowController.shared.show() } }
                LabeledContent("Double-click on a file") { Button("Edit Filetypes…") { FiletypeStore.openInEditor() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Reset the buttons to the defaults?", isPresented: $confirmReset) {
            Button("Reset Buttons", role: .destructive) { ButtonStore.shared.resetToDefaults() }
        } message: {
            Text("Your own buttons are replaced by the standard set.")
        }
    }
}

// MARK: - Operations

private struct OperationsSettingsView: View {
    @State private var retention = OperationLog.retentionDays

    var body: some View {
        Form {
            Section {
                Picker("Keep the log for", selection: $retention) {
                    ForEach(OperationLog.retentionChoices, id: \.self) { days in
                        Text(days == 365 ? tr("1 year") : tr("%d days", days)).tag(days)
                    }
                }
                .onChange(of: retention) { days in
                    OperationLog.retentionDays = days
                    OperationLog.shared.prune()
                }
                LabeledContent("Log") { Button("Open Operation Log…") { OperationLogWindow.show() } }
            } header: {
                Text("Operation log")
            } footer: {
                Text("Every copy, move, upload, download, duplicate and Move to Trash is listed. Older entries are removed automatically, and the log never holds more than 1000.")
            }
            Section {
                Text("⌘Z takes back the last copy, move, duplicate or Move to Trash done on your disk in this session. Nothing is ever deleted for good.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Undo")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Updates

private struct UpdatesSettingsView: View {
    @AppStorage("autoUpdateCheck") private var automatic = false
    @State private var lastCheck = Settings.lastUpdateCheck
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                LabeledContent("Last checked") {
                    Text(lastCheck.map { Self.formatter.string(from: $0) } ?? tr("Never")).foregroundStyle(.secondary)
                }
                LabeledContent("Check now") {
                    Button("Check for Updates…") {
                        UpdateManager.shared.check(userInitiated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { lastCheck = Settings.lastUpdateCheck }
                    }
                }
            } header: {
                Text("MacLister")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $automatic)
                    .onChange(of: automatic) { _ in Settings.updateQuestionAsked = true }
            } footer: {
                Text("Once a day MacLister asks GitHub whether a newer release exists. Nothing is installed without your confirmation, and no information about you or your files is sent.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Window

/// The Settings window: a toolbar of tabs, as every Mac app has it (⌘,).
enum SettingsWindow {
    private static var window: NSWindow?

    /// The views of the tabs, for the self-test.
    static func tabViews() -> [(title: String, view: AnyView)] {
        [(tr("General"), AnyView(GeneralSettingsView())), (tr("Listers"), AnyView(ListersSettingsView())),
         (tr("Operations"), AnyView(OperationsSettingsView())), (tr("Updates"), AnyView(UpdatesSettingsView()))]
    }

    static func show(tab: Int = 0) {
        if let window {
            NSApp.bringToFront()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        let tabs: [(title: String, symbol: String, view: AnyView)] = [
            (tr("General"), "gearshape", AnyView(GeneralSettingsView())),
            (tr("Listers"), "macwindow", AnyView(ListersSettingsView())),
            (tr("Operations"), "clock.arrow.circlepath", AnyView(OperationsSettingsView())),
            (tr("Updates"), "arrow.down.circle", AnyView(UpdatesSettingsView())),
        ]
        for tab in tabs {
            let host = NSHostingController(rootView: tab.view)
            host.title = tab.title
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            controller.addTabViewItem(item)
        }
        controller.selectedTabViewItemIndex = min(max(tab, 0), tabs.count - 1)
        let created = NSWindow(contentViewController: controller)
        created.styleMask = [.titled, .closable]
        created.toolbarStyle = .preference
        created.isReleasedWhenClosed = false
        created.title = tabs[controller.selectedTabViewItemIndex].title
        created.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in window = nil }
        window = created
        NSApp.bringToFront()
        created.makeKeyAndOrderFront(nil)
    }
}
