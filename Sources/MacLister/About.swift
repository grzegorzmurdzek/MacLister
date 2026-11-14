import SwiftUI
import AppKit

/// What the About window shows. Version, build and release date come from Info.plist (package.sh stamps the date).
enum AboutInfo {
    static let author = "Grzegorz Murdzek"
    static let website = URL(string: "https://maclister.github.io/")!
    static let repository = URL(string: "https://github.com/grzegorzmurdzek/MacLister")!

    static var version: String { UpdateChecker.currentVersion }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// "1.4.3 (build 10)", or just the version when there is no build number.
    static var versionText: String { build.isEmpty ? version : tr("%@ (build %@)", version, build) }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 \(author)"
    }

    /// The day this version was released (Info.plist key MacListerReleaseDate, "yyyy-MM-dd").
    static var releaseDate: Date? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "MacListerReleaseDate") as? String else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    /// "14 November 2026" in the language of the interface.
    static func dateText(_ date: Date, language: String = Bundle.main.preferredLocalizations.first ?? "en") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("MacLister").font(.system(size: 22, weight: .semibold))
            Text("A lister-based file manager in the spirit of Directory Opus Magellan.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Version").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(AboutInfo.versionText).textSelection(.enabled)
                }
                if let date = AboutInfo.releaseDate {
                    GridRow {
                        Text("Released").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(AboutInfo.dateText(date))
                    }
                }
                GridRow {
                    Text("Author").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(AboutInfo.author)
                }
                GridRow {
                    Text("License").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: "MIT")
                }
            }
            .padding(.top, 4)

            HStack(spacing: 14) {
                Link("Website", destination: AboutInfo.website)
                Link("Source code", destination: AboutInfo.repository)
            }
            .font(.callout)

            Button("Check for Updates…") { UpdateManager.shared.check(userInitiated: true) }
                .padding(.top, 2)

            Text(AboutInfo.copyright).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 340)
    }
}

enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { NSApp.bringToFront(); window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: AboutView())
        let created = NSWindow(contentViewController: host)
        created.styleMask = [.titled, .closable]
        created.title = tr("About MacLister")
        created.isReleasedWhenClosed = false
        created.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in window = nil }
        window = created
        NSApp.bringToFront()
        created.makeKeyAndOrderFront(nil)
    }

    static var isOpen: Bool { window != nil }
}
