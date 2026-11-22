import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The applications that can open a file, for the "Open with" line of the Info sheet.
struct InfoOpenWith {
    /// "Plain Text", "PDF document" …: what the system calls this kind of file.
    let kind: String
    /// The applications that can open it, the default one first.
    let apps: [URL]
    let defaultApp: URL?

    /// Offered for local files that are not folders and are all of one kind; nil otherwise.
    static func make(for urls: [URL]) -> InfoOpenWith? {
        guard let first = urls.first else { return nil }
        var type: UTType?
        for url in urls {
            guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]),
                  values.isDirectory != true, let kind = values.contentType else { return nil }
            if let type, type != kind { return nil }
            type = kind
        }
        guard let type else { return nil }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let defaultApp { apps.removeAll { $0 == defaultApp }; apps.insert(defaultApp, at: 0) }
        guard !apps.isEmpty else { return nil }
        let described = (try? first.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription
        return InfoOpenWith(kind: described ?? type.localizedDescription ?? type.identifier, apps: Array(apps.prefix(30)), defaultApp: defaultApp)
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Info (⌘I): the facts about the selected items, and for files the application they open with, as in Finder's
/// Get Info: choosing another application asks whether it should open all files of this kind from now on.
struct InfoView: View {
    let title: String
    let text: String
    let icon: NSImage?
    let openWith: InfoOpenWith?
    var canChecksum = false
    var onChecksums: () -> Void = {}
    /// Asks the question and changes the system's default; calls back with whether it was changed.
    var onMakeDefault: (URL, @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
    /// Lets the user pick an application that is not listed; calls back with it when it became the default.
    var onOther: (@escaping (URL?) -> Void) -> Void = { $0(nil) }
    var close: () -> Void

    @State private var apps: [URL] = []
    @State private var current: URL?
    @State private var picked: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).lineLimit(2).truncationMode(.middle)
                    Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if openWith != nil, !apps.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Text(tr("Open with:"))
                    Picker("", selection: $picked) {
                        ForEach(apps, id: \.self) { app in
                            Text(app == current ? tr("%@ (default)", InfoOpenWith.name(of: app)) : InfoOpenWith.name(of: app)).tag(Optional(app))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Button(tr("Other…")) {
                        onOther { app in
                            guard let app else { return }
                            if !apps.contains(app) { apps.insert(app, at: 0) }
                            current = app
                            picked = app
                        }
                    }
                }
                Text(tr("Choosing another application asks whether it should open all “%@” files.", openWith?.kind ?? ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                if canChecksum { Button(tr("Checksums…")) { onChecksums() } }
                Spacer()
                Button(tr("OK")) { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 280)
        .onAppear {
            guard let openWith else { return }
            apps = openWith.apps
            current = openWith.defaultApp
            picked = openWith.defaultApp ?? openWith.apps.first
        }
        .onChange(of: picked) { app in
            guard let app, app != current else { return }
            onMakeDefault(app) { changed in
                if changed { current = app } else { picked = current }
            }
        }
    }
}

/// The application macOS opens a kind of file with, as Settings → Filetypes shows and changes it for a filetype.
enum SystemDefaultApplication {
    /// The type of the first plain extension of a filetype ("md", "tar.gz" → gz); nil for * and @folder, or when the
    /// system does not know any of them.
    static func type(forExtensions extensions: [String]) -> UTType? {
        for entry in extensions where !entry.isEmpty && !entry.hasPrefix("@") && entry != "*" {
            let last = entry.split(separator: ".").last.map(String.init) ?? entry
            if let type = UTType(filenameExtension: last), type != .data, type != .item { return type }
        }
        return nil
    }

    static func application(for type: UTType) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: type) }

    /// Asks, as Finder's Change All… does, then makes `app` the default for `type`. `completion`: whether it was changed.
    static func change(to app: URL, for type: UTType, completion: @escaping (Bool) -> Void) {
        let kind = type.localizedDescription ?? type.identifier
        let name = InfoOpenWith.name(of: app)
        let alert = NSAlert()
        alert.messageText = tr("Always open “%@” files with %@?", kind, name)
        alert.informativeText = tr("This changes the application for all files of this kind, in Finder and in every other application, not only in MacLister.")
        alert.addButton(withTitle: tr("Change All"))
        alert.addButton(withTitle: tr("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { completion(false); return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
            DispatchQueue.main.async {
                if let error {
                    let failed = NSAlert()
                    failed.messageText = tr("Cannot change the application: %@", error.localizedDescription)
                    failed.runModal()
                }
                completion(error == nil)
            }
        }
    }
}

/// In Settings → Filetypes: the application the system opens these files with, and a way to change it.
struct SystemDefaultRow: View {
    let extensions: [String]
    @State private var refreshed = 0

    var body: some View {
        if let type = SystemDefaultApplication.type(forExtensions: extensions) {
            let app = SystemDefaultApplication.application(for: type)
            LabeledContent(tr("System default application")) {
                HStack(spacing: 8) {
                    if let app { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 16, height: 16) }
                    Text(app.map(InfoOpenWith.name(of:)) ?? tr("None")).id(refreshed)
                    Button(tr("Change…")) { choose(for: type) }
                }
            }
            Text(tr("What macOS opens “%@” files with, also in Finder: this is not a setting of MacLister's own.", type.localizedDescription ?? type.identifier))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose(for type: UTType) {
        let panel = NSOpenPanel()
        panel.title = tr("Choose an Application")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        SystemDefaultApplication.change(to: app, for: type) { changed in if changed { refreshed += 1 } }
    }
}
