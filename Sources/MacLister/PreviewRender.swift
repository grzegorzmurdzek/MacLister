import AppKit
import SwiftUI

/// `MacLister --render-details out.png [dark]`: draws the transfer-details window with made-up data
/// (a download that started 72 s ago) into a PNG. A development aid for looking at the design without
/// starting a real copy.
enum PreviewRender {
    @MainActor
    static func transferDetails(to url: URL, dark: Bool) {
        let start = Date().addingTimeInterval(-72)
        let monitor = TransferMonitor(title: tr("Copying"), from: "Downloads", to: "NAS Backup", now: start)
        var progress = TransferProgress(itemsDone: 0, itemsTotal: 6, bytesDone: 0, bytesTotal: 6_700_000_000, current: "Win11_23H2_English_x64.iso")
        var written: Int64 = 0
        // 72 seconds of speed: a ramp-up, a plateau near 38 MB/s, a dip, and a recovery
        for step in 1...144 {
            let t = Double(step) * 0.5
            var rate = 38_000_000.0
            if t < 4 { rate = 38_000_000 * t / 4 }
            if t > 38 && t < 46 { rate = 22_000_000 + 3_000_000 * sin(t) }
            if t > 46 { rate = 33_000_000 + 4_000_000 * sin(t / 3) }
            rate += 2_500_000 * sin(t * 1.7)
            written += Int64(rate * 0.5)
            progress.bytesDone = written
            progress.itemsDone = Int(Double(written) / 1_200_000_000)
            monitor.update(progress, now: start.addingTimeInterval(t))
        }
        let size = NSSize(width: 500, height: 560)
        let host = NSHostingView(rootView: TransferDetailsView(monitor: monitor, close: { }))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.title = tr("Copying")
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.fittingSize)
        window.orderFrontRegardless()
        // give SwiftUI (and the chart) a moment to draw
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        guard let content = window.contentView?.superview ?? window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { print("render failed"); return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }

    /// `MacLister --render-buttons out.png width [page]`: the button bar at that width (page of buttons) into a PNG.
    @MainActor
    static func buttonBar(to url: URL, width: CGFloat, page: Int) {
        let model = ListerModel(url: FileManager.default.homeDirectoryForCurrentUser)
        let host = NSHostingView(rootView: ButtonBarView(model: model, store: .shared, startPage: page, onAction: { _ in }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: width, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
        window.close()
    }

    /// A lister with a name and colour, drawn from made-up files in a temporary folder.
    @MainActor
    static func lister(to url: URL, label: String, color: String, dark: Bool) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("maclister-preview-\(UUID().uuidString)/Backup")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, size) in [("Photos 2026.zip", 48_000_000), ("report.pdf", 1_200_000), ("notes.txt", 4_000), ("invoice.xlsx", 86_000)] {
            try? Data(count: size).write(to: folder.appendingPathComponent(name))
        }
        try? fm.createDirectory(at: folder.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let controller = ListerManager.shared.openLister(directory: folder, anchor: .origin(NSPoint(x: 80, y: 80)))
        controller.model.setLabel(label, color: color)
        controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.window?.setContentSize(NSSize(width: 640, height: 300))
        ListerManager.shared.toggleRole(.destination, for: controller)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        if let content = controller.window?.contentView?.superview, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
        ListerManager.shared.closeAll()
        try? fm.removeItem(at: folder.deletingLastPathComponent())
    }

    /// Real Recents from Spotlight: prints how many files came back and whether they are newest first.
    @MainActor
    static func recentsCheck() {
        let controller = ListerManager.shared.openLister(directory: FileManager.default.homeDirectoryForCurrentUser, anchor: .origin(NSPoint(x: 80, y: 80)))
        controller.model.navigate(to: VirtualPlace.recents.url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let dates = controller.model.items.compactMap(\.modified)
            let sorted = zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }
            let oldest = dates.last.map { Int(Date().timeIntervalSince($0) / 86_400) } ?? -1
            print("recents: \(controller.model.items.count) files, newest first: \(sorted), oldest \(oldest) days ago, all real files: \(controller.model.items.allSatisfy { $0.url.isFileURL }), Where column: \(controller.listerViewController?.tableView.tableColumns.contains { $0.identifier.rawValue == "folder" } ?? false)")
            ListerManager.shared.closeAll()
            NSApp.terminate(nil)
        }
    }
}
