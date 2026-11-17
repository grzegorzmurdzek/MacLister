import SwiftUI
import AppKit

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("desktopTrigger") private var trigger = DesktopTrigger.doubleClick.rawValue
    @AppStorage("centerOnCursor") private var center = false
    @AppStorage("startDirectory") private var startDirectory = ""
    @AppStorage("restoreLayoutAtLaunch") private var restoreLayout = true
    @AppStorage("autoAssignRoles") private var autoRoles = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("listersOnAllDesktops") private var allDesktops = false
    @State private var language = AppLanguage.current

    private var startsOnDevices: Bool { startDirectory == VirtualPlace.devices.url.absoluteString }
    private var startsOnHome: Bool { startDirectory.isEmpty }
    private var startsOnFolder: Bool { !startsOnHome && !startsOnDevices }

    private var startFolderText: String {
        if startsOnDevices { return VirtualPlace.devices.title }
        return startsOnHome ? tr("Home") : PathText.short((startDirectory as NSString).expandingTildeInPath)
    }

    /// The button of the start place that is in use looks pressed.
    @ViewBuilder private func startButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        if active {
            Button(title, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(title, action: action)
        }
    }

    var body: some View {
        Form {
            Section("Opening listers") {
                Picker("Open a lister with", selection: $trigger) {
                    ForEach(DesktopTrigger.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                Toggle("Center the lister on the pointer", isOn: $center)
                Toggle("First lister is the source, the next the destination", isOn: $autoRoles)
                Text("A new lister becomes the source when there is none, then the destination. When the source is closed, the destination takes its place and the next lister becomes the destination. Off: set SRC and DST yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Start folder") {
                    HStack {
                        Text(startFolderText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        startButton(tr("Choose…"), active: startsOnFolder) { chooseStartFolder() }
                        startButton(tr("Home"), active: startsOnHome) { startDirectory = "" }
                        startButton(tr("Devices"), active: startsOnDevices) { startDirectory = VirtualPlace.devices.url.absoluteString }
                    }
                }
                Toggle("Reopen the saved layout when MacLister starts", isOn: $restoreLayout)
                Toggle("Show listers on all desktops", isOn: $allDesktops)
                    .onChange(of: allDesktops) { _ in ListerManager.shared.applyDesktopBehavior() }
                Text("To keep your listers on a desktop of their own, switch to that desktop and choose Move All Listers to This Desktop (menu-bar icon, Dock icon or a shortcut). Or Control-click the Dock icon → Options → Assign To → This Desktop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show MacLister in the Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _ in (NSApp.delegate as? AppDelegate)?.applyDockIconPreference() }
            } header: {
                Text("Dock")
            } footer: {
                Text("Right-click the Dock icon for the open listers and New Lister. The menu-bar icon stays either way.")
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
        panel.directoryURL = Settings.startDirectory.isFileURL ? Settings.startDirectory : FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = tr("Choose")
        if panel.runModal() == .OK, let url = panel.url { startDirectory = url.path }
    }
}

// MARK: - Listers

private struct ListersSettingsView: View {
    @AppStorage("relativeDates") private var relativeDates = true
    @AppStorage("foldersFirst") private var foldersFirst = true
    @AppStorage("dragSelectFromNames") private var dragSelect = true
    @AppStorage("browseArchives") private var browseArchives = true
    @AppStorage("springLoadedFolders") private var springLoaded = true
    @AppStorage("newWindowStyle") private var windowStyle = NewWindowStyle.lister.rawValue

    var body: some View {
        Form {
            Section("Two-panel window") {
                Picker("Opens", selection: $windowStyle) {
                    ForEach(NewWindowStyle.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                .help("What the desktop click, the global shortcut and the Dock icon open. ⌥⌘N opens a two-panel window either way.")
            }
            Section("File list") {
                Toggle("Keep folders above files when sorting", isOn: $foldersFirst)
                    .onChange(of: foldersFirst) { _ in NotificationCenter.default.post(name: .columnsChanged, object: nil) }
                Toggle("Show dates as Today and Yesterday", isOn: $relativeDates)
                    .onChange(of: relativeDates) { _ in NotificationCenter.default.post(name: .columnsChanged, object: nil) }
                Toggle("Open archives like folders", isOn: $browseArchives)
                Text("A double-click on a zip, tar, 7z or rar file shows what is inside, read-only; copy files out with Copy. Off: your filetype rule decides (by default it unpacks the archive). Extract unpacks it either way.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open folders when you drag files over them", isOn: $springLoaded)
                Text("Hold the files over a folder in a list, or a closed folder in the tree, for a moment and it opens, so you can carry them several levels down in one drag.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Select by dragging from file names", isOn: $dragSelect)
                Text("Dragging from empty space of a row always selects. With this on, an unselected file name does too; a selected file is always dragged as a file.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Window title") {
                    Button("Lister Title…") { TitleFormatWindow.show() }
                }
            }
            Section("Customize") {
                LabeledContent("Keyboard") { Button("Keyboard Shortcuts…") { ShortcutsWindowController.shared.show() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Buttons

private struct ButtonsSettingsView: View {
    @AppStorage("buttonBarPosition") private var position = ButtonBarPosition.abovePath.rawValue
    @AppStorage("showButtonLabels") private var labels = false
    @AppStorage("showButtonMenuArrows") private var menuArrows = false
    @AppStorage("buttonMenuDirection") private var menuDirection = ButtonMenuDirection.automatic.rawValue
    @State private var confirmReset = false
    @AppStorage("terminalBundleID") private var terminal = "com.apple.Terminal"
    @AppStorage("textEditorBundleID") private var editor = "com.apple.TextEdit"

    /// Installed editors, plus the chosen one even when it is not in the list (an app picked with "Other App…").
    private var editorChoices: [(name: String, id: String)] {
        var choices = AppDelegate.editorChoices()
        if !choices.contains(where: { $0.id == editor }) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? editor
            choices.append((name, editor))
        }
        return choices
    }

    private func chooseEditorApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { editor = id }
    }

    private var terminalChoices: [(name: String, id: String)] {
        var choices = AppDelegate.terminalChoices()
        // a custom bundle id set with `defaults write` stays visible
        if !choices.contains(where: { $0.id == terminal }) { choices.append((terminal, terminal)) }
        return choices
    }

    var body: some View {
        Form {
            Section("Button bar") {
                Picker("Position", selection: $position) {
                    ForEach(ButtonBarPosition.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                Toggle("Show button names next to the icons", isOn: $labels)
                Toggle("Show an arrow on buttons that have a menu", isOn: $menuArrows)
                Text("A button can have a menu of more actions (Edit Buttons…). Hold the button down for a moment and the menu opens; a plain click still does the button's own action. With the arrow, a click on it opens the menu at once.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Menu opens", selection: $menuDirection) {
                    ForEach(ButtonMenuDirection.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                LabeledContent("Buttons") {
                    HStack {
                        Button("Edit Buttons…") { ButtonEditorWindow.show() }
                        Button("Reload") { ButtonStore.shared.reload() }.help("Read buttons.json again after editing it by hand")
                        Button("Reset…") { confirmReset = true }
                    }
                }
            }
            Section("Terminal Here") {
                Picker("Terminal app", selection: $terminal) {
                    ForEach(terminalChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                Picker("Text editor", selection: $editor) {
                    ForEach(editorChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Spacer()
                    Button("Other App…") { chooseEditorApp() }
                }
            } header: {
                Text("New Text File")
            } footer: {
                Text("The New Text File button makes an empty text file in the folder and opens it in this app.")
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

// MARK: - Tabs

private struct TabsSettingsView: View {
    @AppStorage("listerTabs") private var tabs = true
    @AppStorage("tabDoubleClick") private var tabDoubleClick = TabDoubleClickAction.nameTab.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Allow tabs in listers", isOn: $tabs)
                    .onChange(of: tabs) { _ in ListerManager.shared.applyTabSetting() }
                Picker("Double-click on a tab", selection: $tabDoubleClick) {
                    ForEach(TabDoubleClickAction.allCases, id: \.rawValue) { Text($0.menuTitle).tag($0.rawValue) }
                }
                .disabled(!tabs)
            } header: {
                Text("Tabs")
            } footer: {
                Text("⌘T opens the folder in a new tab, ⌘-double-click opens a folder in one, ⌃Tab goes to the next tab and ⌘W closes it. A double-click on a tab does what you choose above (by default it names the tab). A tab shows the folder's name; Name This Tab… in the title-bar menu gives it a name of its own. Source and destination belong to the window: the tab you see has the role, and it goes along to the tab you switch to. Off: every tab becomes a lister of its own again.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Finder

/// "Open in MacLister" for Finder: the Quick Action is added to ~/Library/Services and removed again here.
private struct FinderActionSection: View {
    @State private var installed = FinderIntegration.isInstalled()
    @State private var problem: String?

    var body: some View {
            Section {
                LabeledContent("Quick Action “Open in MacLister”") {
                    HStack {
                        if installed {
                            Text("Installed").foregroundStyle(.secondary)
                            Button("Remove") { set(add: false) }
                        } else {
                            Button("Add to Finder") { set(add: true) }
                        }
                    }
                }
                if let problem = problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Finder")
            } footer: {
                Text("Adds a Quick Action to ~/Library/Services. Then right-click a folder or file in Finder → Quick Actions → Open in MacLister (also in Finder → Services). A folder opens in a lister; for a file, the folder it is in opens with the file selected. A key for it can be set in System Settings → Keyboard → Keyboard Shortcuts → Services.")
            }
    }

    private func set(add: Bool) {
        do {
            if add { try FinderIntegration.install() } else { try FinderIntegration.uninstall() }
            problem = nil
        } catch {
            problem = tr("Cannot change ~/Library/Services: %@", error.localizedDescription)
        }
        installed = FinderIntegration.isInstalled()
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
                LabeledContent("Recent folders in the Go menu") {
                    Button("Clear Recent Folders…") { HistoryClearing.confirmAndClear(.recentFolders) }
                }
                LabeledContent("Operation log") {
                    Button("Clear Operation Log…") { HistoryClearing.confirmAndClear(.operationLog) }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Each asks for confirmation first. Files and bookmarks are never touched.")
            }
            Section {
                Text("⌘Z takes back the last copy, move, duplicate or Move to Trash done on your disk in this session. Nothing is ever deleted for good.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Undo")
            }
            FinderActionSection()
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
                .onReceive(NotificationCenter.default.publisher(for: .updateCheckFinished)) { _ in lastCheck = Settings.lastUpdateCheck }
                LabeledContent("Check now") {
                    Button("Check for Updates…") { UpdateManager.shared.check(userInitiated: true) }
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
         (tr("Tabs"), AnyView(TabsSettingsView())), (tr("Buttons"), AnyView(ButtonsSettingsView())),
         (tr("Filetypes"), AnyView(FiletypeEditorView())), (tr("Operations"), AnyView(OperationsSettingsView())), (tr("Updates"), AnyView(UpdatesSettingsView()))]
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
            (tr("Tabs"), "rectangle.stack", AnyView(TabsSettingsView())),
            (tr("Buttons"), "square.grid.2x2", AnyView(ButtonsSettingsView())),
            (tr("Filetypes"), "doc.badge.gearshape", AnyView(FiletypeEditorView())),
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
