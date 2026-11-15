import AppKit

/// `MacLister --selftest`: drives two real listers through roles, Copy and Move using the same
/// code paths as the buttons, writes PASS/FAIL lines to ~/Library/Logs/MacLister.log and quits.
enum SelfTest {
    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("selftest \(condition ? "ok  " : "FAIL") \(message)")
    }

    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("magellan-selftest-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] { try? "x".write(to: src.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        let manager = ListerManager.shared
        let one = manager.openLister(directory: src, anchor: .cursor(NSPoint(x: 300, y: 600), centered: false))
        let two = manager.openLister(directory: dst, anchor: .cursor(NSPoint(x: 1000, y: 600), centered: false))
        guard let vcOne = one.window?.contentViewController as? ListerViewController else {
            check(false, "view controller reachable"); finish(root); return
        }

        // 0. Menu-bar list of listers
        let titles = appDelegate.listerMenuTitles()
        check(titles.count == 2 && titles[0].hasPrefix("src") && titles[1].hasPrefix("dst"), "menu lists both listers in open order: \(titles)")

        let menuTitles = appDelegate.statusMenuTitles()
        check(titles.allSatisfy(menuTitles.contains) && menuTitles.contains("Bring All to Front") && menuTitles.contains("Close All Listers"),
              "status-bar menu shows the listers plus Bring All to Front / Close All: \(menuTitles.prefix(8))")

        check(menuTitles.first == "About MacLister" && menuTitles.contains { $0.hasPrefix("Version ") }, "status-bar menu starts with About and the version: \(menuTitles.prefix(3))")
        check(appDelegate.makeDockMenu().items.map(\.title).contains("About MacLister"), "the Dock menu has About")
        AboutWindow.show()
        check(AboutWindow.isOpen, "the About window opens")
        let aboutDate = AboutInfo.parse("2026-11-14")
        check(aboutDate != nil && AboutInfo.dateText(aboutDate!, language: "en") == "November 14, 2026" && AboutInfo.dateText(aboutDate!, language: "pl") == "14 listopada 2026",
              "release date is shown in the interface language: \(aboutDate.map { AboutInfo.dateText($0, language: "pl") } ?? "nil")")
        check(AboutInfo.parse("soon") == nil && AboutInfo.author == "Grzegorz Murdzek", "the release date must parse; the author is named")
        NSApp.windows.filter { $0.title == "About MacLister" }.forEach { $0.close() }

        // 1. Roles
        manager.toggleRole(.source, for: one)
        manager.toggleRole(.destination, for: two)
        check(one.model.role == .source && two.model.role == .destination, "SRC on first, DST on second")
        let withRoles = appDelegate.listerMenuTitles()
        check(withRoles[0].hasSuffix("[SRC]") && withRoles[1].hasSuffix("[DST]"), "menu entries show the SRC / DST roles: \(withRoles)")
        manager.toggleRole(.destination, for: one)
        check(one.model.role == .destination && two.model.role == .none, "DST moves to first, second loses it")
        manager.toggleRole(.destination, for: one)
        check(one.model.role == .none, "pressing DST again clears it")
        manager.toggleRole(.source, for: one)
        manager.toggleRole(.destination, for: two)
        manager.swapRoles()
        check(one.model.role == .destination && two.model.role == .source, "swap exchanges roles")
        manager.swapRoles()
        check(one.model.role == .source && two.model.role == .destination, "swap back")

        // 2. Copy a.txt from the source lister
        one.model.selectedURLs = [src.appendingPathComponent("a.txt")]
        vcOne.perform(ListerButton(title: "Copy", symbol: nil, action: .copy))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            check(fm.fileExists(atPath: dst.appendingPathComponent("a.txt").path), "copy created a.txt in destination")
            check(fm.fileExists(atPath: src.appendingPathComponent("a.txt").path), "copy kept a.txt in source")
            check(two.model.items.contains { $0.name == "a.txt" }, "destination lister refreshed itself")

            // 3. Move b.txt
            one.model.selectedURLs = [src.appendingPathComponent("b.txt")]
            vcOne.perform(ListerButton(title: "Move", symbol: nil, action: .move))

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                check(fm.fileExists(atPath: dst.appendingPathComponent("b.txt").path), "move created b.txt in destination")
                check(!fm.fileExists(atPath: src.appendingPathComponent("b.txt").path), "move removed b.txt from source")
                check(!one.model.items.contains { $0.name == "b.txt" }, "source lister refreshed itself")

                // 4. Error paths
                manager.toggleRole(.destination, for: two)   // clear DST
                one.model.errorMessage = nil
                one.model.selectedURLs = [src.appendingPathComponent("a.txt")]
                vcOne.perform(ListerButton(title: "Copy", symbol: nil, action: .copy))
                check(one.model.errorMessage?.contains("No destination") == true, "copy without DST reports an error")
                check(fm.fileExists(atPath: src.appendingPathComponent("a.txt").path), "nothing touched on error")

                // 5. Extract: zip next to the archive (no DST set)
                let zip = src.appendingPathComponent("pack.zip")
                let work = root.appendingPathComponent("work")
                try? fm.createDirectory(at: work, withIntermediateDirectories: true)
                try? "inside".write(to: work.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
                let zipper = Process()
                zipper.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                zipper.arguments = ["-qj", zip.path, work.appendingPathComponent("inner.txt").path]
                try? zipper.run(); zipper.waitUntilExit()
                one.model.reload()
                one.model.errorMessage = nil
                one.model.selectedURLs = [zip]
                vcOne.perform(ListerButton(title: "Extract", symbol: nil, action: .extract))

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    check(fm.fileExists(atPath: src.appendingPathComponent("pack/inner.txt").path), "extract unpacked pack.zip into folder 'pack'")
                    check(one.model.items.contains { $0.name == "pack" }, "lister shows the new folder")

                    // 6. Extract into the destination lister
                    manager.toggleRole(.destination, for: two)
                    one.model.selectedURLs = [zip]
                    vcOne.perform(ListerButton(title: "Extract", symbol: nil, action: .extract))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        check(fm.fileExists(atPath: dst.appendingPathComponent("pack/inner.txt").path), "extract goes to the destination lister's folder")
                        check(two.model.items.contains { $0.name == "pack" }, "destination lister shows the extracted folder")

                        one.model.errorMessage = nil
                        one.model.selectedURLs = [src.appendingPathComponent("a.txt")]
                        vcOne.perform(ListerButton(title: "Extract", symbol: nil, action: .extract))
                        check(one.model.errorMessage?.contains("no supported archive") == true, "extract on a non-archive reports an error")

                        // 7. Context menu + rename
                        one.model.reload()
                        guard let zipItem = one.model.items.first(where: { $0.name == "pack.zip" }),
                              let fileItem = one.model.items.first(where: { $0.name == "a.txt" }) else {
                            check(false, "fixtures present for menu test"); finish(root); return
                        }
                        let menu = NSMenu()
                        vcOne.populate(menu, selection: [zipItem])
                        let titles = menu.flatTitles
                        check(["Open", "Quick Look", "Extract", "Rename…", "Reveal in Finder", "Copy Path", "Move to Trash", "New Folder…"].allSatisfy(titles.contains),
                              "archive menu has Open, Quick Look, Extract, Rename, Reveal, Copy Path, Trash, New Folder: \(titles)")
                        check(titles.contains { $0.hasPrefix("Copy to “dst”") } && titles.contains { $0.hasPrefix("Move to “dst”") },
                              "menu offers Copy/Move to the destination lister")
                        vcOne.populate(menu, selection: [fileItem])
                        check(!menu.flatTitles.contains("Extract"), "plain file menu has no Extract")
                        vcOne.populate(menu, selection: [])
                        let background = menu.flatTitles
                        check(background.contains("New Folder…") && !background.contains("Move to Trash") && background.contains("Copy Folder Path"),
                              "empty-area menu has folder commands only")

                        if case .success(let renamed) = vcOne.rename(fileItem, to: "renamed.txt") {
                            check(fm.fileExists(atPath: renamed.path) && !fm.fileExists(atPath: fileItem.url.path), "rename moved a.txt to renamed.txt")
                        } else { check(false, "rename succeeds") }
                        if case .failure = vcOne.rename(zipItem, to: "renamed.txt") { check(true, "rename onto existing name is refused") }
                        else { check(false, "rename onto existing name is refused") }
                        if case .failure = vcOne.rename(zipItem, to: "bad/name") { check(true, "rename with '/' is refused") }
                        else { check(false, "rename with '/' is refused") }
                        // 8. Bring All to Front really beats other apps' windows
                        func frontOwnership() -> [Bool] {
                            let pid = Int(ProcessInfo.processInfo.processIdentifier)
                            let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                            return infos.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
                                        .map { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
                        }
                        one.window?.orderBack(nil)
                        two.window?.orderBack(nil)
                        // The window server applies orderBack asynchronously: give it a moment before measuring.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let before = Array(frontOwnership().prefix(2))
                            manager.bringAllToFront()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                let after = Array(frontOwnership().prefix(2))
                                check(before != [true, true], "precondition: listers were sent behind other windows (before=\(before))")
                                if QuietMode.isOn {
                                    // quiet mode must not cover your windows, which is just what this measures
                                    DebugLog.write("selftest skip Bring All to Front above other apps (not measured with --quiet)")
                                } else {
                                    check(after == [true, true], "Bring All to Front puts both listers above other apps' windows (after=\(after))")
                                }

                            manager.closeAll()
                            check(manager.openCount == 0, "Close All Listers closes every window")
                            check(appDelegate.statusMenuTitles().contains("No open listers"), "menu says 'No open listers' afterwards")
                            finish(root)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func finish(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        DebugLog.write("selftest \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }
}

extension NSMenu {
    /// Titles of all items, submenus included (the self-tests look for commands wherever they live).
    var flatTitles: [String] {
        items.flatMap { item in [item.title] + (item.submenu?.flatTitles ?? []) }
    }
}
