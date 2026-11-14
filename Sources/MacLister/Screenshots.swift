import AppKit
import SwiftUI

/// `MacLister --screenshots <folder> [dark]`: draws the app's own windows with made-up files and saves
/// them as PNGs for the README and the forum. A window of its own (a soft gradient) covers the screen behind
/// the app's windows, so nothing else from the desktop can appear in a picture. Needs Screen Recording
/// access for the process that starts it.
enum Screenshots {
    private static var outDir = URL(fileURLWithPath: "/tmp")
    private static var dark = false
    private static var demo = DemoFiles()
    private static var steps: [(String, () -> Void)] = []
    private static var backdrop: NSWindow?

    // MARK: Entry

    static func run(outDir: URL, dark: Bool) {
        self.outDir = outDir
        self.dark = dark
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-shots-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AppSupport.override = support                         // bookmarks, layouts, servers: nothing of the user's
        SharedPlaces.browsingEnabled = false
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        demo = DemoFiles()
        demo.create()
        VolumeInfo.hidden = true                                     // no real disk figures in the title bars
        makeBackdrop()

        let suffix = dark ? "-dark" : ""
        queue("lister-pair\(suffix)") { pair(named: "lister-pair\(suffix)") }
        queue("context-menu\(suffix)") { contextMenu(named: "context-menu\(suffix)") }
        queue("transfer-details\(suffix)") { transferDetails(named: "transfer-details\(suffix)") }
        if !dark {
            queue("title-bar-menu") { titleBarMenu(named: "title-bar-menu") }
            queue("batch-rename") { batchRename(named: "batch-rename") }
            queue("name-lister") { nameLister(named: "name-lister") }
            queue("connect-to-server") { connectSheet(named: "connect-to-server") }
            queue("keyboard-shortcuts") { shortcuts(named: "keyboard-shortcuts") }
        }
        next()
    }

    private static func queue(_ name: String, _ body: @escaping () -> Void) { steps.append((name, body)) }

    /// Runs the next scene; each scene calls `finishScene` when its picture is saved.
    private static func next() {
        guard !steps.isEmpty else { finish(); return }
        let (name, body) = steps.removeFirst()
        print("scene \(name)")
        body()
    }

    private static func finishScene() {
        ListerManager.shared.closeAll()
        for window in NSApp.windows where window.isVisible && window.level == .normal && window !== backdrop { window.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
    }

    private static func finish() {
        backdrop?.close()
        demo.remove()
        if let support = AppSupport.override { try? FileManager.default.removeItem(at: support) }
        AppSupport.override = nil
        print("done: \(outDir.path)")
        NSApp.terminate(nil)
    }

    // MARK: Scenes

    /// The sharpest display (a Retina one when there is one): pictures made there have twice the pixels.
    private static var chosenScreen: NSScreen? {
        NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main
    }

    private static func screen() -> NSRect { chosenScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// Two listers: Projects (source, selection) and a NAS (destination) with a copy in progress.
    private static func pair(named name: String) {
        let area = screen()
        let size = NSSize(width: 700, height: 430)
        let leftOrigin = NSPoint(x: area.minX + 60, y: area.maxY - size.height - 90)
        let rightOrigin = NSPoint(x: leftOrigin.x + size.width + 36, y: leftOrigin.y - 34)
        let manager = ListerManager.shared
        let left = manager.openLister(directory: demo.projects, anchor: .origin(leftOrigin))
        let right = manager.openLister(directory: demo.backup, anchor: .origin(rightOrigin))
        for controller in [left, right] { controller.window?.setContentSize(size) }
        left.window?.setFrameOrigin(leftOrigin)
        right.window?.setFrameOrigin(rightOrigin)
        left.model.setLabel(tr("Work"), color: "blue")
        right.model.setLabel("NAS", color: "orange")
        manager.toggleRole(.source, for: left)
        manager.toggleRole(.destination, for: right)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            left.listerViewController?.setSelectionForSheetTest(["report", "budget", "video"].map { demo.project($0) })
            let monitor = syntheticMonitor(progressFraction: 0.62)
            let status = TransferStatus(text: ListerViewController.progressText(verb: tr("Copying"), progress: monitor.progress, speed: monitor.speed, paused: false, queued: 0),
                                        fraction: monitor.progress.fraction, cancel: { }, details: monitor)
            left.model.progress = status
            right.model.progress = status
            NSApp.activate(ignoringOtherApps: true)
            left.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                capture(to: name)
                left.model.progress = nil
                right.model.progress = nil
                finishScene()
            }
        }
    }

    /// The right-click menu on a spreadsheet.
    private static func contextMenu(named name: String) {
        let area = screen()
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(NSPoint(x: area.minX + 100, y: area.maxY - 500)))
        controller.window?.setContentSize(NSSize(width: 700, height: 440))
        controller.window?.setFrameOrigin(NSPoint(x: area.minX + 100, y: area.maxY - 500))
        controller.model.setLabel(tr("Work"), color: "blue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController,
                  let item = controller.model.items.first(where: { $0.name == demo.name("report") }),
                  let row = vc.rows.firstIndex(of: item) else { finishScene(); return }
            vc.setSelectionForSheetTest([item.url])
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            let menu = NSMenu()
            vc.populate(menu, selection: [item])
            let rect = vc.tableView.rect(ofRow: row)
            popUp(menu, at: NSPoint(x: 250, y: rect.midY), in: vc.tableView, capturing: name)
        }
    }

    /// The lister menu of the title bar.
    private static func titleBarMenu(named name: String) {
        let area = screen()
        let controller = ListerManager.shared.openLister(directory: demo.projects, anchor: .origin(NSPoint(x: area.minX + 100, y: area.maxY - 500)))
        controller.window?.setContentSize(NSSize(width: 700, height: 440))
        controller.window?.setFrameOrigin(NSPoint(x: area.minX + 100, y: area.maxY - 500))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let vc = controller.listerViewController else { finishScene(); return }
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            popUp(vc.makeTitleBarMenu(), at: NSPoint(x: 40, y: 6), in: vc.tableView.enclosingScrollView ?? vc.view, capturing: name)
        }
    }

    private static func transferDetails(named name: String) {
        let monitor = syntheticMonitor(progressFraction: nil)
        let percent = Int((monitor.progress.fraction * 100).rounded())
        let window = show(TransferDetailsView(monitor: monitor, close: { }), title: "\(percent)% — \(tr("Copying"))")
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 640))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            capture(to: name)
            finishScene()
        }
    }

    private static func batchRename(named name: String) {
        var options = BatchRenameOptions()
        options.find = "Q4"
        options.replace = "2026-Q4"
        options.caseMode = .unchanged
        let files = ["budget", "notes", "logo", "contract"].map { demo.project($0) }
        let window = show(BatchRenameView(items: files, initial: options, onApply: { _ in }, close: { }), title: tr("Rename"))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    private static func nameLister(named name: String) {
        let window = show(ListerLabelView(initialName: "NAS", initialColor: "orange", onApply: { _, _ in }, close: { }), title: tr("Name This Lister"))
        window.setFrameOrigin(NSPoint(x: screen().minX + 300, y: screen().maxY - 460))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { capture(to: name); finishScene() }
    }

    private static func connectSheet(named name: String) {
        var profile = ServerProfile()
        profile.scheme = .sftp
        profile.host = "files.example.org"
        profile.user = "demo"
        profile.name = "Web host"
        let window = show(ConnectToServerView(initial: profile, initialSecret: "", onConnect: { _, _, _, _, _ in }, close: { }), title: tr("Connect to Server"))
        window.setFrameOrigin(NSPoint(x: screen().minX + 300, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    private static func shortcuts(named name: String) {
        let window = show(ShortcutsView(), title: tr("Keyboard Shortcuts"), size: NSSize(width: 620, height: 640))
        window.setFrameOrigin(NSPoint(x: screen().minX + 200, y: screen().maxY - 700))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { capture(to: name); finishScene() }
    }

    // MARK: Helpers

    private static func show<V: View>(_ view: V, title: String, size: NSSize? = nil) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if let size { window.setContentSize(size) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Opens a menu, takes the picture while it is open, then closes it. Menu tracking sometimes ends at once
    /// (the app was not yet active); the menu is then opened again, up to four times.
    private static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView, capturing name: String, attempt: Int = 1) {
        var captured = false
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            if NSApp.windows.contains(where: { $0.isVisible && String(describing: type(of: $0)).contains("PopupMenu") }) {
                capture(to: name)
                captured = true
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)         // .common includes the menu-tracking mode
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        menu.popUp(positioning: nil, at: point, in: view)  // returns when the menu has closed
        timer.invalidate()
        if captured {
            finishScene()
        } else if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { popUp(menu, at: point, in: view, capturing: name, attempt: attempt + 1) }
        } else {
            print("the menu for \(name) did not stay open")
            finishScene()
        }
    }

    /// A copy that is 62 % done after 72 s: a ramp-up, a plateau, a dip and a recovery.
    private static func syntheticMonitor(progressFraction: Double?) -> TransferMonitor {
        let start = Date().addingTimeInterval(-72)
        let monitor = TransferMonitor(title: tr("Copying"), from: demo.name("projects"), to: "NAS · " + demo.name("backup"), now: start)
        var progress = TransferProgress(itemsDone: 0, itemsTotal: 3, bytesDone: 0, bytesTotal: 3_900_000_000, current: demo.name("video"))
        var written: Int64 = 0
        for step in 1...144 {
            let t = Double(step) * 0.5
            var rate = 38_000_000.0
            if t < 4 { rate = 38_000_000 * t / 4 }
            if t > 38 && t < 46 { rate = 22_000_000 + 3_000_000 * sin(t) }
            if t > 46 { rate = 33_000_000 + 4_000_000 * sin(t / 3) }
            rate += 2_500_000 * sin(t * 1.7)
            written += Int64(rate * 0.5)
            progress.bytesDone = written
            progress.itemsDone = Int(Double(written) / 1_300_000_000)
            monitor.update(progress, now: start.addingTimeInterval(t))
        }
        return monitor
    }

    // MARK: Capture

    /// A borderless window with a soft gradient, in front of every other application and behind this app's windows.
    private static func makeBackdrop() {
        let frame = screen()
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        let colors: [Color] = dark ? [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.20, green: 0.14, blue: 0.27)]
                                   : [Color(red: 0.80, green: 0.88, blue: 0.97), Color(red: 0.93, green: 0.84, blue: 0.95)]
        window.contentView = NSHostingView(rootView: LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    /// Takes the picture of the area around this app's windows (menus included) from the screen. Only the backdrop and
    /// this app's windows can be in it, so nothing of the user's desktop is.
    private static func capture(to name: String) {
        guard let backdrop, let main = NSScreen.screens.first else { return }
        let region = backdrop.frame
        let mine = NSApp.windows.filter { $0.isVisible && $0 !== backdrop && !($0 is NSPanel && $0.title.isEmpty && $0.frame.height < 40) && !String(describing: type(of: $0)).contains("StatusBar") }
        guard !mine.isEmpty else { print("nothing to capture for \(name)"); return }
        var union = mine[0].frame
        for window in mine.dropFirst() { union = union.union(window.frame) }
        let pad: CGFloat = 70
        let wanted = union.insetBy(dx: -pad, dy: -pad).intersection(region)

        // the whole backdrop, then cut out the part around the windows
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let top = main.frame.maxY - region.maxY                      // Cocoa counts from the bottom, screencapture from the top
        process.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(top)),\(Int(region.width)),\(Int(region.height))", file.path]
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let source = NSImage(contentsOf: file),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("capture failed for \(name)"); return }
        let factor = CGFloat(cg.width) / region.width
        let crop = CGRect(x: (wanted.minX - region.minX) * factor, y: (region.maxY - wanted.maxY) * factor,
                          width: wanted.width * factor, height: wanted.height * factor).integral
        guard let cut = cg.cropping(to: crop) else { return }
        let rep = NSBitmapImageRep(cgImage: cut)
        let url = outDir.appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent) (\(cut.width)×\(cut.height))")
    }
}

// MARK: - Made-up files

/// A folder of invented documents under /Users/Shared, so no real file name ever appears in a picture.
/// Names are in the language the app runs in.
struct DemoFiles {
    let base = URL(fileURLWithPath: "/Users/Shared/MacLister Demo")
    private let polish = AppLanguage.effectiveCode == "pl"

    private var names: [String: String] {
        polish ? [
            "projects": "Projekty", "backup": "Kopia",
            "report": "Raport roczny 2026.pdf", "budget": "Budżet Q4.xlsx", "notes": "Notatki ze spotkania.md", "logo": "Logo finalne.png",
            "video": "Prezentacja produktu.mov", "deck": "Prezentacja.key", "contract": "Umowa (wersja robocza).docx",
            "wireframes": "Makiety.fig", "archive": "Archiwum 2025.zip",
            "f_brand": "Materiały marki", "f_invoices": "Faktury klientów", "f_photos": "Zdjęcia 2026", "f_web": "Nowa strona www",
            "b_index": "indeks-kopii.json", "b_invoices": "Faktury klientów.zip", "b_brand": "Materiały marki.zip", "b_photos": "Zdjęcia",
        ] : [
            "projects": "Projects", "backup": "Backup",
            "report": "Annual Report 2026.pdf", "budget": "Budget Q4.xlsx", "notes": "Meeting Notes.md", "logo": "Logo Final.png",
            "video": "Product Demo.mov", "deck": "Presentation.key", "contract": "Contract Draft.docx",
            "wireframes": "Wireframes.fig", "archive": "Archive 2025.zip",
            "f_brand": "Brand Assets", "f_invoices": "Client Invoices", "f_photos": "Photos 2026", "f_web": "Website Redesign",
            "b_index": "backup-index.json", "b_invoices": "Client Invoices.zip", "b_brand": "Brand Assets.zip", "b_photos": "Photos",
        ]
    }

    func name(_ key: String) -> String { names[key] ?? key }
    var projects: URL { base.appendingPathComponent(name("projects")) }
    var backup: URL { base.appendingPathComponent(name("backup")) }
    func project(_ key: String) -> URL { projects.appendingPathComponent(name(key)) }

    func create() {
        remove()
        let fm = FileManager.default
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        func when(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? now
            let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return min(date, now.addingTimeInterval(-120))
        }
        func file(_ key: String, in folder: URL, bytes: Int64, date: Date) {
            let url = folder.appendingPathComponent(name(key))
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) { try? handle.truncate(atOffset: UInt64(bytes)); try? handle.close() }
            try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
        func folder(_ title: String, in parent: URL, date: Date) {
            let url = parent.appendingPathComponent(title)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try? fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for (key, days) in [("f_brand", 6), ("f_invoices", 2), ("f_photos", 1), ("f_web", 0)] {
            folder(name(key), in: projects, date: when(daysAgo: days, hour: 16, minute: 20))
        }
        file("report", in: projects, bytes: 4_400_000, date: when(daysAgo: 0, hour: 9, minute: 41))
        file("budget", in: projects, bytes: 86_000, date: when(daysAgo: 0, hour: 8, minute: 15))
        file("notes", in: projects, bytes: 4_200, date: when(daysAgo: 1, hour: 17, minute: 5))
        file("logo", in: projects, bytes: 312_000, date: when(daysAgo: 1, hour: 11, minute: 32))
        file("video", in: projects, bytes: 184_000_000, date: when(daysAgo: 2, hour: 14, minute: 48))
        file("deck", in: projects, bytes: 22_000_000, date: when(daysAgo: 3, hour: 10, minute: 12))
        file("contract", in: projects, bytes: 118_000, date: when(daysAgo: 9, hour: 15, minute: 30))
        file("wireframes", in: projects, bytes: 9_600_000, date: when(daysAgo: 14, hour: 13, minute: 0))
        file("archive", in: projects, bytes: 640_000_000, date: when(daysAgo: 40, hour: 9, minute: 0))
        for (title, days) in [("2024", 120), ("2025", 60), ("2026", 0), (name("b_photos"), 8)] {
            folder(title, in: backup, date: when(daysAgo: days, hour: 12, minute: 0))
        }
        file("b_index", in: backup, bytes: 18_000, date: when(daysAgo: 0, hour: 7, minute: 0))
        file("b_invoices", in: backup, bytes: 54_000_000, date: when(daysAgo: 7, hour: 18, minute: 25))
        file("b_brand", in: backup, bytes: 310_000_000, date: when(daysAgo: 12, hour: 10, minute: 40))
        FinderTags.toggle(label: 6, on: [project("report")])
        FinderTags.toggle(label: 4, on: [project("budget")])
    }

    func remove() {
        guard base.lastPathComponent == "MacLister Demo", base.deletingLastPathComponent().path == "/Users/Shared" else { return }
        try? FileManager.default.removeItem(at: base)
    }
}
