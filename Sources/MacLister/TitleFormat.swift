import SwiftUI
import AppKit

/// What the title and the subtitle of a lister window say, written as a template with %-variables
/// (in the spirit of Directory Opus' title formats). `{ … }` marks an optional part: it is shown only
/// when every variable inside it has a value, so "{%l — }%n" is "Work — Reports" for a named lister and
/// just "Reports" for the others.
enum TitleFormat {
    static let defaultTitle = "{%l — }%n{ – %h}"
    static let defaultSubtitle = "%c{ · %F}{ · %R}"

    /// The values a template can use, gathered from a lister.
    struct Context {
        var name = "", path = "", shortPath = "", label = "", role = "", roleLong = "", volume = "", server = ""
        var items = "", folders = "", files = "", selected = "", selectedSize = ""
        var free = "", capacity = "", diskSummary = "", filter = "", time = "", date = ""

        func value(_ code: Character) -> String? {
            switch code {
            case "n": return name
            case "p": return path
            case "~": return shortPath
            case "l": return label
            case "r": return role
            case "R": return roleLong
            case "v": return volume
            case "h": return server
            case "c": return items
            case "d": return folders
            case "f": return files
            case "s": return selected
            case "S": return selectedSize
            case "F": return diskSummary
            case "b": return free
            case "B": return capacity
            case "m": return filter
            case "t": return time
            case "D": return date
            default: return nil
            }
        }
    }

    /// Every variable with its explanation, for the editor (the texts are translated there).
    static let variables: [(code: String, help: String)] = [
        ("%n", "Name of the folder"), ("%p", "Full path"), ("%~", "Path with ~ for the home folder"),
        ("%l", "The name you gave the lister"), ("%r", "SRC or DST"), ("%R", "SOURCE or DESTINATION (with “locked”)"),
        ("%v", "Name of the disk"), ("%h", "Server (for a server folder)"),
        ("%c", "Number of items, as text (“11 items”)"), ("%d", "Number of folders"), ("%f", "Number of files"),
        ("%s", "Number of selected items"), ("%S", "Size of the selection"),
        ("%F", "Free space, e.g. “340 GB free of 994 GB (66% used)”"), ("%b", "Free space on the disk"), ("%B", "Size of the disk"),
        ("%m", "The filter that is set"), ("%t", "Time"), ("%D", "Date"),
        ("%%", "A percent sign"), ("%{ %}", "A { or } character"),
    ]

    static let presets: [(name: String, title: String, subtitle: String)] = [
        (tr("Default"), defaultTitle, defaultSubtitle),
        (tr("Full path"), "{%l — }%~", tr("%c · %s selected{ · %S}")),
        (tr("Compact"), "%n", tr("%d folders, %f files{ · %R}")),
        (tr("With filter"), defaultTitle, tr("%c{ · %F}{ · %R}{ · filter: %m}")),
    ]

    /// Fills the template. Unknown variables are left as they are, so a typo is visible.
    static func render(_ template: String, _ context: Context) -> String {
        var output = ""
        var group: (text: String, complete: Bool)?
        func emit(_ text: String, complete: Bool = true) {
            if group != nil { group!.text += text; if !complete { group!.complete = false } } else { output += text }
        }
        let characters = Array(template)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "%", i + 1 < characters.count {
                let code = characters[i + 1]
                i += 2
                if code == "%" { emit("%"); continue }
                if code == "{" { emit("{"); continue }
                if code == "}" { emit("}"); continue }
                if let value = context.value(code) { emit(value, complete: !value.isEmpty) } else { emit("%\(code)") }
            } else if c == "{", group == nil {
                group = ("", true)
                i += 1
            } else if c == "}", let finished = group {
                if finished.complete { output += finished.text }
                group = nil
                i += 1
            } else {
                emit(String(c))
                i += 1
            }
        }
        if let open = group { output += "{" + open.text }       // an unclosed { is just text
        return output.trimmingCharacters(in: .whitespaces)
    }

    static var title: String {
        get { let stored = UserDefaults.standard.string(forKey: "titleFormat") ?? ""; return stored.isEmpty ? defaultTitle : stored }
        set { UserDefaults.standard.set(newValue == defaultTitle ? "" : newValue, forKey: "titleFormat"); notify() }
    }
    static var subtitle: String {
        get { let stored = UserDefaults.standard.string(forKey: "subtitleFormat") ?? ""; return stored.isEmpty ? defaultSubtitle : stored }
        set { UserDefaults.standard.set(newValue == defaultSubtitle ? "" : newValue, forKey: "subtitleFormat"); notify() }
    }
    private static func notify() { NotificationCenter.default.post(name: .titleFormatChanged, object: nil) }

    // MARK: From a lister

    static func context(for model: ListerModel, now: Date = Date()) -> Context {
        var c = Context()
        let url = model.url
        c.label = model.label
        if let title = VirtualPlace.title(for: url), model.virtualPlace != nil {
            c.name = title
        } else if url.isFileURL {
            c.name = FileManager.default.displayName(atPath: url.path)
            c.path = url.path
            c.shortPath = (url.path as NSString).abbreviatingWithTildeInPath
            if let volume = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName { c.volume = volume }
            if !VolumeInfo.hidden, let numbers = VolumeInfo.figures(for: url) { c.free = numbers.free; c.capacity = numbers.total }
            c.diskSummary = VolumeInfo.summary(for: url) ?? ""
        } else {
            let path = RemoteURL.path(of: url)
            let server = RemoteURL.serverLabel(of: url)
            c.name = path == "/" ? server : (path as NSString).lastPathComponent
            c.server = path == "/" ? "" : server
            c.path = path
            c.shortPath = path
        }
        switch model.role {
        case .source:      c.role = "SRC"; c.roleLong = tr("SOURCE") + (model.roleLocked ? " " + tr("(locked)") : "")
        case .destination: c.role = "DST"; c.roleLong = tr("DESTINATION") + (model.roleLocked ? " " + tr("(locked)") : "")
        case .none:        break
        }
        c.items = trCount("%d items", model.items.count)
        c.folders = String(model.items.filter(\.isDirectory).count)
        c.files = String(model.items.filter { !$0.isDirectory }.count)
        c.selected = String(model.selectedURLs.count)
        let bytes = model.selectedBytes
        c.selectedSize = model.selectedURLs.isEmpty ? "" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        c.filter = model.filter
        c.time = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        c.date = DateFormatter.localizedString(from: now, dateStyle: .medium, timeStyle: .none)
        return c
    }
}

extension VolumeInfo {
    /// Free space and size of the disk as texts.
    static func figures(for url: URL) -> (free: String, total: String)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity else { return nil }
        return (ByteCountFormatter.string(fromByteCount: free, countStyle: .file), ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))
    }
}

extension Notification.Name {
    static let titleFormatChanged = Notification.Name("MacListerTitleFormatChanged")
}

// MARK: - Editor

struct TitleFormatEditor: View {
    @State private var title: String
    @State private var subtitle: String
    let close: () -> Void

    init(title: String = TitleFormat.title, subtitle: String = TitleFormat.subtitle, close: @escaping () -> Void) {
        _title = State(initialValue: title)
        _subtitle = State(initialValue: subtitle)
        self.close = close
    }

    private var preview: (String, String) {
        guard let model = ListerManager.shared.frontmost?.model else { return ("", "") }
        let context = TitleFormat.context(for: model)
        return (TitleFormat.render(title, context), TitleFormat.render(subtitle, context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lister Title").font(.headline)
            Text("Write the title and the line under it with variables. Text in { } is shown only when everything inside it has a value.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Title")
                    TextField("", text: $title).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Under the title")
                    TextField("", text: $subtitle).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Preview").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preview.0).fontWeight(.semibold)
                        Text(preview.1).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Menu("Presets") {
                    ForEach(Array(TitleFormat.presets.enumerated()), id: \.offset) { _, preset in
                        Button(preset.name) { title = preset.title; subtitle = preset.subtitle }
                    }
                }
                .fixedSize()
                Spacer()
            }

            GroupBox("Variables") {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        ForEach(Array(TitleFormat.variables.enumerated()), id: \.offset) { _, item in
                            GridRow {
                                Text(item.code).font(.system(.callout, design: .monospaced)).foregroundStyle(Color.accentColor)
                                Text(LocalizedStringKey(item.help)).font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .frame(height: 130)
            }

            HStack {
                Button("Reset") { title = TitleFormat.defaultTitle; subtitle = TitleFormat.defaultSubtitle }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                Button("OK") {
                    TitleFormat.title = title
                    TitleFormat.subtitle = subtitle
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

enum TitleFormatWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { NSApp.bringToFront(); window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: TitleFormatEditor(close: { window?.close() }))
        let created = NSWindow(contentViewController: host)
        created.styleMask = [.titled, .closable]
        created.title = tr("Lister Title")
        created.isReleasedWhenClosed = false
        created.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in window = nil }
        window = created
        NSApp.bringToFront()
        created.makeKeyAndOrderFront(nil)
    }
}
