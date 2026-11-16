import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation

/// `MacLister --demo-video <file.mov> [dark]`: plays scripted scenes with made-up files and records them with
/// ScreenCaptureKit for the website video. Only this app's windows are recorded (a gradient window stands in
/// for the desktop), the real pointer is hidden and a drawn one moves instead. Scene boundaries and camera hints
/// go to `<file>.markers.json`, which Tools/demo_video_edit.py reads to cut, zoom and add transitions.
/// Needs Screen Recording access for the process that starts it.
@available(macOS 15.0, *)
@MainActor
enum DemoVideo {
    private static var demo = DemoFiles()
    private static var dark = false
    private static var region = NSRect.zero               // recorded area, Cocoa screen points
    private static var screen: NSScreen?
    private static var backdrop: NSWindow?
    private static var cursor: CursorWindow?
    private static var stream: SCStream?
    private static var recorder: Recorder?
    private static var startTime: CFTimeInterval = 0
    private static var markers: [[String: Any]] = []

    // MARK: Entry

    static func run(out: URL, dark: Bool) {
        self.dark = dark
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-video-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AppSupport.override = support
        SharedPlaces.browsingEnabled = false
        VolumeInfo.hidden = true
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        demo = DemoFiles()
        demo.create()
        addVideoFiles()

        screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 1280, height: 720)
        region = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                        width: size.width, height: size.height)
        makeBackdrop(covering: visible)
        cursor = CursorWindow()
        cursor?.place(at: NSPoint(x: region.maxX + 80, y: region.minY - 80))
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            do {
                try await startRecording(to: out)
                try await play()
                try await stopRecording()
                writeMarkers(next: out)
            } catch {
                print("demo video failed: \(error)")
            }
            finish()
        }
    }

    private static func finish() {
        ListerManager.shared.closeAll()
        backdrop?.close()
        cursor?.close()
        demo.remove()
        if let support = AppSupport.override { try? FileManager.default.removeItem(at: support) }
        AppSupport.override = nil
        NSApp.terminate(nil)
    }

    // MARK: The script

    private static let lister = NSSize(width: 600, height: 440)
    private static var leftOrigin: NSPoint { NSPoint(x: region.minX + 24, y: region.maxY - 134 - lister.height) }
    private static var rightOrigin: NSPoint { NSPoint(x: region.minX + lister.width + 56, y: region.maxY - 112 - lister.height) }
    private static var restPoint: NSPoint { NSPoint(x: region.midX + 40, y: region.minY + 70) }

    private static func play() async throws {
        try await pause(0.3)
        try await sceneDesktop()
        try await sceneCopy()
        try await sceneDrag()
        try await sceneArchive()
        try await sceneTools()
        try await sceneMany()
        try await sceneTabs()
        try await sceneTwoPanel()
        try await sceneTree()
        try await sceneDark()
        try await sceneButtons()
        try await sceneCard()
    }

    /// Scene 1: a double-click on the empty desktop opens a lister right there – twice.
    private static func sceneDesktop() async throws {
        let leftTop = NSPoint(x: region.minX + 24, y: region.maxY - 112)
        let rightTop = NSPoint(x: region.minX + lister.width + 56, y: region.maxY - 134)
        mark("scene", "desktop")
        let caption = Overlay.caption(tr("Double-click the empty desktop"), in: region)
        async let firstReady = prepareLister(demo.projects, topLeft: leftTop, size: lister)
        try await pause(0.3)
        await cursor?.move(to: NSPoint(x: leftTop.x + 4, y: leftTop.y - 4), duration: 0.85)
        await cursor?.doubleClick()
        let first = await firstReady
        async let secondReady = prepareLister(demo.backup, topLeft: rightTop, size: lister)
        await first.show()
        try await pause(0.25)
        await cursor?.move(to: NSPoint(x: rightTop.x + 4, y: rightTop.y - 4), duration: 0.65)
        await cursor?.doubleClick()
        await (await secondReady).show()
        try await pause(0.8)
        caption.dismiss()
        mark("end", "desktop")
        try await pause(0.3)
    }

    /// Scene 2: source and destination, drag-select, F5, then ⌘Z takes it back.
    private static func sceneCopy() async throws {
        let (left, right) = try await openPair(demo.projects, demo.backup)
        mark("scene", "copy")
        let caption = Overlay.caption(tr("Source and destination: F5 copies"), in: region)
        try await pause(0.3)
        if let src = badge("SRC", in: left) {
            await cursor?.move(to: src, duration: 0.55)
            await cursor?.click()
        }
        ListerManager.shared.toggleRole(.source, for: left)
        try await pause(0.25)
        if let dst = badge("DST", in: right) {
            await cursor?.move(to: dst, duration: 0.6)
            await cursor?.click()
        }
        ListerManager.shared.toggleRole(.destination, for: right)
        try await pause(0.25)

        guard let vc = left.listerViewController else { return }
        let indices = [demo.name("video"), demo.name("deck")].compactMap { name in vc.rows.firstIndex { $0.name == name } }
        guard let firstRow = indices.min() else { return }
        let rows = Array(firstRow..<min(firstRow + 3, vc.rows.count))
        let urls = await dragSelect(rows, in: vc)
        try await pause(0.3)

        let key = Overlay.key("F5", label: tr("Copy"), in: region)
        mark("zoom", "progress", focus: statusPoint(of: left, right))
        let copied = try await fakeCopy(urls, from: left, to: right, seconds: 2.4)
        key.dismiss()
        try await pause(0.9)
        mark("zoomEnd", "progress")
        try await pause(0.6)
        let undo = Overlay.key("⌘Z", label: tr("Undo"), in: region)
        try await pause(0.35)
        for url in copied { try? FileManager.default.removeItem(at: url) }
        right.model.reload()
        try await pause(1.0)
        undo.dismiss()
        caption.dismiss()
        mark("end", "copy")
        try await pause(0.2)
    }

    /// Scene 3: photos dragged from one lister into the other.
    private static func sceneDrag() async throws {
        clear()
        let photos = demo.project("f_photos")
        let nasPhotos = demo.backup.appendingPathComponent(demo.name("b_photos"))
        let (left, right) = try await openPair(photos, nasPhotos)
        mark("scene", "drag")
        let caption = Overlay.caption(tr("Drag and drop, also to and from Finder"), in: region)
        try await pause(0.3)
        guard let vc = left.listerViewController, vc.rows.count > 4 else { return }
        let urls = await dragSelect([1, 2, 3], in: vc)
        try await pause(0.2)
        await cursor?.move(to: rowPoint(2, in: vc), duration: 0.25)
        await cursor?.press()
        let ghost = DragGhost(urls: urls, at: cursor?.position ?? .zero)
        let target = NSPoint(x: right.window?.frame.midX ?? region.midX, y: (right.window?.frame.midY ?? region.midY) - 40)
        await cursor?.move(to: target, duration: 0.9) { ghost.follow($0) }
        await cursor?.release()
        ghost.drop()
        let copies = urls.map { nasPhotos.appendingPathComponent($0.lastPathComponent) }
        for (from, to) in zip(urls, copies) { try? FileManager.default.copyItem(at: from, to: to) }
        right.model.reload()
        try await pause(0.25)
        right.window?.makeKeyAndOrderFront(nil)
        right.listerViewController?.setSelectionForSheetTest(copies)
        try await pause(1.5)
        caption.dismiss()
        mark("end", "drag")
        try await pause(0.2)
    }

    /// Scene 4: a ZIP opens like a folder, and so does a folder inside it.
    private static func sceneArchive() async throws {
        clear()
        let size = NSSize(width: 760, height: 470)
        let controller = open(demo.projects, origin: NSPoint(x: region.midX - size.width / 2, y: region.maxY - 116 - size.height), size: size)
        controller.model.setLabel(tr("Work"), color: "blue")
        controller.window?.makeKeyAndOrderFront(nil)
        await cursor?.move(to: restPoint, duration: 0.01)
        try await pause(0.6)
        mark("scene", "archive")
        let caption = Overlay.caption(tr("Open archives like folders"), in: region)
        guard let vc = controller.listerViewController,
              let row = vc.rows.firstIndex(where: { $0.name == demo.name("archive") }) else { return }
        await cursor?.move(to: rowPoint(row, in: vc), duration: 0.7)
        vc.setSelectionForSheetTest([vc.rows[row].url])
        await cursor?.doubleClick()
        vc.open(vc.rows[row])
        try await pause(0.9)
        if let window = controller.window { mark("zoom", "archive", focus: NSPoint(x: window.frame.minX + 300, y: window.frame.maxY - 190)) }
        try await pause(0.8)
        if let folder = vc.rows.firstIndex(where: { $0.isNavigable }) {
            await cursor?.move(to: rowPoint(folder, in: vc), duration: 0.5)
            vc.setSelectionForSheetTest([vc.rows[folder].url])
            await cursor?.doubleClick()
            vc.open(vc.rows[folder])
        }
        try await pause(1.4)
        mark("zoomEnd", "archive")
        try await pause(0.7)
        caption.dismiss()
        mark("end", "archive")
        try await pause(0.2)
    }

    /// Scene 5: Find, Find Duplicates and Synchronize spring up one after the other.
    private static func sceneTools() async throws {
        clear()
        cursor?.orderOut(nil)
        var query = FindQuery(scope: demo.projects)
        query.name = "*.pdf *.key"
        query.withinDays = 30
        let top = region.maxY - 100
        let find = hosted(FindView(initial: query, onFind: { _ in }, close: { }), title: tr("Find"),
                          size: NSSize(width: 470, height: 420), topLeft: NSPoint(x: region.minX + 30, y: top))
        let dupes = hosted(DuplicatesView(initial: DuplicateFinder.Options(scope: demo.base), autoSearch: true, onTrash: { _, _ in }, close: { }),
                           title: tr("Find Duplicates"), size: NSSize(width: 600, height: 500), topLeft: NSPoint(x: region.minX + 330, y: top - 40))
        let sync = hosted(SynchronizeView(source: demo.projects, destination: demo.backup, onRun: { _ in }, close: { }),
                          title: tr("Synchronize"), size: NSSize(width: 560, height: 470), topLeft: NSPoint(x: region.maxX - 590, y: top - 10))
        var prepared: [PreparedWindow] = []
        for window in [find, dupes, sync] { prepared.append(await prepare(window, anchor: nil, settle: 1.2)) }
        mark("scene", "tools")
        let caption = Overlay.caption(tr("Find, find duplicates, synchronize"), in: region)
        try await pause(0.35)
        for item in prepared {
            item.showDetached()
            try await pause(0.55)
        }
        try await pause(1.6)
        caption.dismiss()
        mark("end", "tools")
        try await pause(0.2)
        cursor?.orderFrontRegardless()
    }

    /// Scene 6: six listers, one double-click each.
    private static func sceneMany() async throws {
        clear()
        await cursor?.move(to: restPoint, duration: 0.01)
        let size = NSSize(width: 380, height: 250)
        let spots: [(URL, String?, String?)] = [
            (demo.projects, tr("Work"), "blue"), (demo.backup, "NAS", "orange"), (demo.project("f_photos"), nil, nil),
            (demo.project("f_brand"), nil, "purple"), (demo.base, nil, nil), (demo.project("f_invoices"), nil, "green"),
        ]
        var prepared: [PreparedLister] = []
        for (n, spot) in spots.enumerated() {
            let column = CGFloat(n % 3), row = CGFloat(n / 3)
            let topLeft = NSPoint(x: region.minX + 34 + column * 410 + row * 26, y: region.maxY - 100 - row * 300)
            let item = await prepareLister(spot.0, topLeft: topLeft, size: size)
            if let label = spot.1 ?? spot.2.map({ _ in spot.0.lastPathComponent }) { item.controller.model.setLabel(label, color: spot.2) }
            prepared.append(item)
        }
        mark("scene", "many")
        let caption = Overlay.caption(tr("As many listers as you like"), in: region)
        try await pause(0.25)
        for item in prepared {
            await cursor?.move(to: NSPoint(x: item.anchor.x + 4, y: item.anchor.y - 4), duration: 0.32)
            await cursor?.doubleClick()
            item.showDetached()
            try await pause(0.12)
        }
        try await pause(1.4)
        caption.dismiss()
        mark("end", "many")
        try await pause(0.2)
    }

    /// Scene 7: tabs. ⌘T opens a folder in a new tab of the same lister, a named tab gets a colour, ⌃Tab goes round them.
    private static func sceneTabs() async throws {
        clear()
        await cursor?.move(to: restPoint, duration: 0.01)
        let size = NSSize(width: 860, height: 440)
        let host = open(demo.projects, origin: NSPoint(x: region.midX - size.width / 2, y: region.maxY - 124 - size.height), size: size)
        host.model.setLabel(tr("Work"), color: "blue")
        NSApp.activate(ignoringOtherApps: true)         // after the six listers closed the app was not the active one: a dimmed window
        host.window?.makeKeyAndOrderFront(nil)
        try await pause(0.8)
        mark("scene", "tabs")
        let caption = Overlay.caption(tr("Tabs: many folders in one lister"), in: region)
        try await pause(0.4)
        if let window = host.window { mark("zoom", "tabs", focus: NSPoint(x: window.frame.midX, y: window.frame.maxY - 30)) }

        var key = Overlay.key("⌘T", label: tr("New tab"), in: region)
        try await pause(0.45)
        let photos = ListerManager.shared.newTab(from: host)
        photos?.model.navigate(to: demo.project("f_photos"))
        try await pause(1.0)
        key.dismiss()

        key = Overlay.key("⌘T", label: tr("New tab"), in: region)
        try await pause(0.45)
        let nas = photos.flatMap { ListerManager.shared.openFolder(demo.backup, inNewTabFrom: $0) }
        nas?.model.setLabel("NAS", color: "orange")
        try await pause(1.0)
        key.dismiss()
        mark("zoomEnd", "tabs")

        key = Overlay.key("⌃Tab", label: tr("Next tab"), in: region)
        try await pause(0.45)
        if let nas { ListerManager.shared.selectNeighbourTab(of: nas, forward: true) }
        try await pause(0.9)
        if let photos { ListerManager.shared.selectNeighbourTab(of: photos, forward: false) }
        try await pause(0.4)
        if let nas { ListerManager.shared.select(nas) }
        try await pause(0.9)
        key.dismiss()
        caption.dismiss()
        mark("end", "tabs")
        try await pause(0.2)
    }

    /// The two-panel window: ⌥⌘N, F5 copies to the other pane, Tab moves to it and the roles go along.
    private static func sceneTwoPanel() async throws {
        clear()
        await cursor?.move(to: restPoint, duration: 0.01)
        mark("scene", "twoPanel")
        let caption = Overlay.caption(tr("Two-panel window, like a classic file manager"), in: region)
        try await pause(0.3)
        var key = Overlay.key("⌥⌘N", label: tr("New two-panel window"), in: region)
        try await pause(0.45)
        let size = NSSize(width: 1180, height: 440)
        let dual = ListerManager.shared.openDual(left: demo.projects, right: demo.backup,
                                                 anchor: .origin(NSPoint(x: region.midX - size.width / 2, y: region.maxY - 124 - size.height))) { dual in
            dual.window?.setContentSize(size)
        }
        dual.splitEvenly()
        let left = dual.leftPane, right = dual.rightPane
        left.model.setLabel(tr("Work"), color: "blue")
        right.model.setLabel("NAS", color: "orange")
        NSApp.activate(ignoringOtherApps: true)
        dual.window?.makeKeyAndOrderFront(nil)
        try await pause(0.5)
        NSApp.activate(ignoringOtherApps: true)            // once more: after the scene before, the first one is not always taken
        dual.window?.makeKeyAndOrderFront(nil)
        dual.focus(left)
        try await pause(0.4)
        key.dismiss()

        guard let vc = left.listerViewController else { return }
        // the notes and the file below them (in both languages one that the NAS does not have yet), so the copy shows
        guard let firstRow = vc.rows.firstIndex(where: { $0.name == demo.name("notes") }) else { return }
        let urls = await dragSelect(Array(firstRow..<min(firstRow + 2, vc.rows.count)), in: vc)
        try await pause(0.3)
        key = Overlay.key("F5", label: tr("Copy to the other pane"), in: region)
        if let window = dual.window { mark("zoom", "twoPanel", focus: NSPoint(x: window.frame.midX, y: window.frame.minY + 40)) }
        let copied = try await fakeCopy(urls, from: left, to: right, seconds: 1.6)
        key.dismiss()
        try await pause(0.5)
        mark("zoomEnd", "twoPanel")

        key = Overlay.key("Tab", label: tr("The other pane is the source now"), in: region)
        try await pause(0.4)
        dual.focus(right)
        try await pause(1.3)
        key.dismiss()
        for url in copied { try? FileManager.default.removeItem(at: url) }      // the next scenes start from the same files
        caption.dismiss()
        mark("end", "twoPanel")
        try await pause(0.2)
    }

    /// Scene 8: the folder tree follows the lister.
    private static func sceneTree() async throws {
        clear()
        let size = NSSize(width: 860, height: 480)
        let controller = open(demo.projects, origin: NSPoint(x: region.midX - size.width / 2, y: region.maxY - 112 - size.height), size: size)
        controller.model.setLabel(tr("Work"), color: "blue")
        if let vc = controller.listerViewController {
            vc.treeController.setRoots([demo.base])
            vc.setTree(visible: true, remember: false)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        await cursor?.move(to: restPoint, duration: 0.01)
        try await pause(0.8)
        mark("scene", "tree")
        let caption = Overlay.caption(tr("Folder tree"), in: region)
        guard let vc = controller.listerViewController,
              let row = vc.rows.firstIndex(where: { $0.name == demo.name("f_photos") }) else { return }
        await cursor?.move(to: rowPoint(row, in: vc), duration: 0.7)
        vc.setSelectionForSheetTest([vc.rows[row].url])
        await cursor?.doubleClick()
        vc.open(vc.rows[row])
        try await pause(1.6)
        caption.dismiss()
        mark("end", "tree")
        try await pause(0.2)
    }

    /// Scene 9: the same pair of listers in the dark appearance.
    private static func sceneDark() async throws {
        clear()
        setAppearance(dark: true)
        let (left, right) = try await openPair(demo.projects, demo.backup)
        ListerManager.shared.toggleRole(.source, for: left)
        ListerManager.shared.toggleRole(.destination, for: right)
        try await pause(0.3)
        mark("scene", "dark")
        let caption = Overlay.caption(tr("Light and dark"), in: region)
        guard let vc = left.listerViewController else { return }
        _ = await dragSelect([5, 6, 7], in: vc)
        try await pause(1.4)
        caption.dismiss()
        mark("end", "dark")
        try await pause(0.2)
        clear()
        setAppearance(dark: false)
    }

    /// Scene 10: the button editor beside a lister.
    private static func sceneButtons() async throws {
        let size = NSSize(width: 560, height: 440)
        let controller = open(demo.projects, origin: NSPoint(x: region.minX + 24, y: region.maxY - 130 - size.height), size: size)
        controller.model.setLabel(tr("Work"), color: "blue")
        controller.window?.makeKeyAndOrderFront(nil)
        var buttons = ListerButton.defaults
        if let copy = buttons.firstIndex(where: { $0.action == .copy }) {
            buttons[copy].rightAction = .move
            buttons[copy].middleAction = .compare
        }
        let selected = buttons.firstIndex { $0.action == .copy }
        let editor = hosted(ButtonEditorView(initial: buttons, selection: selected, close: { }), title: tr("Edit Buttons"),
                            size: NSSize(width: 680, height: 470), topLeft: NSPoint(x: region.maxX - 710, y: region.maxY - 150))
        let prepared = await prepare(editor, anchor: nil, settle: 0.6)
        try await pause(0.3)
        mark("scene", "buttons")
        let caption = Overlay.caption(tr("Your own buttons: left, right and middle click"), in: region)
        if let window = controller.window {
            await cursor?.move(to: NSPoint(x: window.frame.minX + 202, y: window.frame.maxY - 66), duration: 0.6)
            await cursor?.click()
        }
        await prepared.show()
        try await pause(1.8)
        caption.dismiss()
        mark("end", "buttons")
        try await pause(0.2)
    }

    /// Scene 11: the end card; it fades back to the bare desktop the video starts with, so a loop is seamless.
    private static func sceneCard() async throws {
        clear()
        cursor?.orderOut(nil)
        try await pause(0.3)
        mark("scene", "card")
        let card = Overlay.endCard(in: region)
        try await pause(2.6)
        card.dismiss()
        try await pause(0.4)
        mark("end", "card")
        try await pause(0.2)
    }

    // MARK: Scene helpers

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Closes everything the previous scene opened (not the backdrop, the pointer or the overlays on their way out).
    private static func clear() {
        ListerManager.shared.closeAll()
        for window in NSApp.windows where window.isVisible && window.level == .normal && window !== backdrop { window.close() }
    }

    private static func setAppearance(dark: Bool) {
        self.dark = dark
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        backdrop?.contentView = NSHostingView(rootView: Wallpaper(dark: dark))
    }

    private static func open(_ folder: URL, origin: NSPoint, size: NSSize) -> ListerWindowController {
        ListerManager.shared.openLister(directory: folder, anchor: .origin(origin)) { $0.window?.setContentSize(size) }
    }

    /// The usual two listers, already named, side by side.
    private static func openPair(_ a: URL, _ b: URL) async throws -> (ListerWindowController, ListerWindowController) {
        clear()
        await cursor?.move(to: restPoint, duration: 0.01)
        let left = open(a, origin: leftOrigin, size: lister)
        let right = open(b, origin: rightOrigin, size: lister)
        left.model.setLabel(tr("Work"), color: "blue")
        right.model.setLabel("NAS", color: "orange")
        left.window?.makeKeyAndOrderFront(nil)
        try await pause(0.55)
        return (left, right)
    }

    /// Presses on the first row and drags down to the last, selecting as it goes; returns the selected files.
    private static func dragSelect(_ rows: [Int], in vc: ListerViewController) async -> [URL] {
        let rows = rows.filter { $0 < vc.rows.count }
        guard let first = rows.first else { return [] }
        vc.tableView.scrollRowToVisible(rows.last ?? first)
        await cursor?.move(to: rowPoint(first, in: vc), duration: 0.55)
        await cursor?.press()
        for n in rows.indices {
            vc.setSelectionForSheetTest(rows[0...n].map { vc.rows[$0].url })
            if n + 1 < rows.count { await cursor?.move(to: rowPoint(rows[n + 1], in: vc), duration: 0.2) }
        }
        await cursor?.release()
        return rows.map { vc.rows[$0].url }
    }

    /// A SwiftUI window like the app's own panels, not shown yet.
    private static func hosted<V: View>(_ view: V, title: String, size: NSSize, topLeft: NSPoint) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
        return window
    }

    /// A window drawn behind the backdrop with its picture taken, ready to spring out of `anchor` (its middle when nil).
    @MainActor
    class PreparedWindow {
        let window: NSWindow
        let image: CGImage?
        let anchor: NSPoint
        init(window: NSWindow, image: CGImage?, anchor: NSPoint) {
            self.window = window; self.image = image; self.anchor = anchor
        }
        /// Lets the picture spring out of the anchor, then swaps in the real window.
        func show() async {
            if let image {
                let pop = PopWindow(image: image, frame: window.frame, anchor: anchor)
                await pop.play()
                window.orderFront(nil)
                window.makeKey()
                try? await Task.sleep(nanoseconds: 30_000_000)
                pop.close()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        }
        /// The same without waiting for the spring to settle, so the next one can start.
        func showDetached() { Task { @MainActor in await show() } }
    }

    final class PreparedLister: PreparedWindow {
        let controller: ListerWindowController
        init(controller: ListerWindowController, image: CGImage?, anchor: NSPoint) {
            self.controller = controller
            super.init(window: controller.window ?? NSWindow(), image: image, anchor: anchor)
        }
    }

    private static func prepare(_ window: NSWindow, anchor: NSPoint?, settle: Double) async -> PreparedWindow {
        await hide(window, settle: settle)
        return PreparedWindow(window: window, image: await snapshot(of: window), anchor: anchor ?? NSPoint(x: window.frame.midX, y: window.frame.midY))
    }

    /// Draws the window where it cannot be seen: invisible first (openLister floats a lister and raises it again
    /// after 0.4 s), then behind the backdrop, where it still draws.
    private static func hide(_ window: NSWindow, settle: Double) async {
        window.alphaValue = 0
        window.orderFront(nil)
        try? await pause(max(settle, 0.45))
        // SwiftUI panels can grow to their ideal size after they are shown: keep them inside the picture
        var frame = window.frame
        if frame.maxX > region.maxX - 20 { frame.origin.x = region.maxX - 20 - frame.width }
        if frame.minY < region.minY + 20 { frame.origin.y = region.minY + 20 }
        if frame != window.frame { window.setFrame(frame, display: true); try? await pause(0.1) }
        window.level = .normal
        if let backdrop { window.order(.below, relativeTo: backdrop.windowNumber) }
        window.alphaValue = 1
        try? await pause(0.05)
    }

    private static func prepareLister(_ folder: URL, topLeft: NSPoint, size: NSSize) async -> PreparedLister {
        let controller = ListerManager.shared.openLister(directory: folder, anchor: .cursor(topLeft, centered: false)) { controller in
            controller.window?.setContentSize(size)
        }
        guard let window = controller.window else { return PreparedLister(controller: controller, image: nil, anchor: topLeft) }
        await hide(window, settle: 0.45)
        return PreparedLister(controller: controller, image: await snapshot(of: window), anchor: topLeft)
    }

    private static func snapshot(of window: NSWindow) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
    }

    /// Screen point of an accessibility element of a lister with this label (the SRC / DST badges).
    private static func badge(_ label: String, in controller: ListerWindowController) -> NSPoint? {
        guard let root = controller.window?.contentView else { return nil }
        func search(_ element: Any, depth: Int) -> NSRect? {
            guard depth < 30, let object = element as? NSAccessibilityProtocol else { return nil }
            let node = element as AnyObject
            let title = (node.accessibilityLabel?() ?? nil) ?? (node.accessibilityTitle?() ?? nil) ?? ""
            if title == label { return object.accessibilityFrame() }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let frame = search(root, depth: 0), frame.width > 0 else { return nil }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private static func rowPoint(_ row: Int, in vc: ListerViewController) -> NSPoint {
        let table = vc.tableView
        let rect = table.convert(table.rect(ofRow: row), to: nil)
        let onScreen = table.window?.convertToScreen(rect) ?? rect
        return NSPoint(x: onScreen.minX + 150, y: onScreen.midY)
    }

    /// The middle between the bottoms of the two listers: where the progress bars are.
    private static func statusPoint(of a: ListerWindowController, _ b: ListerWindowController) -> NSPoint {
        let fa = a.window?.frame ?? region, fb = b.window?.frame ?? region
        return NSPoint(x: (fa.minX + fb.midX) / 2, y: (fa.minY + fb.minY) / 2 + 30)   // all of the source, the names landing in the destination
    }

    /// A progress bar that runs for `seconds`, then the files really appear in the destination.
    private static func fakeCopy(_ items: [URL], from left: ListerWindowController, to right: ListerWindowController, seconds: Double) async throws -> [URL] {
        let sizes = items.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
        let total = max(sizes.reduce(0, +), 1)
        let start = Date()
        let monitor = TransferMonitor(title: tr("Copying"), from: left.model.url.lastPathComponent,
                                      to: "NAS · " + right.model.url.lastPathComponent, now: start)
        let steps = Int(seconds * 30)
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let done = Int64(Double(total) * eased)
            var running: Int64 = 0
            var itemsDone = 0
            var current = items.first?.lastPathComponent ?? ""
            for (url, size) in zip(items, sizes) {
                if running + size <= done { itemsDone += 1; running += size } else { current = url.lastPathComponent; break }
            }
            let progress = TransferProgress(itemsDone: itemsDone, itemsTotal: items.count, bytesDone: done, bytesTotal: total, current: current)
            monitor.update(progress, now: start.addingTimeInterval(Double(step) / 30 * 1.9))   // the speed of a fast NAS, not of a clone
            let status = TransferStatus(text: ListerViewController.progressText(verb: tr("Copying"), progress: progress, speed: monitor.speed, paused: false, queued: 0),
                                        fraction: progress.fraction, cancel: { }, details: monitor)
            left.model.progress = status
            right.model.progress = status
            try await pause(1.0 / 30)
        }
        for url in items { try? FileManager.default.copyItem(at: url, to: right.model.url.appendingPathComponent(url.lastPathComponent)) }
        left.model.progress = nil
        right.model.progress = nil
        let copies = items.map { right.model.url.appendingPathComponent($0.lastPathComponent) }
        right.model.reload()
        try await pause(0.15)
        right.listerViewController?.setSelectionForSheetTest(copies)
        return copies
    }

    // MARK: Markers

    private static func mark(_ kind: String, _ name: String, focus: NSPoint? = nil) {
        var entry: [String: Any] = ["kind": kind, "name": name, "t": CACurrentMediaTime() - startTime]
        if let focus {   // 0…1 within the recorded area, from the top-left
            entry["fx"] = (focus.x - region.minX) / region.width
            entry["fy"] = (region.maxY - focus.y) / region.height
        }
        markers.append(entry)
        print("mark \(kind) \(name) at \(String(format: "%.2f", entry["t"] as? Double ?? 0))")
    }

    private static func writeMarkers(next movie: URL) {
        let url = movie.deletingPathExtension().appendingPathExtension("markers.json")
        let body: [String: Any] = ["width": region.width, "height": region.height, "markers": markers]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) { try? data.write(to: url) }
        print("wrote \(movie.path) and \(url.lastPathComponent)")
    }

    // MARK: Backdrop

    private static func makeBackdrop(covering frame: NSRect) {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.contentView = NSHostingView(rootView: Wallpaper(dark: dark))
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    // MARK: Recording

    private static func startRecording(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw NSError(domain: "DemoVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "no screen"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw NSError(domain: "DemoVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "display not shareable"])
        }
        let mine = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, including: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.sourceRect = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                                   width: region.width, height: region.height)
        config.width = Int(region.width * scale)
        config.height = Int(region.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recorder = Recorder()
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mov
        outputConfig.videoCodecType = .hevc
        let output = SCRecordingOutput(configuration: outputConfig, delegate: recorder)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        await recorder.waitForStart()
        startTime = CACurrentMediaTime()
        self.stream = stream
        self.recorder = recorder
        print("recording \(config.width)×\(config.height) to \(url.path)")
    }

    private static func stopRecording() async throws {
        try await stream?.stopCapture()
        await recorder?.waitForFinish()
    }

    private final class Recorder: NSObject, SCRecordingOutputDelegate {
        private var started: CheckedContinuation<Void, Never>?
        private var finished: CheckedContinuation<Void, Never>?
        private var didStart = false, didFinish = false
        private let lock = NSLock()

        func waitForStart() async {
            await withCheckedContinuation { c in
                lock.lock(); if didStart { lock.unlock(); c.resume() } else { started = c; lock.unlock() }
            }
        }
        func waitForFinish() async {
            await withCheckedContinuation { c in
                lock.lock(); if didFinish { lock.unlock(); c.resume() } else { finished = c; lock.unlock() }
            }
        }
        func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
            lock.lock(); didStart = true; let c = started; started = nil; lock.unlock(); c?.resume()
        }
        func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            lock.lock(); didFinish = true; let c = finished; finished = nil; lock.unlock(); c?.resume()
        }
        func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
            print("recording failed: \(error)")
            lock.lock(); didStart = true; didFinish = true; let a = started, b = finished; started = nil; finished = nil; lock.unlock()
            a?.resume(); b?.resume()
        }
    }
    // MARK: Extra made-up files

    /// Photos for the drag scene and a real ZIP for the archive scene (the screenshot files are empty sparse files).
    private static func addVideoFiles() {
        let fm = FileManager.default
        let polish = AppLanguage.effectiveCode == "pl"
        let photos = demo.project("f_photos")
        for n in 0..<9 {
            let url = photos.appendingPathComponent(String(format: "IMG_%04d.jpg", 2041 + n * 7))
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) { try? handle.truncate(atOffset: UInt64(2_400_000 + n * 310_000)); try? handle.close() }
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(86_400 + n * 3_700))], ofItemAtPath: url.path)
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("maclister-zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let content: [(String, Int)] = polish
            ? [("Faktury/Faktura 01-2025.pdf", 180_000), ("Faktury/Faktura 02-2025.pdf", 176_000), ("Faktury/Faktura 03-2025.pdf", 190_000),
               ("Umowy/Umowa najmu.docx", 64_000), ("Umowy/Umowa serwisowa.docx", 58_000),
               ("Podsumowanie roku.pdf", 2_300_000), ("Plan 2026.xlsx", 92_000), ("Zdjęcie zespołu.jpg", 3_100_000)]
            : [("Invoices/Invoice 01-2025.pdf", 180_000), ("Invoices/Invoice 02-2025.pdf", 176_000), ("Invoices/Invoice 03-2025.pdf", 190_000),
               ("Contracts/Lease.docx", 64_000), ("Contracts/Service Agreement.docx", 58_000),
               ("Year in Review.pdf", 2_300_000), ("Plan 2026.xlsx", 92_000), ("Team Photo.jpg", 3_100_000)]
        for (path, size) in content {
            let url = staging.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 0x20, count: size))
        }
        let archive = demo.project("archive")
        try? fm.removeItem(at: archive)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-r", "-q", "-X", archive.path, "."]
        try? zip.run()
        zip.waitUntilExit()
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: archive.path)
    }
}

// MARK: - Files under the pointer while dragging

@MainActor
private final class DragGhost {
    private let window: NSWindow

    init(urls: [URL], at point: NSPoint) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 110, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.isReleasedWhenClosed = false
        let icon = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        window.contentView = NSHostingView(rootView: GhostView(icon: icon, count: urls.count))
        follow(point)
        window.alphaValue = 0.9
        window.orderFrontRegardless()
    }

    func follow(_ point: NSPoint) { window.setFrameOrigin(NSPoint(x: point.x - 30, y: point.y - 80)) }

    func drop() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in window.close() })
    }
}

private struct GhostView: View {
    let icon: NSImage
    let count: Int
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(0..<min(count, 3), id: \.self) { n in
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                        .offset(x: CGFloat(n) * 5, y: CGFloat(-n) * 5)
                }
            }
            .frame(width: 90, height: 90)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Circle().fill(Color.red))
            }
        }
        .frame(width: 110, height: 100)
    }
}

// MARK: - Animation clock

/// Calls `update` with 0…1 on every display refresh for `duration` seconds.
@MainActor
private func animate(_ duration: Double, _ update: @escaping (Double) -> Void) async {
    let start = CACurrentMediaTime()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            update(t)
            if t >= 1 { timer.invalidate(); done.resume() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

private func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

// MARK: - Drawn pointer

/// A borderless window that carries the arrow pointer (a bit larger than life) and draws click ripples.
@MainActor
private final class CursorWindow: NSWindow {
    private let side: CGFloat = 160
    private let arrow = CALayer()
    private let host = CALayer()
    private(set) var position = NSPoint.zero

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        contentView = view
        host.frame = view.bounds
        view.layer?.addSublayer(host)
        let image = NSCursor.arrow.image
        let hot = NSCursor.arrow.hotSpot                // from the top-left of the image
        let zoom: CGFloat = 1.3
        arrow.contents = image
        arrow.contentsScale = 2
        arrow.bounds = CGRect(x: 0, y: 0, width: image.size.width * zoom, height: image.size.height * zoom)
        arrow.anchorPoint = CGPoint(x: hot.x / image.size.width, y: 1 - hot.y / image.size.height)
        arrow.position = CGPoint(x: side / 2, y: side / 2)
        arrow.shadowOpacity = 0.25
        arrow.shadowRadius = 3
        arrow.shadowOffset = CGSize(width: 0, height: -2)
        host.addSublayer(arrow)
        orderFrontRegardless()
    }

    func place(at point: NSPoint) {
        position = point
        setFrameOrigin(NSPoint(x: point.x - side / 2, y: point.y - side / 2))
    }

    /// Moves along a slight arc with ease-in-out, like a hand would.
    func move(to target: NSPoint, duration: Double, follow: ((NSPoint) -> Void)? = nil) async {
        let from = position
        let dx = target.x - from.x, dy = target.y - from.y
        let length = max(1, hypot(dx, dy))
        let bend = min(80, length * 0.12)
        let control = NSPoint(x: (from.x + target.x) / 2 - dy / length * bend, y: (from.y + target.y) / 2 + dx / length * bend)
        await animate(duration) { [weak self] t in
            let e = easeInOut(t), u = 1 - e
            let point = NSPoint(x: u * u * from.x + 2 * u * e * control.x + e * e * target.x,
                                y: u * u * from.y + 2 * u * e * control.y + e * e * target.y)
            self?.place(at: point)
            follow?(point)
        }
    }

    func press() async {
        ripple()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        arrow.transform = CATransform3DMakeScale(0.82, 0.82, 1)
        CATransaction.commit()
        try? await Task.sleep(nanoseconds: 90_000_000)
    }

    func release() async {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        arrow.transform = CATransform3DIdentity
        CATransaction.commit()
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    func click() async { await press(); await release() }

    func doubleClick() async {
        await click()
        try? await Task.sleep(nanoseconds: 40_000_000)
        await click()
    }

    private func ripple() {
        let ring = CAShapeLayer()
        let r: CGFloat = 26
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = CGPoint(x: side / 2, y: side / 2)
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        ring.strokeColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2.5
        host.insertSublayer(ring, below: arrow)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.25
        scale.toValue = 1.25
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
    }
}

// MARK: - A lister springing out of the click

@MainActor
final class PopWindow: NSWindow {
    private let picture = CALayer()
    private let margin: CGFloat = 80

    init(image: CGImage, frame: NSRect, anchor: NSPoint) {
        let outer = frame.insetBy(dx: -80, dy: -80)
        super.init(contentRect: outer, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: outer.size))
        view.wantsLayer = true
        contentView = view
        picture.contents = image
        picture.contentsScale = 2
        picture.cornerRadius = 10
        picture.masksToBounds = false
        picture.shadowOpacity = 0.35
        picture.shadowRadius = 22
        picture.shadowOffset = CGSize(width: 0, height: -10)
        let inner = CGRect(x: margin, y: margin, width: frame.width, height: frame.height)
        let ax = (anchor.x - frame.minX) / frame.width, ay = (anchor.y - frame.minY) / frame.height
        picture.anchorPoint = CGPoint(x: ax, y: ay)
        picture.bounds = CGRect(origin: .zero, size: inner.size)
        picture.position = CGPoint(x: inner.minX + ax * inner.width, y: inner.minY + ay * inner.height)
        picture.transform = CATransform3DMakeScale(0.04, 0.04, 1)
        picture.opacity = 0
        view.layer?.addSublayer(picture)
        orderFrontRegardless()
    }

    func play() async {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.04
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 210
        spring.damping = 17
        spring.initialVelocity = 2
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        picture.transform = CATransform3DIdentity
        picture.opacity = 1
        picture.add(spring, forKey: "pop")
        picture.add(fade, forKey: "fade")
        try? await Task.sleep(nanoseconds: UInt64(min(spring.settlingDuration, 0.75) * 1_000_000_000))
    }
}

// MARK: - Captions, key badges, end card

@MainActor
private final class Overlay {
    private let window: NSWindow

    private init<V: View>(_ view: V, frame: NSRect) {
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = host
        window.orderFrontRegardless()
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in window.close() })
    }

    static func caption(_ text: String, in region: NSRect) -> Overlay {
        Overlay(CaptionView(text: text), frame: NSRect(x: region.minX, y: region.maxY - 84, width: region.width, height: 84))
    }

    static func key(_ key: String, label: String, in region: NSRect) -> Overlay {
        Overlay(KeyView(key: key, label: label), frame: NSRect(x: region.midX - 200, y: region.minY + 20, width: 400, height: 110))
    }

    static func endCard(in region: NSRect) -> Overlay {
        Overlay(EndCardView(), frame: region)
    }
}

private struct CaptionView: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .offset(y: shown ? 0 : -24)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { shown = true } }
    }
}

private struct KeyView: View {
    let key: String
    let label: String
    @State private var shown = false
    var body: some View {
        HStack(spacing: 16) {
            Text(key)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundColor(.black.opacity(0.85))
                .frame(minWidth: 64)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 0, y: 4))
            Text(label)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.7)))
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { shown = true } }
    }
}

private struct EndCardView: View {
    @State private var icon = false
    @State private var text = false
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 190, height: 190)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                .scaleEffect(icon ? 1 : 0.2)
                .rotationEffect(.degrees(icon ? 0 : -25))
                .opacity(icon ? 1 : 0)
            Text(verbatim: "MacLister")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            Text(tr("Free file manager for macOS") + "  ·  maclister.github.io")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
        }
        .offset(y: text ? 0 : 30)
        .opacity(text ? 1 : 0.0001)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { icon = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.18)) { text = true }
        }
    }
}

/// The "desktop": a saturated gradient with a few soft blobs of colour.
private struct Wallpaper: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.07, green: 0.09, blue: 0.22), Color(red: 0.22, green: 0.08, blue: 0.30)]
                                        : [Color(red: 0.16, green: 0.42, blue: 0.95), Color(red: 0.62, green: 0.30, blue: 0.90)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle().fill(Color(red: 1.0, green: 0.55, blue: 0.45).opacity(dark ? 0.25 : 0.55))
                    .frame(width: w * 0.55).position(x: w * 0.82, y: h * 0.85).blur(radius: 120)
                Circle().fill(Color(red: 0.30, green: 0.85, blue: 0.95).opacity(dark ? 0.2 : 0.45))
                    .frame(width: w * 0.5).position(x: w * 0.12, y: h * 0.15).blur(radius: 120)
                Circle().fill(Color(red: 0.95, green: 0.40, blue: 0.75).opacity(dark ? 0.2 : 0.35))
                    .frame(width: w * 0.35).position(x: w * 0.45, y: h * 0.55).blur(radius: 110)
            }
        }
        .ignoresSafeArea()
    }
}
