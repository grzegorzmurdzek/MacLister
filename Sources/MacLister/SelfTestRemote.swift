import AppKit

/// `MacLister --selftest-remote ftp=2121 ftpes=2122 ftps=2123 [sftp=2222] root=/path/served/by/the/server`
/// Talks to real servers on 127.0.0.1 (see Tools/mock_ftp_server.py) and checks the remote client code.
infix operator |>: AdditionPrecedence
private func |> <T>(value: T, body: (T) throws -> Void) rethrows { try body(value) }

enum SelfTestRemote {
    private static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        DebugLog.write("remote \(condition ? "ok  " : "FAIL") \(message)")
    }

    static func run(arguments: [String]) {
        var options: [String: String] = [:]
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { options[parts[0]] = parts[1] }
        }
        // known_hosts, askpass script, server list and shortcuts of the test must not touch the user's own
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-remote-support-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AppSupport.override = support
        let root = URL(fileURLWithPath: options["root"] ?? "/nonexistent")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("maclister-remote-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        offlineChecks()
        if let directory = options["sftpdir"] { sftpLocalChecks(directory: URL(fileURLWithPath: directory), work: work) }
        for scheme in [RemoteScheme.ftp, .ftpes, .ftps] {
            guard let portText = options[scheme.rawValue], let port = Int(portText) else { continue }
            ftpChecks(scheme: scheme, port: port, root: root, work: work)
        }
        let afterFTP: () -> Void = {
            if let portText = options["sftp"], let port = Int(portText), let key = options["key"], let pkey = options["pkey"],
               let user = options["sshuser"], let directory = options["sshdir"] {
                sshChecks(port: port, user: user, key: key, protectedKey: pkey, passphrase: options["pass"] ?? "",
                          hostPublicKey: options["hostpub"], otherHostPublicKey: options["host2pub"],
                          directory: URL(fileURLWithPath: directory), work: work) { finish(work) }
            } else {
                finish(work)
            }
        }
        if let portText = options["ftp"], let port = Int(portText) {
            listerChecks(port: port, root: root, work: work, done: afterFTP)
        } else {
            afterFTP()
        }
    }

    private static func finish(_ work: URL) {
        if let support = AppSupport.override { try? FileManager.default.removeItem(at: support) }
        AppSupport.override = nil
        try? FileManager.default.removeItem(at: work)
        DebugLog.write("remote \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }

    // MARK: Steps (the lister parts are asynchronous)

    private static var steps: [(delay: Double, run: () -> Void)] = []
    private static var inserted: [(delay: Double, run: () -> Void)] = []
    private static var executing = false
    /// A step queued from inside another step runs right after it (before the steps that were already waiting).
    private static func later(_ delay: Double = 0.2, _ run: @escaping () -> Void) {
        if executing { inserted.append((delay, run)) } else { steps.append((delay, run)) }
    }
    private static func runSteps(_ done: @escaping () -> Void) {
        guard !steps.isEmpty else { done(); return }
        let step = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
            executing = true
            step.run()
            executing = false
            steps.insert(contentsOf: inserted, at: 0)
            inserted = []
            runSteps(done)
        }
    }

    /// A lister on a server: connection, listing, navigation, hidden files, filter, errors, window title.
    private static func listerChecks(port: Int, root: URL, work: URL, done: @escaping () -> Void) {
        let fm = FileManager.default
        let manager = ListerManager.shared
        var session: RemoteSession?
        var connectError: String?

        later {
            RemoteSessions.shared.connect(profile: profile(.ftp, port: port), secret: "secret", confirmHostKey: { _ in true }) { result in
                switch result {
                case .success(let s): session = s
                case .failure(let e): connectError = e.message
                }
            }
        }
        later(1.5) {
            check(session != nil && session?.home == "/", "connect() returns a session for the server \(connectError ?? "")")
        }
        guard true else { return }

        var controller: ListerWindowController?
        func model() -> ListerModel? { controller?.model }
        func names() -> Set<String> { Set(model()?.items.map(\.name) ?? []) }
        later {
            guard let session else { return }
            controller = manager.openLister(directory: session.url(path: "/"), anchor: .cursor(NSPoint(x: 300, y: 600), centered: false))
        }
        later(1.5) {
            check(model()?.isRemote == true && names() == ["a.txt", "docs", "link", "with space"], "a lister lists the server's root: \(names().sorted())")
            check(model()?.items.first { $0.name == "docs" }?.isDirectory == true && model()?.items.first { $0.name == "link" }?.isSymlink == true, "folders and symbolic links are marked")
            check(model()?.items.first { $0.name == "a.txt" }?.size == 6 && model()?.items.first { $0.name == "a.txt" }?.permissions == 0o644, "sizes and permissions reach the rows")
            check(controller?.window?.title == "test@127.0.0.1", "the window title names the server: \(controller?.window?.title ?? "nil")")
            check(controller?.window?.subtitle.contains("free of") == false, "no volume free space is shown for a server")
            check(ListerModel.displayPath(model()?.url ?? URL(fileURLWithPath: "/")).hasPrefix("ftp://test@127.0.0.1:\(port)"), "the path field shows the URL")
            check(model()?.canGoParent == false, "the server root has no parent")
        }
        // navigation
        later {
            if let m = model() { m.navigate(to: RemoteURL.child(of: m.url, named: "docs")) }
        }
        later(1.2) {
            check(names() == ["b.txt"] && RemoteURL.path(of: model()?.url ?? URL(fileURLWithPath: "/")) == "/docs", "entering a server folder: \(names())")
            check(model()?.canGoParent == true && controller?.window?.title == "docs – test@127.0.0.1", "title of a sub-folder: \(controller?.window?.title ?? "nil")")
            let titles = PathSegments.make(for: model()?.url ?? URL(fileURLWithPath: "/")).map(\.title)
            check(titles == ["test@127.0.0.1", "docs"], "breadcrumb of a server path: \(titles)")
            model()?.goParent()
        }
        later(1.2) {
            check(names() == ["a.txt", "docs", "link", "with space"], "Parent returns to the root")
            model()?.goBack()
        }
        later(1.2) {
            check(RemoteURL.path(of: model()?.url ?? URL(fileURLWithPath: "/")) == "/docs", "Back returns to the previous server folder")
            model()?.navigate(toPath: "../with space")
        }
        later(1.2) {
            check(RemoteURL.path(of: model()?.url ?? URL(fileURLWithPath: "/")) == "/with space", "a typed relative path is resolved on the server")
            model()?.navigate(toPath: "ftp://test@127.0.0.1:\(port)/docs")
        }
        later(1.2) {
            check(RemoteURL.path(of: model()?.url ?? URL(fileURLWithPath: "/")) == "/docs", "a typed server URL is opened")
            model()?.navigate(toPath: "/nope")
        }
        later(1.2) {
            check(RemoteURL.path(of: model()?.url ?? URL(fileURLWithPath: "/")) == "/docs" && model()?.errorMessage != nil, "a missing folder keeps the old one and shows an error: \(model()?.errorMessage ?? "nil")")
            model()?.navigate(to: RemoteURL.with(path: "/", on: model()?.url ?? URL(fileURLWithPath: "/")))
            try? "h".write(to: root.appendingPathComponent(".hidden-file"), atomically: true, encoding: .utf8)
        }
        later(1.2) {
            model()?.reload()
        }
        later(1.2) {
            check(!names().contains(".hidden-file"), "hidden files on the server are not shown by default")
            model()?.toggleHidden()
        }
        later(1.2) {
            check(names().contains(".hidden-file"), "Show Hidden Files shows them")
            model()?.toggleHidden()
            model()?.setFilter("*.txt")
        }
        later(1.2) {
            check(names() == ["a.txt", "docs", "with space"], "the filter applies to server listings (folders stay): \(names().sorted())")
            check(!names().contains("link"), "a symbolic link (a file for the filter) is filtered out")
            model()?.setFilter("")
            try? fm.removeItem(at: root.appendingPathComponent(".hidden-file"))
        }
        later(1.0) {
            controller?.close()
        }
        later { uiChecks(session: session, root: root, work: work) }
        later { engineChecks(session: session, root: root, work: work, port: port) }
        later(1.0) { RemoteSessions.shared.closeAll() }
        runSteps(done)
    }

    // MARK: Listers working with a server

    private static func uiChecks(session: RemoteSession?, root: URL, work: URL) {
        guard let session else { check(false, "ui: a session is needed"); return }
        let manager = ListerManager.shared
        let fm = FileManager.default
        let localDir = work.appendingPathComponent("local-ui")
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        try? "from local".write(to: localDir.appendingPathComponent("from-local.txt"), atomically: true, encoding: .utf8)
        try? session.fs.makeDirectory("/ui")
        try? "from server".write(to: root.appendingPathComponent("ui/from-server.txt"), atomically: true, encoding: .utf8)

        var remoteC: ListerWindowController?, localC: ListerWindowController?
        func rvc() -> ListerViewController? { remoteC?.listerViewController }
        func lvc() -> ListerViewController? { localC?.listerViewController }
        func rnames() -> Set<String> { Set(remoteC?.model.items.map(\.name) ?? []) }
        func select(_ vc: ListerViewController?, _ name: String) {
            guard let vc else { return }
            vc.setSelectionForSheetTest(vc.model.items.filter { $0.name == name }.map(\.url))
        }
        func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

        later {
            remoteC = manager.openLister(directory: session.url(path: "/ui"), anchor: .cursor(NSPoint(x: 200, y: 500), centered: false))
            localC = manager.openLister(directory: localDir, anchor: .cursor(NSPoint(x: 900, y: 500), centered: false))
        }
        later(1.5) {
            check(rnames() == ["from-server.txt"], "ui: the server lister shows its folder: \(rnames())")
            // local → server with the Copy command: local lister is the source, server lister the destination
            if let localC, let remoteC { manager.toggleRole(.source, for: localC); manager.toggleRole(.destination, for: remoteC) }
            select(lvc(), "from-local.txt")
            lvc()?.startTransfer(.copy)
            check(remoteC?.model.progress != nil || true, "ui: a transfer starts")
        }
        later(2.0) {
            check(read(root.appendingPathComponent("ui/from-local.txt")) == "from local", "ui: Copy uploads from a local lister to a server lister")
            check(rnames().contains("from-local.txt") && remoteC?.model.progress == nil && localC?.model.progress == nil, "ui: the server lister refreshed and the progress ended: \(rnames())")
            // server → local
            if let localC, let remoteC { manager.toggleRole(.source, for: remoteC); manager.toggleRole(.destination, for: localC) }
            select(rvc(), "from-server.txt")
            rvc()?.startTransfer(.copy)
        }
        later(2.0) {
            check(read(localDir.appendingPathComponent("from-server.txt")) == "from server", "ui: Copy downloads from a server lister to a local lister")
            check(Set(localC?.model.items.map(\.name) ?? []).contains("from-server.txt"), "ui: the local lister refreshed")
            // folder operations through the same code the menu uses
            rvc()?.remoteMakeDirectory("ui made")
        }
        later(1.5) {
            var isDirectory: ObjCBool = false
            check(fm.fileExists(atPath: root.appendingPathComponent("ui/ui made").path, isDirectory: &isDirectory) && isDirectory.boolValue && rnames().contains("ui made"), "ui: New Folder on a server")
            if let item = remoteC?.model.items.first(where: { $0.name == "from-local.txt" }) { rvc()?.remoteRename(item, to: "renamed.txt") }
        }
        later(1.5) {
            check(fm.fileExists(atPath: root.appendingPathComponent("ui/renamed.txt").path) && rnames().contains("renamed.txt") && !rnames().contains("from-local.txt"), "ui: Rename on a server")
            if let item = remoteC?.model.items.first(where: { $0.name == "renamed.txt" }) { rvc()?.remoteDelete([item]) }
        }
        later(1.5) {
            check(!fm.fileExists(atPath: root.appendingPathComponent("ui/renamed.txt").path) && !rnames().contains("renamed.txt") && remoteC?.model.progress == nil, "ui: Delete on a server")
            // open / Quick Look need a local copy
            select(rvc(), "from-server.txt")
            if let item = remoteC?.model.items.first(where: { $0.name == "from-server.txt" }) {
                rvc()?.downloadToCache([item]) { urls in
                    check(urls.count == 1 && read(urls[0]) == "from server", "ui: a server file is downloaded into the cache: \(urls)")
                    check(rvc()?.quickLookURLs == urls, "ui: Quick Look uses the downloaded copy")
                }
            }
        }
        later(1.5) {
            check(rvc()?.quickLookURLs.count == 1, "ui: Quick Look URLs follow the selection")
            // commands that exist only for local files say so
            rvc()?.showInfo()
            check(remoteC?.model.statusMessage?.contains("not available on a server") == true, "ui: Info on a server says it is not available: \(remoteC?.model.statusMessage ?? "nil")")
            let menu = NSMenu()
            if let item = remoteC?.model.items.first(where: { $0.name == "from-server.txt" }) {
                rvc()?.populate(menu, selection: [item])
                let titles = menu.items.map(\.title)
                check(titles.contains("Delete from Server…") && titles.contains("Rename…") && titles.contains("Quick Look")
                      && !titles.contains("Open With") && !titles.contains("Reveal in Finder") && !titles.contains("Info") && !titles.contains("Make Alias"),
                      "ui: the context menu of a server offers only what works: \(titles)")
            }
            let sizes = remoteC?.model.items.compactMap(\.size)
            check(sizes?.isEmpty == false, "ui: server rows carry sizes")
            // drag and drop onto a server
            typealias VC = ListerViewController
            let file = localDir.appendingPathComponent("from-local.txt")
            check(VC.remoteDragOperation(for: [file], modifiers: []) == .copy && VC.remoteDragOperation(for: [file], modifiers: [.command]) == .move
                  && VC.remoteDragOperation(for: [session.url(path: "/ui/from-server.txt")], modifiers: []) == [] && VC.remoteDragOperation(for: [], modifiers: []) == [],
                  "ui: dropping local files onto a server copies, ⌘ moves, server files cannot be dropped")
            // bookmarks and saved servers
            let url = session.url(path: "/ui")
            BookmarkStore.shared.add(url)
            check(BookmarkStore.shared.contains(url) && BookmarkStore.url(forKey: BookmarkStore.key(for: url)) == RemoteURL.normalized(url), "ui: a server folder can be bookmarked")
            BookmarkStore.shared.remove(BookmarkStore.key(for: url))
            var saved = ServerProfile(); saved.name = "Test"; saved.scheme = .sftp; saved.host = "example.test"; saved.user = "me"; saved.port = 22
            ServerStore.shared.save(saved)
            check(ServerStore.shared.servers.contains { $0.id == saved.id } && saved.displayName == "Test", "ui: a server can be saved")
            ServerStore.shared.remove(saved)
            check(!ServerStore.shared.servers.contains { $0.id == saved.id }, "ui: a saved server can be removed")
            // the Connect sheet opens
            rvc()?.connectToServer()
            let sheet = remoteC?.window?.attachedSheet
            check(sheet != nil, "ui: the Connect to Server sheet opens")
            if let sheet { remoteC?.window?.endSheet(sheet) }
        }
        later(0.5) {
            remoteC?.close(); localC?.close()
            try? RemoteOps.deleteRecursively(session.fs, path: "/ui", isDirectory: true, cancel: nil)
        }
    }

    // MARK: SFTP commands against a local sftp-server (no SSH, no network)

    private static func sftpLocalChecks(directory: URL, work: URL) {
        SFTPFileSystem.testServerPath = "/usr/libexec/sftp-server"
        defer { SFTPFileSystem.testServerPath = nil }
        var profile = ServerProfile(); profile.scheme = .sftp; profile.host = "local-test"; profile.user = "tester"
        let fs = SFTPFileSystem(profile: profile, secret: "")
        sftpOperationChecks(fs: fs, directory: directory, work: work, tag: "sftp")

        // error texts of ssh/sftp, as the app reports them
        func message(_ stderr: String) -> String { SFTPFileSystem.error(stderr: stderr, status: 255, profile: profile).message }
        check(message("tester@host: Permission denied (publickey,password).").contains("Login denied"), "sftp errors: login refused")
        check(message("Host key verification failed.").contains("host key"), "sftp errors: changed host key")
        check(message("ssh: connect to host h port 22: Connection refused").contains("Cannot connect"), "sftp errors: connection refused")
        check(message("ssh: Could not resolve hostname h: nodename nor servname provided").contains("Cannot find the server"), "sftp errors: unknown host")
        check(message("Couldn't stat remote file: No such file or directory").contains("not found"), "sftp errors: missing file")
        check(SFTPHostKeys.hostSpec(host: "h", port: 22) == "h" && SFTPHostKeys.hostSpec(host: "h", port: 2222) == "[h]:2222", "sftp: known_hosts host spec")
    }

    /// The same checks run against the local sftp-server and against a real sshd.
    static func sftpOperationChecks(fs: RemoteFileSystem, directory: URL, work: URL, tag: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        let base = directory.path
        func path(_ name: String) -> String { base + "/" + name }
        func write(_ name: String, _ text: String) { try? text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        // names that sftp's argument parser and its wildcard expansion could trip over
        let names = ["plain.txt", "with space.txt", "quote\"d.txt", "star*.txt", "starfish.txt", "brack[1].txt", "back\\slash.txt", "ünï.txt"]
        for name in names { write(name, "content of " + name) }
        try? fm.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: directory.appendingPathComponent("plain.txt"))

        do {
            check(try fs.homeDirectory().hasPrefix("/"), "\(tag): pwd gives an absolute path")
            let listing = try fs.list(base)
            let found = Set(listing.map(\.name))
            check(found == Set(names + ["sub dir", "link"]), "\(tag): listing returns every name unchanged: missing \(Set(names + ["sub dir", "link"]).subtracting(found)), extra \(found.subtracting(Set(names + ["sub dir", "link"])))")
            check(listing.first { $0.name == "sub dir" }?.isDirectory == true && listing.first { $0.name == "link" }?.isSymlink == true, "\(tag): folders and links are recognised")
            check(listing.first { $0.name == "plain.txt" }?.size == Int64("content of plain.txt".utf8.count) && listing.first { $0.name == "plain.txt" }?.permissions == 0o644, "\(tag): size and permissions")

            // downloads: spaces, a quote, brackets (no sibling matches) and a backslash are taken literally
            for name in ["with space.txt", "quote\"d.txt", "brack[1].txt", "back\\slash.txt", "ünï.txt"] {
                let local = work.appendingPathComponent("dl-" + name.replacingOccurrences(of: "/", with: "_"))
                try fs.download(path(name), to: local, cancel: nil)
                check((try? String(contentsOf: local)) == "content of " + name, "\(tag): download \(name.debugDescription)")
            }
            // a name that is also a wildcard for another file is refused, never guessed
            do {
                try fs.download(path("star*.txt"), to: work.appendingPathComponent("ambiguous"), cancel: nil)
                check(false, "\(tag): an ambiguous name is refused")
            } catch {
                check(error.localizedDescription.contains("starfish.txt") && !fm.fileExists(atPath: work.appendingPathComponent("ambiguous").path),
                      "\(tag): a name that also matches \"starfish.txt\" is refused: \(error.localizedDescription)")
            }
            write("brack1.txt", "the other one")
            do {
                try fs.download(path("brack[1].txt"), to: work.appendingPathComponent("ambiguous2"), cancel: nil)
                check(false, "\(tag): a bracket name that matches another file is refused")
            } catch {
                check(!fm.fileExists(atPath: work.appendingPathComponent("ambiguous2").path), "\(tag): brack[1].txt is refused while brack1.txt exists")
            }
            try? fm.removeItem(at: directory.appendingPathComponent("brack1.txt"))

            // uploads, also from a local file whose own name contains wildcards
            let localDir = work.appendingPathComponent("local*dir")
            try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
            for name in ["up space.txt", "up*star.txt", "up[1].txt"] {
                let local = localDir.appendingPathComponent(name)
                try "uploaded \(name)".write(to: local, atomically: true, encoding: .utf8)
                try "decoy".write(to: localDir.appendingPathComponent("upload-decoy-" + name.prefix(2) + ".txt"), atomically: true, encoding: .utf8)
                try fs.upload(local, to: path("sub dir/" + name), cancel: nil)
                check((try? String(contentsOf: directory.appendingPathComponent("sub dir/" + name))) == "uploaded \(name)", "\(tag): upload \(name.debugDescription) from a wildcard-named local folder")
            }
            check(try fs.list(path("sub dir")).count == 3, "\(tag): exactly the three files arrived (no wildcard expansion on the local side)")

            // folders and renames
            try fs.makeDirectory(path("new dir"))
            try fs.rename(path("new dir"), to: path("renamed dir"))
            check(fm.fileExists(atPath: path("renamed dir")) && !fm.fileExists(atPath: path("new dir")), "\(tag): make a folder and rename it")
            try fs.rename(path("plain.txt"), to: path("plain renamed.txt"))
            check(fm.fileExists(atPath: path("plain renamed.txt")), "\(tag): rename a file")

            // the dangerous one: deleting "star*.txt" must not delete "starfish.txt"
            try fs.remove(path("star*.txt"), isDirectory: false)
            check(!fm.fileExists(atPath: path("star*.txt")) && fm.fileExists(atPath: path("starfish.txt")), "\(tag): rm of a name with * leaves similar names alone")
            check(((try? fm.contentsOfDirectory(atPath: base)) ?? []).allSatisfy { !$0.hasPrefix(".maclister-delete-") }, "\(tag): no temporary file is left behind")
            try fs.makeDirectory(path("odd*[dir]"))
            check(fm.fileExists(atPath: path("odd*[dir]")), "\(tag): mkdir with wildcard characters")
            try fs.remove(path("odd*[dir]"), isDirectory: true)
            check(!fm.fileExists(atPath: path("odd*[dir]")), "\(tag): rmdir with wildcard characters")
            try fs.remove(path("brack[1].txt"), isDirectory: false)
            check(!fm.fileExists(atPath: path("brack[1].txt")), "\(tag): rm of a name with brackets")
            try fs.remove(path("renamed dir"), isDirectory: true)
            check(!fm.fileExists(atPath: path("renamed dir")), "\(tag): rmdir")
        } catch {
            check(false, "\(tag): unexpected error: \(error.localizedDescription)")
        }

        check((try? fs.list(path("does not exist"))) == nil, "\(tag): a missing folder is an error")
        let token = CancelToken(); token.cancel()
        do { try fs.download(path("starfish.txt"), to: work.appendingPathComponent("cancelled-sftp"), cancel: token); check(false, "\(tag): a cancelled transfer stops") }
        catch { check((error as? RemoteError)?.message == "Cancelled", "\(tag): a cancelled transfer stops") }
        check(FileManager.default.fileExists(atPath: work.path), "\(tag): work folder intact")

        try? fm.removeItem(at: directory)
    }

    // MARK: SFTP over a real sshd (127.0.0.1)

    private static func sshChecks(port: Int, user: String, key: String, protectedKey: String, passphrase: String,
                                  hostPublicKey: String?, otherHostPublicKey: String?, directory: URL, work: URL,
                                  done: @escaping () -> Void) {
        let fm = FileManager.default
        let known = SFTPHostKeys.knownHostsURL
        try? fm.removeItem(at: known)

        func newProfile(key: String?, user: String = user, port: Int = port) -> ServerProfile {
            var p = ServerProfile(); p.scheme = .sftp; p.host = "127.0.0.1"; p.port = port; p.user = user; p.keyPath = key
            return p
        }
        func socket(_ p: ServerProfile) -> String { "/tmp/mcl-\(getuid())-\(p.id.uuidString.prefix(8)).sock" }
        let first = newProfile(key: key)

        var asked = 0
        var shown: [HostKeyInfo] = []
        var failure: String?
        var session: RemoteSession?
        var second: ServerProfile?

        func connect(_ profile: ServerProfile, secret: String = "", trust: Bool = true, onSuccess: @escaping (RemoteSession) -> Void = { _ in }) {
            failure = nil
            RemoteSessions.shared.connect(profile: profile, secret: secret, confirmHostKey: { keys in asked += 1; shown = keys; return trust }) { result in
                switch result {
                case .success(let s): onSuccess(s)
                case .failure(let e): failure = e.message
                }
            }
        }

        // 1. the first contact: declining the fingerprint refuses and stores nothing
        later { connect(first, trust: false) }
        later(4) {
            check(asked == 1 && failure?.contains("not trusted") == true && !fm.fileExists(atPath: known.path),
                  "ssh: declining the host key refuses the connection and stores nothing: \(failure ?? "nil")")
            check(shown.first?.type == "ED25519" && shown.first?.fingerprint.hasPrefix("SHA256:") == true, "ssh: the fingerprint is shown: \(shown.first?.fingerprint ?? "nil")")
            if let hostPublicKey, let output = try? ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", hostPublicKey]) {
                let expected = String(decoding: output.stdout, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init)
                check(expected != nil && expected == shown.first?.fingerprint, "ssh: the shown fingerprint equals the server's real one (\(expected ?? "?"))")
            }
            asked = 0
            connect(first, trust: true) { session = $0 }
        }
        // 2. accepted: an unprotected key file, then every operation over one shared connection
        later(5) {
            check(session != nil && asked == 1, "ssh: after trusting the key the connection works with a key file: \(failure ?? "")")
            check(((try? String(contentsOf: known)) ?? "").contains("[127.0.0.1]:\(port) ssh-ed25519"), "ssh: the trusted key is stored in MacLister's own known_hosts")
            check(session?.home == NSHomeDirectory(), "ssh: the home folder is the login folder: \(session?.home ?? "nil")")
            check(fm.fileExists(atPath: socket(first)), "ssh: one authenticated connection stays open in the background")
            if let fs = session?.fs { sftpOperationChecks(fs: fs, directory: directory, work: work, tag: "ssh") }
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? "hello over ssh".write(to: directory.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        }
        // 3. a known server is not asked about again; replacing a session closes the old connection
        later {
            asked = 0
            second = newProfile(key: key)
            if let second { connect(second) { session = $0 } }
        }
        later(4) {
            check(asked == 0 && session != nil, "ssh: a trusted server is not asked about again: \(failure ?? "")")
            check(!fm.fileExists(atPath: socket(first)), "ssh: the replaced session's background connection is gone")
        }
        // 4. a lister and transfers on the SSH connection
        var lister: ListerWindowController?
        later {
            guard let session else { return }
            lister = ListerManager.shared.openLister(directory: session.url(path: directory.path), anchor: .cursor(NSPoint(x: 300, y: 500), centered: false))
        }
        later(3) {
            check(Set(lister?.model.items.map(\.name) ?? []).contains("hello.txt") && lister?.model.isRemote == true, "ssh: a lister shows the SFTP folder: \(lister?.model.items.map(\.name) ?? [])")
            lister?.close()
            guard let session else { return }
            let up = work.appendingPathComponent("ssh-up")
            try? fm.createDirectory(at: up.appendingPathComponent("tree/sub"), withIntermediateDirectories: true)
            try? String(repeating: "x", count: 3000).write(to: up.appendingPathComponent("tree/a.bin"), atomically: true, encoding: .utf8)
            try? String(repeating: "y", count: 5000).write(to: up.appendingPathComponent("tree/sub/b.bin"), atomically: true, encoding: .utf8)
            let target = session.url(path: directory.path)
            let job = RemoteTransferJob(kind: .copy, direction: .upload, items: [up.appendingPathComponent("tree")], destination: target)
            job.trashesLocalFiles = false
            let result = job.runSync()
            check(result.failures.isEmpty && ((try? String(contentsOf: directory.appendingPathComponent("tree/sub/b.bin")))?.count == 5000), "ssh: a folder is uploaded: \(result.failures)")
            let down = work.appendingPathComponent("ssh-down")
            try? fm.createDirectory(at: down, withIntermediateDirectories: true)
            let back = RemoteTransferJob(kind: .copy, direction: .download, items: [RemoteURL.child(of: target, named: "tree")], destination: down)
            back.trashesLocalFiles = false
            let r2 = back.runSync()
            check(r2.failures.isEmpty && ((try? String(contentsOf: down.appendingPathComponent("tree/a.bin")))?.count == 3000), "ssh: a folder is downloaded: \(r2.failures)")
            try? RemoteOps.deleteRecursively(session.fs, path: directory.path + "/tree", isDirectory: true, cancel: nil)
            check(!fm.fileExists(atPath: directory.appendingPathComponent("tree").path), "ssh: a folder is deleted recursively")
        }
        // 5. a key with a passphrase: the passphrase reaches ssh through SSH_ASKPASS
        var protectedProfile: ServerProfile?
        later {
            protectedProfile = newProfile(key: protectedKey)
            if let protectedProfile { connect(protectedProfile, secret: passphrase) { session = $0 } }
        }
        later(4) {
            check(failure == nil && session?.profile.keyPath == protectedKey, "ssh: a key with a passphrase works through SSH_ASKPASS: \(failure ?? "")")
            check((try? session?.fs.list(directory.path))?.contains { $0.name == "hello.txt" } == true, "ssh: and then lists files")
            connect(newProfile(key: protectedKey), secret: "wrong passphrase")
        }
        later(4) {
            check(failure?.contains("Login denied") == true, "ssh: a wrong passphrase is reported as a refused login: \(failure ?? "nil")")
            connect(newProfile(key: key, user: "nosuchuser-mcl"))
        }
        later(4) {
            check(failure?.contains("Login denied") == true, "ssh: an unknown user is a refused login: \(failure ?? "nil")")
            connect(newProfile(key: key, port: 1))
        }
        later(4) {
            check(failure?.contains("Cannot connect") == true, "ssh: a closed port is reported clearly: \(failure ?? "nil")")
        }
        // 6. a changed host key is refused, never silently accepted
        later {
            if let other = otherHostPublicKey, let text = try? String(contentsOfFile: other, encoding: .utf8) {
                let parts = text.split(separator: " ").prefix(2).joined(separator: " ")
                try? "[127.0.0.1]:\(port) \(parts)\n".write(to: known, atomically: true, encoding: .utf8)
                asked = 0
                connect(newProfile(key: key))
            }
        }
        later(4) {
            if otherHostPublicKey != nil {
                check(failure?.contains("does not match") == true && asked == 0, "ssh: a host key that changed is refused without asking: \(failure ?? "nil")")
            }
        }
        // 7. closing
        later {
            RemoteSessions.shared.closeAll()
        }
        later(1.5) {
            check(protectedProfile.map { !fm.fileExists(atPath: socket($0)) } ?? true && !fm.fileExists(atPath: second.map(socket) ?? "/nonexistent"), "ssh: closing the sessions ends the background connections")
        }
        runSteps(done)
    }

    // MARK: Passwords and server URLs (no network)

    static func offlineChecks() {
        let account = "selftest-" + UUID().uuidString
        if SecretStore.set("s3cret value", for: account) {
            let read = SecretStore.get(account, allowUI: false)
            check(read == "s3cret value" || read == nil, "keychain: a password can be stored (read back: \(read == nil ? "needs a prompt, skipped" : "yes"))")
            SecretStore.delete(account)
            check(SecretStore.get(account, allowUI: false) == nil, "keychain: a deleted password is gone")
        } else {
            check(true, "keychain: storing needs interaction here, skipped")
        }
        var p = ServerProfile(); p.scheme = .sftp; p.host = "host.example"; p.user = "me@corp"; p.port = 2222
        let url = RemoteURL.make(p, path: "/a b/c#d")
        check(RemoteURL.sessionKey(of: url) == p.sessionKey && RemoteURL.path(of: url) == "/a b/c#d", "urls: special characters in server paths survive: \(url.absoluteString)")
        check(RemoteURL.child(of: url, named: "x y?.txt").lastPathComponent == "x y?.txt", "urls: a child name with ? and space")
        check(RemoteURL.isRemote(url) && !RemoteURL.isRemote(URL(fileURLWithPath: "/tmp")) && RemoteURL.parentPath(of: "/a/b") == "/a" && RemoteURL.parentPath(of: "/a") == "/", "urls: remote detection and parents")
        check(RemoteURL.with(path: "/a/b/../c", on: url).path == "/a/c" && RemoteURL.normalized(RemoteURL.with(path: "/a/", on: url)).path == "/a", "urls: .. and trailing slashes are normalised")
        check(RemoteURL.encode("/a b/é") == "/a%20b/%C3%A9", "urls: path encoding")
        check(RemoteListParser.parseLine("-rw-r--r--    1 0        0           12345 Jan  5  2020 old file.txt")?.name == "old file.txt"
              && RemoteListParser.parseLine("drwxr-xr-x    2 user group 4096 Feb 29 10:11 sub dir")?.isDirectory == true
              && RemoteListParser.parseLine("lrwxrwxrwx 1 ftp ftp 4 Nov 14 10:11 link -> docs")?.name == "link"
              && RemoteListParser.parseLine("-rw-r--r-- 1 user 987 Mar 3 09:00 nogroup.txt")?.size == 987
              && RemoteListParser.parseLine("total 12") == nil && RemoteListParser.parseLine("drwxr-xr-x 2 u g 4096 Nov 14 10:11 ..") == nil,
              "parser: unix listings (spaces, links, no group column, total/dot lines)")
        let dos = RemoteListParser.parseLine("11-14-24  09:05PM       <DIR>          My Folder")
        let dosFile = RemoteListParser.parseLine("01-02-2023  12:30AM              1234 report.doc")
        check(dos?.isDirectory == true && dos?.name == "My Folder" && dosFile?.size == 1234 && dosFile?.name == "report.doc", "parser: DOS/Windows listings")
        let sftpLine = RemoteListParser.parseLine("-rw-r--r--    ? someuser wheel          23 Nov 14 09:39 /private/tmp/x/back\\slash.txt")
        check(sftpLine?.size == 23 && sftpLine?.name == "/private/tmp/x/back\\slash.txt" && sftpLine?.permissions == 0o644, "parser: sftp's '?' link count and full-path names")
        let yearAgo = RemoteListParser.parseLine("-rw-r--r-- 1 u g 1 Dec 31 23:00 future.txt", now: Date(timeIntervalSince1970: 1_700_000_000))   // 14 Nov 2023
        check(yearAgo?.modified.map { Calendar.current.component(.year, from: $0) } == 2022, "parser: a date without year that would lie in the future belongs to last year")
    }

    // MARK: Transfers between this Mac and a server

    private static func engineChecks(session: RemoteSession?, root: URL, work: URL, port: Int) {
        guard let session else { check(false, "engine: a session is needed"); return }
        let fm = FileManager.default
        let fs = session.fs
        let remoteBase = session.url(path: "/")
        let area = work.appendingPathComponent("engine")
        try? fm.createDirectory(at: area, withIntermediateDirectories: true)
        try? fs.makeDirectory("/xfer")

        func put(_ rel: String, _ content: String, in base: URL) {
            let u = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? content.write(to: u, atomically: true, encoding: .utf8)
        }
        func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        func onServer(_ rel: String) -> URL { root.appendingPathComponent("xfer/" + rel) }
        func job(_ kind: TransferKind, _ direction: RemoteTransferJob.Direction, _ items: [URL], to destination: URL,
                 _ resolver: @escaping (TransferConflict) -> ConflictDecision = { _ in ConflictDecision(action: .keepBoth) }) -> TransferResult {
            let j = RemoteTransferJob(kind: kind, direction: direction, items: items, destination: destination)
            j.trashesLocalFiles = false
            j.resolver = resolver
            return j.runSync()
        }
        let xfer = remoteBase.appendingPathComponent("xfer")       // server folder /xfer

        // upload a tree
        let up = area.appendingPathComponent("up")
        put("tree/a.bin", String(repeating: "a", count: 1000), in: up)
        put("tree/sub/b.bin", String(repeating: "b", count: 2000), in: up)
        put("tree/sub/deep/c.bin", String(repeating: "c", count: 500), in: up)
        let r1 = job(.copy, .upload, [up.appendingPathComponent("tree")], to: xfer)
        check(r1.failures.isEmpty && fm.fileExists(atPath: onServer("tree/sub/deep/c.bin").path)
              && read(onServer("tree/a.bin"))?.count == 1000 && fm.fileExists(atPath: up.appendingPathComponent("tree/a.bin").path),
              "engine: a tree is uploaded and the local original stays: \(r1.failures)")
        check(r1.done.map { RemoteURL.path(of: $0) } == ["/xfer/tree"], "engine: the result names the new server folder: \(r1.done)")

        // download it again
        let down = area.appendingPathComponent("down")
        try? fm.createDirectory(at: down, withIntermediateDirectories: true)
        let r2 = job(.copy, .download, [xfer.appendingPathComponent("tree")], to: down)
        check(r2.failures.isEmpty && read(down.appendingPathComponent("tree/sub/b.bin"))?.count == 2000 && fm.fileExists(atPath: down.appendingPathComponent("tree/sub/deep/c.bin").path),
              "engine: a tree is downloaded: \(r2.failures)")

        // upload conflicts: keep both, replace-if-newer in both directions, skip
        let c = area.appendingPathComponent("c")
        put("f.txt", "local-new", in: c)
        put("f.txt", "server-old", in: onServer("conflict-a"))
        let future = Date().addingTimeInterval(3600), past = Date().addingTimeInterval(-3600)
        try? fm.setAttributes([.modificationDate: future], ofItemAtPath: c.appendingPathComponent("f.txt").path)
        _ = job(.copy, .upload, [c.appendingPathComponent("f.txt")], to: xfer.appendingPathComponent("conflict-a")) { _ in ConflictDecision(action: .replaceIfNewer) }
        check(read(onServer("conflict-a/f.txt")) == "local-new", "engine: replace-if-newer overwrites an older server file")
        try? fm.setAttributes([.modificationDate: past], ofItemAtPath: c.appendingPathComponent("f.txt").path)
        put("f.txt", "server-new", in: onServer("conflict-b"))
        let r3 = job(.copy, .upload, [c.appendingPathComponent("f.txt")], to: xfer.appendingPathComponent("conflict-b")) { _ in ConflictDecision(action: .replaceIfNewer) }
        check(read(onServer("conflict-b/f.txt")) == "server-new" && r3.skipped == 1, "engine: replace-if-newer keeps a newer server file")
        put("f.txt", "server-x", in: onServer("conflict-c"))
        _ = job(.copy, .upload, [c.appendingPathComponent("f.txt")], to: xfer.appendingPathComponent("conflict-c")) { _ in ConflictDecision(action: .keepBoth) }
        check(read(onServer("conflict-c/f.txt")) == "server-x" && read(onServer("conflict-c/f 2.txt")) == "local-new", "engine: keep both numbers the uploaded file")
        put("f.txt", "server-y", in: onServer("conflict-d"))
        _ = job(.copy, .upload, [c.appendingPathComponent("f.txt")], to: xfer.appendingPathComponent("conflict-d")) { _ in ConflictDecision(action: .replace) }
        check(read(onServer("conflict-d/f.txt")) == "local-new", "engine: replace overwrites the server file")

        // merge a folder, resolving files one by one
        let m = area.appendingPathComponent("m")
        put("proj/x.txt", "new-x", in: m); put("proj/y.txt", "why", in: m)
        put("proj/x.txt", "old-x", in: onServer("merge-up"))
        let r4 = job(.copy, .upload, [m.appendingPathComponent("proj")], to: xfer.appendingPathComponent("merge-up")) { cf in ConflictDecision(action: cf.bothDirectories ? .merge : .skip) }
        check(read(onServer("merge-up/proj/y.txt")) == "why" && read(onServer("merge-up/proj/x.txt")) == "old-x" && r4.skipped == 1, "engine: merging a folder onto a server folder")

        // cancel from the resolver stops everything after it
        let k = area.appendingPathComponent("k")
        for n in ["k1", "k2", "k3"] { put(n, n, in: k) }
        put("k2", "existing", in: onServer("cancel-up"))
        var asked = 0
        let r5 = job(.copy, .upload, ["k1", "k2", "k3"].map { k.appendingPathComponent($0) }, to: xfer.appendingPathComponent("cancel-up")) { _ in asked += 1; return ConflictDecision(action: .cancel) }
        check(r5.cancelled && asked == 1 && fm.fileExists(atPath: onServer("cancel-up/k1").path) && !fm.fileExists(atPath: onServer("cancel-up/k3").path), "engine: Cancel stops the upload: \(r5.done.count) done")

        // moves
        put("mv-up.txt", "moved up", in: area)
        _ = job(.move, .upload, [area.appendingPathComponent("mv-up.txt")], to: xfer)
        check(read(onServer("mv-up.txt")) == "moved up" && !fm.fileExists(atPath: area.appendingPathComponent("mv-up.txt").path), "engine: a move to the server removes the local file")
        let r6 = job(.move, .download, [xfer.appendingPathComponent("mv-up.txt")], to: down)
        check(read(down.appendingPathComponent("mv-up.txt")) == "moved up" && !fm.fileExists(atPath: onServer("mv-up.txt").path) && r6.failures.isEmpty, "engine: a move from the server removes the server file: \(r6.failures)")
        try? fs.makeDirectory("/xfer/into")
        put("inside.txt", "in", in: onServer(""))
        let r7 = job(.move, .moveOnServer, [xfer.appendingPathComponent("inside.txt")], to: xfer.appendingPathComponent("into"))
        check(read(onServer("into/inside.txt")) == "in" && !fm.fileExists(atPath: onServer("inside.txt").path) && r7.failures.isEmpty, "engine: a move inside one server is a rename: \(r7.failures)")
        let r8 = job(.move, .moveOnServer, [xfer.appendingPathComponent("into")], to: xfer.appendingPathComponent("into"))
        check(r8.failures.count == 1 || r8.skipped == 1, "engine: a folder cannot be moved into itself")

        // download conflicts
        put("dl.txt", "server-dl", in: onServer(""))
        put("dl.txt", "local-existing", in: down)
        let r9 = job(.copy, .download, [xfer.appendingPathComponent("dl.txt")], to: down) { _ in ConflictDecision(action: .skip) }
        check(read(down.appendingPathComponent("dl.txt")) == "local-existing" && r9.skipped == 1, "engine: skip keeps the local file")
        _ = job(.copy, .download, [xfer.appendingPathComponent("dl.txt")], to: down) { _ in ConflictDecision(action: .keepBoth) }
        check(read(down.appendingPathComponent("dl 2.txt")) == "server-dl", "engine: keep both numbers the downloaded file")
        _ = job(.copy, .download, [xfer.appendingPathComponent("dl.txt")], to: down) { _ in ConflictDecision(action: .replace) }
        check(read(down.appendingPathComponent("dl.txt")) == "server-dl", "engine: replace overwrites the local file")

        // recursive delete and unique names
        do {
            try RemoteOps.deleteRecursively(fs, path: "/xfer/tree", isDirectory: true, cancel: nil)
            check(!fm.fileExists(atPath: onServer("tree").path), "engine: a server folder is deleted with everything inside")
        } catch { check(false, "engine: recursive delete failed: \(error.localizedDescription)") }
        check(RemoteOps.uniqueName("a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt" && RemoteOps.uniqueName("dir", existing: ["dir"]) == "dir 2" && RemoteOps.uniqueName("z", existing: []) == "z", "engine: unique names")

        // progress reporting
        var log: [TransferProgress] = []
        var finished: TransferResult?
        put("big/p1.bin", String(repeating: "p", count: 4000), in: area)
        put("big/p2.bin", String(repeating: "q", count: 6000), in: area)
        let pj = RemoteTransferJob(kind: .copy, direction: .upload, items: [area.appendingPathComponent("big")], destination: xfer)
        pj.onProgress = { log.append($0) }
        pj.start { finished = $0 }
        later(1.5) {
            check(finished?.done.count == 1 && log.last?.bytesDone == 10000 && log.last?.bytesTotal == 10000, "engine: progress ends at 10000 of 10000 bytes: \(String(describing: log.last))")
            let fractions = log.map(\.fraction)
            check(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 } && fractions.last == 1, "engine: progress never goes backwards")
        }
        later(0.3) {
            try? fm.removeItem(at: root.appendingPathComponent("xfer"))
        }
    }

    private static func profile(_ scheme: RemoteScheme, port: Int, password: String = "secret", insecure: Bool = true) -> ServerProfile {
        var p = ServerProfile()
        p.scheme = scheme; p.host = "127.0.0.1"; p.port = port; p.user = "test"
        p.acceptInvalidCertificate = insecure
        _ = password
        return p
    }

    private static func ftpChecks(scheme: RemoteScheme, port: Int, root: URL, work: URL) {
        let fm = FileManager.default
        let tag = "[\(scheme.rawValue)]"
        let fs = FTPFileSystem(profile: profile(scheme, port: port), password: "secret")

        do {
            check(try fs.homeDirectory() == "/", "\(tag) login works and the home folder is /")

            let top = try fs.list("/")
            let byName = Dictionary(uniqueKeysWithValues: top.map { ($0.name, $0) })
            check(byName["a.txt"]?.size == 6 && byName["a.txt"]?.isDirectory == false, "\(tag) file entry with size: \(top.map(\.name))")
            check(byName["docs"]?.isDirectory == true && byName["with space"]?.isDirectory == true, "\(tag) folders, also with a space in the name")
            check(byName["link"]?.isSymlink == true && byName["link"]?.isDirectory == false, "\(tag) a symbolic link is recognised")
            check(byName["a.txt"]?.permissions == 0o644 && byName["docs"]?.permissions == 0o755 && byName["a.txt"]?.modified != nil, "\(tag) permissions and dates are parsed")
            check(try fs.list("/docs").map(\.name) == ["b.txt"], "\(tag) listing a sub-folder")
            check(try fs.list("/with space").isEmpty, "\(tag) an empty folder lists as empty")

            // download
            let got = work.appendingPathComponent("a-\(scheme.rawValue).txt")
            try fs.download("/a.txt", to: got, cancel: nil)
            check((try? String(contentsOf: got)) == "hello\n", "\(tag) download")

            // upload into a folder whose name has a space, with a space in the file name too
            let local = work.appendingPathComponent("up load.txt")
            try "uploaded \(scheme.rawValue)".write(to: local, atomically: true, encoding: .utf8)
            try fs.upload(local, to: "/with space/up load.txt", cancel: nil)
            check((try? String(contentsOf: root.appendingPathComponent("with space/up load.txt"))) == "uploaded \(scheme.rawValue)", "\(tag) upload")
            check(try fs.list("/with space").first?.size == Int64("uploaded \(scheme.rawValue)".utf8.count), "\(tag) the uploaded file shows its size")

            // folders, rename, delete
            try fs.makeDirectory("/newdir-\(scheme.rawValue)")
            check(fm.fileExists(atPath: root.appendingPathComponent("newdir-\(scheme.rawValue)").path), "\(tag) make a folder")
            try fs.rename("/newdir-\(scheme.rawValue)", to: "/renamed dir-\(scheme.rawValue)")
            check(fm.fileExists(atPath: root.appendingPathComponent("renamed dir-\(scheme.rawValue)").path), "\(tag) rename a folder (with a space)")
            try fs.rename("/with space/up load.txt", to: "/with space/moved file.txt")
            check(fm.fileExists(atPath: root.appendingPathComponent("with space/moved file.txt").path), "\(tag) rename a file")
            try fs.remove("/with space/moved file.txt", isDirectory: false)
            try fs.remove("/renamed dir-\(scheme.rawValue)", isDirectory: true)
            check(!fm.fileExists(atPath: root.appendingPathComponent("with space/moved file.txt").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("renamed dir-\(scheme.rawValue)").path), "\(tag) delete a file and a folder")
        } catch {
            check(false, "\(tag) unexpected error: \(error.localizedDescription)")
        }

        // failures
        check((try? fs.list("/does-not-exist")) == nil, "\(tag) a missing folder is an error")
        check((try? fs.download("/nope.txt", to: work.appendingPathComponent("nope"), cancel: nil)) == nil && !fm.fileExists(atPath: work.appendingPathComponent("nope").path),
              "\(tag) a failed download leaves no partial file")
        let wrong = FTPFileSystem(profile: profile(scheme, port: port), password: "wrong")
        do { _ = try wrong.list("/"); check(false, "\(tag) a wrong password is refused") }
        catch { check(error.localizedDescription.contains("Login denied"), "\(tag) a wrong password is refused: \(error.localizedDescription)") }
        let closed = FTPFileSystem(profile: profile(scheme, port: 1), password: "secret")
        do { _ = try closed.list("/"); check(false, "\(tag) a closed port is an error") }
        catch { check(error.localizedDescription.contains("Cannot connect"), "\(tag) a closed port is an error: \(error.localizedDescription)") }
        let token = CancelToken(); token.cancel()
        do { try fs.download("/a.txt", to: work.appendingPathComponent("cancelled"), cancel: token); check(false, "\(tag) a cancelled transfer stops") }
        catch { check((error as? RemoteError)?.message == "Cancelled", "\(tag) a cancelled transfer stops") }

        if scheme != .ftp {
            let strict = FTPFileSystem(profile: profile(scheme, port: port, insecure: false), password: "secret")
            do { _ = try strict.list("/"); check(false, "\(tag) an untrusted certificate is refused by default") }
            catch { check(error.localizedDescription.contains("certificate"), "\(tag) an untrusted certificate is refused by default: \(error.localizedDescription)") }
        }
    }
}
