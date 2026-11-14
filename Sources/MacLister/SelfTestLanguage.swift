import AppKit
import SwiftUI
import Vision

/// `MacLister --selftest-language -AppleLanguages "(pl)"`: checks that the Polish interface is really
/// used (menus, dialogs, format strings) and that the language choice is stored where macOS keeps it.
enum SelfTestLanguage {
    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("language \(condition ? "ok  " : "FAIL") \(message)")
    }

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maclister-language-\(UUID().uuidString)")
        AppSupport.override = root.appendingPathComponent("support")
        let dir = root.appendingPathComponent("A")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: AppSupport.override!, withIntermediateDirectories: true)
        try? Data(count: 10).write(to: dir.appendingPathComponent("a.txt"))

        check(AppLanguage.effectiveCode == "pl", "the app runs in Polish: \(AppLanguage.effectiveCode)")
        check(tr("Cancel") == "Anuluj" && tr("Move to Trash") == "Przenieś do Kosza", "plain strings are translated")
        check(tr("Disconnect from %@", "x") == "Rozłącz z x", "format strings take their arguments: \(tr("Disconnect from %@", "x"))")
        let plurals = [1, 2, 4, 5, 12, 22, 25].map { trCount("%d items", $0) }
        check(plurals == ["1 element", "2 elementy", "4 elementy", "5 elementów", "12 elementów", "22 elementy", "25 elementów"], "Polish plurals follow the grammar: \(plurals)")
        check(trCount("Move %d items to the Trash?", 3) == "Przenieść 3 elementy do Kosza?", "plural in a sentence: \(trCount("Move %d items to the Trash?", 3))")
        check(tr("Copy to “%@”", "dst") == "Kopiuj do „dst”", "text arguments: \(tr("Copy to “%@”", "dst"))")
        check(tr("This text has no translation") == "This text has no translation", "an unknown text stays as it is")
        check(VirtualPlace.recents.title == "Ostatnie" && VirtualPlace.shared.title == "Udostępniane" && ListerColumn.folder.title == "Gdzie", "the new places are named in Polish")
        check(ListerAction.swapSourceDestination.title == "Zamień źródło i cel" && ListerAction.revealInFinder.title == "Pokaż w Finderze", "action names are translated")
        check(ListerColumn.date.title == "Data zmian" && ListerColumn.permissions.title == "Uprawnienia", "column titles are translated")
        check(DesktopTrigger.middleClick.menuTitle == "Kliknięcie środkowym przyciskiem", "settings menu titles are translated")
        check(ListerViewController.progressText(verb: tr("Copying"), progress: TransferProgress(itemsDone: 1, itemsTotal: 4, bytesDone: 1_000_000, bytesTotal: 8_000_000, current: "x"), speed: 0, paused: false).hasPrefix("Kopiowanie 2 z 4"), "progress text is Polish")

        let manager = ListerManager.shared
        let one = manager.openLister(directory: dir, anchor: .cascade(from: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = one.listerViewController else { check(false, "lister available"); finish(root); return }
            let menu = NSMenu()
            vc.populate(menu, selection: one.model.items.filter { $0.name == "a.txt" })
            let titles = menu.flatTitles
            for expected in ["Otwórz", "Przenieś do Kosza", "Informacje", "Zmień nazwę…", "Duplikuj".replacingOccurrences(of: "Duplikuj", with: "Powiel"), "Utwórz alias", "Szybki podgląd", "Kopiuj", "Udostępnij", "Tagi…", "Szybkie czynności", "Usługi", "Pokaż w Finderze", "Dodaj zakładkę", "Odśwież"] {
                check(titles.contains(expected), "context menu has “\(expected)”")
            }
            check(titles.contains { $0.hasPrefix("Kompresuj „a.txt”") }, "compress item is Polish")
            check(!titles.contains("Move to Trash") && !titles.contains("Open"), "no English leftovers in the context menu")
            let title = vc.makeTitleBarMenu().items.map(\.title)
            check(title.contains("Ustaw jako źródło") && title.contains("Zamknij lister") && title.contains("Połącz z serwerem…"), "title-bar menu is Polish: \(title.filter { !$0.isEmpty }.prefix(6))")

            // SwiftUI: literals are looked up in the same table. Render a small view and read it back with OCR.
            struct Probe: View {
                var body: some View {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Speed").font(.largeTitle)
                        Text("Cancel").font(.largeTitle)
                        Text("Keyboard Shortcuts").font(.largeTitle)
                    }
                    .padding(24).background(Color.white).foregroundStyle(Color.black)
                    .environment(\.colorScheme, .light)
                }
            }
            let renderer = ImageRenderer(content: Probe())
            renderer.scale = 3
            if let image = renderer.cgImage {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["pl-PL", "en-US"]
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let seen = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
                check(seen.contains("Prędkość") && seen.contains("Anuluj") && seen.contains("klawiszowe"), "SwiftUI text is Polish (OCR read: \(seen))")
                check(!seen.contains("Speed") && !seen.contains("Cancel"), "no English left in the SwiftUI text")
            } else {
                check(false, "SwiftUI probe rendered")
            }

            // audit: draw every view and report the texts that have no Polish translation
            LocalizationAudit.install()
            LocalizationAudit.misses = []
            var profile = ServerProfile(); profile.host = "example.org"; profile.user = "me"
            LocalizationAudit.touch(ShortcutsView(), size: NSSize(width: 620, height: 640))
            LocalizationAudit.touch(SelectByAttributesView(onSelect: { _ in }, close: { }))
            LocalizationAudit.touch(BatchRenameView(items: [dir.appendingPathComponent("a.txt")], onApply: { _ in }, close: { }), size: NSSize(width: 640, height: 580))
            LocalizationAudit.touch(AttributesView(title: "x", initial: AttributeFormState.initial(for: [dir.appendingPathComponent("a.txt")]), onApply: { _ in }, close: { }), size: NSSize(width: 500, height: 600))
            LocalizationAudit.touch(ConnectToServerView(initial: nil, initialSecret: "", onConnect: { _, _, _, _, _ in }, close: { }), size: NSSize(width: 520, height: 560))
            LocalizationAudit.touch(ConnectToServerView(initial: profile, initialSecret: "", onConnect: { _, _, _, _, _ in }, close: { }), size: NSSize(width: 520, height: 560))
            let tagState = TagsEditorState.make(for: [dir.appendingPathComponent("a.txt")], alsoSeen: ["Extra"])
            LocalizationAudit.touch(TagsEditorView(state: tagState, title: "a.txt", onApply: { _, _ in }, close: { }), size: NSSize(width: 380, height: 440))
            let busy = TransferMonitor(title: tr("Copying"), from: "A", to: "B")
            busy.update(TransferProgress(itemsDone: 0, itemsTotal: 3, bytesDone: 1000, bytesTotal: 9000, current: "x"))
            LocalizationAudit.touch(TransferDetailsView(monitor: busy, close: { }), size: NSSize(width: 500, height: 560))
            busy.pause()
            LocalizationAudit.touch(TransferDetailsView(monitor: busy, close: { }), size: NSSize(width: 500, height: 560))
            busy.finish(.failed)
            LocalizationAudit.touch(TransferDetailsView(monitor: busy, close: { }), size: NSSize(width: 500, height: 560))
            LocalizationAudit.touch(PathBarView(model: one.model, onToggleRole: { _ in }, onConnect: { _ in }), size: NSSize(width: 700, height: 80))
            LocalizationAudit.touch(ButtonBarView(model: one.model, store: .shared, onAction: { _ in }), size: NSSize(width: 700, height: 60))
            one.model.progress = TransferStatus(text: "x", fraction: 0.3, cancel: { }, details: busy)
            LocalizationAudit.touch(StatusBarView(model: one.model), size: NSSize(width: 700, height: 40))
            for tab in SettingsWindow.tabViews() { LocalizationAudit.touch(tab.view, size: NSSize(width: 520, height: 520)) }
            LocalizationAudit.touch(OperationLogView(), size: NSSize(width: 640, height: 420))
            LocalizationAudit.touch(ButtonEditorView(initial: ListerButton.defaults, selection: 3, close: { }), size: NSSize(width: 700, height: 480))
            LocalizationAudit.touch(TitleFormatEditor(close: { }), size: NSSize(width: 520, height: 600))
            one.model.progress = nil
            let known: Set<String> = ["OK", "Regex", "Folder", "Mission Control", "Spotlight", "Audio", "Video", "port", "ext", "Server", "Servers", "Terminal", "FTP", "SFTP"]
            let untranslated = LocalizationAudit.misses.subtracting(known).sorted()
            DebugLog.write("language info audit saw \(LocalizationAudit.misses.count) untranslated lookups: \(LocalizationAudit.misses.sorted().prefix(40))")
            check(untranslated.isEmpty, "no AppKit text looked up while drawing the views lacks a translation; missing: \(untranslated)")

            // the choice is stored where macOS keeps a per-app language, and put back afterwards
            let domain = Bundle.main.bundleIdentifier ?? "com.example.MacLister"
            let before = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"]
            AppLanguage.english.apply()
            check(AppLanguage.current == .english, "choosing English is stored")
            AppLanguage.polish.apply()
            check(AppLanguage.current == .polish, "choosing Polski is stored")
            AppLanguage.system.apply()
            check(UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] == nil && AppLanguage.current == .system, "System Default removes the setting")
            if let before { UserDefaults.standard.set(before, forKey: "AppleLanguages") }
            check(AppLanguage.allCases.map(\.menuTitle) == ["Domyślny systemowy", "English", "Polski"], "language menu entries: \(AppLanguage.allCases.map(\.menuTitle))")

            manager.closeAll()
            finish(root)
        }
    }

    private static func finish(_ root: URL) {
        AppSupport.override = nil
        try? FileManager.default.removeItem(at: root)
        DebugLog.write("language \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }
}
