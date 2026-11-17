import Foundation
import Darwin

/// Runs a tool to the end and returns its exit status and last words. No progress, no Cancel: for the
/// small jobs behind archive browsing.
enum ExtractProcess {
    static func run(_ tool: String, _ arguments: [String], stdoutTo file: URL?) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        var outputHandle: FileHandle?
        if let file {
            // Without a file to write to, the tool would print the data into this app's own stdout.
            guard FileManager.default.createFile(atPath: file.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: file) else {
                return (-1, tr("Cannot create “%@”", file.lastPathComponent))
            }
            outputHandle = handle
            process.standardOutput = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        defer { try? outputHandle?.close() }

        do { try process.run() }
        catch { return (-1, error.localizedDescription) }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}

/// Unpacks archives, each into a fresh folder, with progress, Pause and Cancel. The unpacking itself is done
/// by bsdtar (or gzip / bzip2) in a child process: Pause stops that process, Cancel ends it. Progress is how far
/// the tool has read into the archive file (all formats, whatever the compression) plus the name of the entry it
/// is writing. A cancelled archive is not thrown away: `ExtractResult.incomplete` lets the user decide.
final class ExtractJob {
    let archives: [URL]
    let parent: URL
    /// Delivered on the main queue, at most about ten times a second.
    var onProgress: ((TransferProgress) -> Void)?

    private let lock = NSLock()            // flags and the child process
    private var cancelFlag = false
    private var pausedFlag = false
    private var child: Process?

    private let stateLock = NSLock()       // progress and the result, touched from the reader and the poller
    private var progress = TransferProgress()
    private var lastReport = Date.distantPast
    private var result = ExtractResult()

    init(archives: [URL], into parent: URL) {
        self.archives = archives
        self.parent = parent
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }

    func cancel() {
        lock.lock()
        cancelFlag = true
        pausedFlag = false
        let running = child
        lock.unlock()
        if let running, running.isRunning {
            kill(running.processIdentifier, SIGCONT)        // a stopped process only dies when it is continued
            running.terminate()
        }
    }

    func pause() {
        lock.lock()
        pausedFlag = true
        let running = child
        lock.unlock()
        if let running, running.isRunning { kill(running.processIdentifier, SIGSTOP) }
    }

    func resume() {
        lock.lock()
        pausedFlag = false
        let running = child
        lock.unlock()
        if let running, running.isRunning { kill(running.processIdentifier, SIGCONT) }
    }

    /// Runs on a background queue; `completion` is called on the main queue.
    func start(completion: @escaping (ExtractResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finished = self.runSync()
            DispatchQueue.main.async { completion(finished) }
        }
    }

    func runSync() -> ExtractResult {
        result = ExtractResult()
        let sizes = archives.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0 }
        stateLock.lock()
        progress = TransferProgress(itemsTotal: archives.count, bytesTotal: sizes.reduce(0, +), current: tr("Preparing…"))
        stateLock.unlock()
        report(force: true)

        for (index, archive) in archives.enumerated() {
            if isCancelled { markCancelled(); break }
            stateLock.lock()
            progress.current = archive.lastPathComponent
            progress.inFlight = 0
            stateLock.unlock()
            report(force: true)

            extractOne(archive, size: sizes[index])

            stateLock.lock()
            progress.itemsDone = index + 1
            progress.bytesDone += sizes[index]
            progress.inFlight = 0
            stateLock.unlock()
            report(force: true)
        }
        stateLock.lock(); defer { stateLock.unlock() }
        return result
    }

    private func markCancelled() { stateLock.lock(); result.cancelled = true; stateLock.unlock() }
    private func addFailure(_ text: String) { stateLock.lock(); result.failures.append(text); stateLock.unlock() }

    // MARK: One archive

    private func extractOne(_ archive: URL, size: Int64) {
        let plan: ArchiveExtractor.Plan
        switch ArchiveExtractor.plan(for: archive, into: parent) {
        case .failure(let error): addFailure("\(archive.lastPathComponent): \(error.message)"); return
        case .success(let made): plan = made
        }
        let fm = FileManager.default
        func discardFolder() { try? fm.removeItem(at: plan.folder) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.tool)
        process.arguments = plan.arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        var outputHandle: FileHandle?
        if let output = plan.outputFile {
            guard fm.createFile(atPath: output.path, contents: nil), let handle = try? FileHandle(forWritingTo: output) else {
                addFailure("\(archive.lastPathComponent): " + tr("Cannot create “%@”", output.lastPathComponent))
                discardFolder()
                return
            }
            outputHandle = handle
            process.standardOutput = handle
        } else {
            process.standardOutput = FileHandle.nullDevice      // the tool would print into this app's own stdout
        }
        defer { try? outputHandle?.close() }

        do { try process.run() } catch {
            addFailure("\(archive.lastPathComponent): \(error.localizedDescription)")
            discardFolder()
            return
        }
        lock.lock()
        child = process
        let stopNow = pausedFlag, killNow = cancelFlag
        lock.unlock()
        if killNow { process.terminate() } else if stopNow { kill(process.processIdentifier, SIGSTOP) }

        // how far the tool has read into the archive, a few times a second
        let archivePath = realPath(archive)
        let pid = process.processIdentifier
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "maclister.extract", qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, size > 0, let offset = Self.inputOffset(pid: pid, path: archivePath) else { return }
            self.stateLock.lock()
            self.progress.inFlight = min(offset, size)
            self.stateLock.unlock()
            self.report(force: false)
        }
        timer.resume()

        // the entries, as the tool names them
        var entries: [String] = []             // every "x name" line, in order
        var errorLines: [String] = []
        var buffer = Data()
        func handle(_ line: String) {
            if line.hasPrefix("x ") {
                let name = Self.decodeEscapes(String(line.dropFirst(2)))
                entries.append(name)
                var shown = name.hasSuffix("/") ? String(name.dropLast()) : name
                while shown.hasPrefix("./") { shown.removeFirst(2) }       // tar names everything "./…"
                stateLock.lock()
                progress.current = shown
                stateLock.unlock()
                report(force: false)
            } else if !line.isEmpty {
                errorLines.append(line)
                if errorLines.count > 30 { errorLines.removeFirst() }
            }
        }
        while true {
            let chunk = errorPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                handle(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { handle(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()
        timer.cancel()
        lock.lock(); child = nil; lock.unlock()

        if process.terminationStatus == 0 {
            stateLock.lock(); result.outputs.append(plan.folder); stateLock.unlock()
            return
        }
        if isCancelled, process.terminationReason == .uncaughtSignal {
            markCancelled()
            settleCancelled(archive, plan: plan, entries: entries)
            return
        }
        discardFolder()                          // never leave a half-empty folder behind after a failure
        let line = errorLines.last ?? "exit \(process.terminationStatus)"
        addFailure("\(archive.lastPathComponent): \(line)")
    }

    /// The tool was stopped by Cancel. The entry it was writing is cut short: delete it. What is left is either
    /// nothing (the folder goes away) or an incomplete folder for the user to judge.
    private func settleCancelled(_ archive: URL, plan: ArchiveExtractor.Plan, entries: [String]) {
        let fm = FileManager.default
        if plan.isStream { try? fm.removeItem(at: plan.folder); return }      // half of one file is of no use

        var removed: String?
        var complete = entries
        if let last = entries.last, !last.hasSuffix("/") {
            complete.removeLast()
            let url = plan.folder.appendingPathComponent(last)
            if Self.isInside(url, plan.folder), Self.isRegularFile(url), (try? fm.removeItem(at: url)) != nil { removed = last }
        }
        let files = complete.filter { !$0.hasSuffix("/") }.count
        if files == 0 {
            try? fm.removeItem(at: plan.folder)
            return
        }
        stateLock.lock()
        result.incomplete = IncompleteExtraction(archive: archive, folder: plan.folder, items: files, removed: removed)
        stateLock.unlock()
    }

    // MARK: Progress

    private func report(force: Bool) {
        guard let onProgress else { return }
        let now = Date()
        stateLock.lock()
        guard force || now.timeIntervalSince(lastReport) >= 0.1 else { stateLock.unlock(); return }
        lastReport = now
        let snapshot = progress
        stateLock.unlock()
        DispatchQueue.main.async { onProgress(snapshot) }
    }

    // MARK: Helpers

    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The position of the read pointer in the archive file the child process has open, or nil.
    static func inputOffset(pid: pid_t, path: String) -> Int64? {
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listSize) / MemoryLayout<proc_fdinfo>.stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, listSize)
        guard used > 0 else { return nil }
        let wanted = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, wanted) == wanted else { continue }
            let opened = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if opened == path { return info.pfi.fi_offset }
        }
        return nil
    }

    /// bsdtar writes names with anything but plain ASCII as \303\251 when it runs without a UTF-8 locale.
    static func decodeEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        var i = 0
        while i < source.count {
            if source[i] == 0x5C, i + 3 < source.count,
               source[i + 1...i + 3].allSatisfy({ $0 >= 0x30 && $0 <= 0x37 }),
               let value = UInt8(String(decoding: source[i + 1...i + 3], as: UTF8.self), radix: 8) {
                bytes.append(value)
                i += 4
            } else {
                bytes.append(source[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
