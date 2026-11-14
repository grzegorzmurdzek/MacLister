import SwiftUI
import AppKit

/// Synchronize (Directory Opus): compares the source and the destination folder, shows what would be copied (and what
/// would go to the Trash), and does it for the items you leave ticked. Every replaced file goes to the Trash first.
enum Synchronizer {
    struct FileInfo: Equatable {
        var size: Int64
        var modified: Date?
    }

    enum Action: Equatable {
        case copyToDestination, copyToSource, trashInDestination

        var symbol: String {
            switch self {
            case .copyToDestination: return "arrow.right"
            case .copyToSource: return "arrow.left"
            case .trashInDestination: return "trash"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        var rel: String                 // path below the two folders
        var action: Action
        var note: String
        var size: Int64
        var id: String { rel }
    }

    struct Options: Equatable {
        /// false: the destination is brought up to date from the source. true: the newer file wins, in both directions.
        var twoWay = false
        /// One way only: files that exist only in the destination go to the Trash.
        var deleteExtras = false
        /// One way only: also replace destination files that are newer than the source's.
        var replaceNewer = false
    }

    struct Plan: Equatable {
        var items: [Item] = []
        var keptNewer = 0               // newer in the destination, left alone
        var conflicts = 0               // two-way: other size, same time; left alone
    }

    /// Same time within this many seconds counts as the same (coarse file system clocks).
    static let tolerance: TimeInterval = 2

    // MARK: Scanning

    /// All files below `root` (links count as files, folders are implied), keyed by their path below `root`.
    static func scan(_ root: URL, cancel: CancelToken? = nil) -> [String: FileInfo]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return [:] }
        let prefix = root.standardizedFileURL.path + "/"
        var result: [String: FileInfo] = [:]
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited % 256 == 0, cancel?.isCancelled == true { return nil }
            if url.lastPathComponent == ".DS_Store" { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            result[String(path.dropFirst(prefix.count))] = FileInfo(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
        return cancel?.isCancelled == true ? nil : result
    }

    // MARK: Planning

    static func plan(source a: [String: FileInfo], destination b: [String: FileInfo], options: Options) -> Plan {
        var plan = Plan()
        for rel in Set(a.keys).union(b.keys).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            switch (a[rel], b[rel]) {
            case let (x?, nil):
                plan.items.append(Item(rel: rel, action: .copyToDestination, note: tr("new"), size: x.size))
            case let (nil, y?):
                if options.twoWay {
                    plan.items.append(Item(rel: rel, action: .copyToSource, note: tr("only in the destination"), size: y.size))
                } else if options.deleteExtras {
                    plan.items.append(Item(rel: rel, action: .trashInDestination, note: tr("not in the source"), size: y.size))
                }
            case let (x?, y?):
                let sameTime = abs((x.modified ?? .distantPast).timeIntervalSince(y.modified ?? .distantPast)) <= tolerance
                if sameTime && x.size == y.size { continue }
                let sourceNewer = (x.modified ?? .distantPast) > (y.modified ?? .distantPast).addingTimeInterval(tolerance)
                let destinationNewer = (y.modified ?? .distantPast) > (x.modified ?? .distantPast).addingTimeInterval(tolerance)
                if sourceNewer {
                    plan.items.append(Item(rel: rel, action: .copyToDestination, note: tr("newer in the source"), size: x.size))
                } else if destinationNewer {
                    if options.twoWay {
                        plan.items.append(Item(rel: rel, action: .copyToSource, note: tr("newer in the destination"), size: y.size))
                    } else if options.replaceNewer {
                        plan.items.append(Item(rel: rel, action: .copyToDestination, note: tr("replaces a newer file"), size: x.size))
                    } else {
                        plan.keptNewer += 1
                    }
                } else if options.twoWay {
                    plan.conflicts += 1         // same time, other size: which one is right?
                } else {
                    plan.items.append(Item(rel: rel, action: .copyToDestination, note: tr("other size"), size: x.size))
                }
            case (nil, nil):
                break
            }
        }
        return plan
    }

    // MARK: Doing it

    /// Runs on a background queue. Replaced files go to the Trash first; a copy that fails puts the old file back.
    static func run(_ items: [Item], source: URL, destination: URL, cancel: CancelToken,
                    progress: @escaping (_ done: Int, _ total: Int, _ current: String) -> Void) -> TransferResult {
        let fm = FileManager.default
        var result = TransferResult()
        for (index, item) in items.enumerated() {
            if cancel.isCancelled { result.cancelled = true; break }
            progress(index, items.count, item.rel)
            let a = source.appendingPathComponent(item.rel), b = destination.appendingPathComponent(item.rel)
            switch item.action {
            case .trashInDestination:
                do {
                    try fm.trashItem(at: b, resultingItemURL: nil)
                    result.done.append(b)
                } catch {
                    result.failures.append("\(item.rel): \(error.localizedDescription)")
                }
            case .copyToDestination, .copyToSource:
                let from = item.action == .copyToDestination ? a : b
                let to = item.action == .copyToDestination ? b : a
                var replaced: URL?
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? fm.attributesOfItem(atPath: to.path)) != nil {
                        var landed: NSURL?
                        try fm.trashItem(at: to, resultingItemURL: &landed)
                        replaced = landed as URL?
                    }
                    try fm.copyItem(at: from, to: to)
                    result.done.append(to)
                    result.pairs.append(TransferPair(source: from, target: to, replaced: replaced))
                } catch {
                    if let replaced { try? fm.moveItem(at: replaced, to: to) }
                    result.failures.append("\(item.rel): \(error.localizedDescription)")
                }
            }
        }
        progress(items.count, items.count, "")
        result.cancelled = result.cancelled || cancel.isCancelled
        return result
    }
}

// MARK: - The window

struct SynchronizeView: View {
    let source: URL
    let destination: URL
    var onRun: ([Synchronizer.Item]) -> Void
    var close: () -> Void

    @State private var scanning = true
    @State private var sourceFiles: [String: Synchronizer.FileInfo] = [:]
    @State private var destinationFiles: [String: Synchronizer.FileInfo] = [:]
    @State private var options = Synchronizer.Options()
    @State private var plan = Synchronizer.Plan()
    @State private var excluded: Set<String> = []
    @State private var token = CancelToken()

    private var chosen: [Synchronizer.Item] { plan.items.filter { !excluded.contains($0.id) } }

    private func summary() -> String {
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        let toDestination = chosen.filter { $0.action == .copyToDestination }
        let toSource = chosen.filter { $0.action == .copyToSource }
        let trash = chosen.filter { $0.action == .trashInDestination }
        var parts: [String] = []
        if !toDestination.isEmpty { parts.append(tr("%d to the destination (%@)", toDestination.count, bytes(toDestination.reduce(0) { $0 + $1.size }))) }
        if !toSource.isEmpty { parts.append(tr("%d to the source (%@)", toSource.count, bytes(toSource.reduce(0) { $0 + $1.size }))) }
        if !trash.isEmpty { parts.append(tr("%d to the Trash", trash.count)) }
        if parts.isEmpty { parts.append(tr("Nothing to do: the folders match")) }
        if plan.keptNewer > 0 { parts.append(tr("%d newer in the destination are kept", plan.keptNewer)) }
        if plan.conflicts > 0 { parts.append(tr("%d with the same time but another size are left alone", plan.conflicts)) }
        return parts.joined(separator: " · ")
    }

    private func recompute() {
        plan = Synchronizer.plan(source: sourceFiles, destination: destinationFiles, options: options)
        excluded = excluded.intersection(Set(plan.items.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synchronize").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Source: %@", PathText.short(source.path))).lineLimit(1).truncationMode(.middle)
                Text(tr("Destination: %@", PathText.short(destination.path))).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout).foregroundStyle(.secondary)

            Picker("", selection: $options.twoWay) {
                Text("Update the destination from the source").tag(false)
                Text("Both ways: the newer file wins").tag(true)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if options.twoWay {
                Text("Files that exist on one side only are copied to the other.").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Move files that are only in the destination to the Trash", isOn: $options.deleteExtras)
                Toggle("Also replace files that are newer in the destination", isOn: $options.replaceNewer)
            }

            if scanning {
                HStack { ProgressView().controlSize(.small); Text("Comparing the folders…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(plan.items) { item in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { !excluded.contains(item.id) },
                                                 set: { on in if on { excluded.remove(item.id) } else { excluded.insert(item.id) } }))
                            .labelsHidden()
                        Image(systemName: item.action.symbol).frame(width: 18).foregroundStyle(item.action == .trashInDestination ? .red : .secondary)
                        Text(item.rel).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(item.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 200)
            }

            Text(scanning ? "" : summary()).font(.caption).foregroundStyle(.secondary).lineLimit(2)

            HStack {
                Spacer()
                Button("Cancel") { token.cancel(); close() }.keyboardShortcut(.cancelAction)
                Button("Synchronize") { onRun(chosen); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scanning || chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onChange(of: options) { _ in recompute() }
        .onAppear {
            let token = token
            DispatchQueue.global(qos: .userInitiated).async {
                let a = Synchronizer.scan(source, cancel: token)
                let b = a == nil ? nil : Synchronizer.scan(destination, cancel: token)
                DispatchQueue.main.async {
                    guard let a, let b else { return }
                    sourceFiles = a
                    destinationFiles = b
                    recompute()
                    scanning = false
                }
            }
        }
    }
}

extension ListerViewController {
    /// Opens the Synchronize window for the source and destination listers' folders.
    func promptSynchronize() {
        if remoteUnavailable(tr("Synchronize")) { return }
        let manager = ListerManager.shared
        guard let destinationModel = manager.destinationController?.model else {
            model.errorMessage = tr("No destination lister: press DST in the lister to compare with")
            return
        }
        let sourceModel = manager.sourceController?.model ?? model
        guard sourceModel !== destinationModel, ListerModel.comparisonKey(sourceModel.url) != ListerModel.comparisonKey(destinationModel.url) else {
            model.errorMessage = tr("Source and destination show the same folder")
            return
        }
        if sourceModel.isInArchive || destinationModel.isInArchive {
            model.errorMessage = tr("“%@” is not available inside an archive: it is read-only. Copy the files out first.", tr("Synchronize"))
            return
        }
        guard !sourceModel.isVirtual, !destinationModel.isVirtual, !sourceModel.isRemote, !destinationModel.isRemote,
              let window = view.window else {
            model.errorMessage = tr("Synchronize needs two local folders")
            return
        }
        let source = sourceModel.url, destination = destinationModel.url
        SheetPresenter().present(on: window, size: NSSize(width: 640, height: 560)) { close in
            SynchronizeView(source: source, destination: destination, onRun: { [weak self] items in
                self?.runSynchronize(items, source: source, destination: destination, showingIn: [sourceModel, destinationModel])
            }, close: close)
        }
    }

    func runSynchronize(_ items: [Synchronizer.Item], source: URL, destination: URL, showingIn models: [ListerModel]) {
        guard !items.isEmpty else { return }
        let token = CancelToken()
        let verb = tr("Synchronizing")
        let cancel: () -> Void = { token.cancel() }
        for m in models { m.progress = TransferStatus(text: verb + "…", fraction: 0, cancel: cancel) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Synchronizer.run(items, source: source, destination: destination, cancel: token) { done, total, current in
                DispatchQueue.main.async {
                    let text = tr("%@ %d of %d", verb, min(done + 1, total), total) + (current.isEmpty ? "" : " · \(current)")
                    for m in models where m.progress != nil {
                        m.progress = TransferStatus(text: text, fraction: total > 0 ? Double(done) / Double(total) : nil, cancel: cancel)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                for m in models { m.progress = nil }
                let urls = items.map { source.appendingPathComponent($0.rel) }
                OperationLog.shared.record(kind: .synchronize, items: urls, result: result,
                                           from: Self.placeName(source), to: Self.placeName(destination))
                let touched = items.flatMap { [source.appendingPathComponent($0.rel).deletingLastPathComponent(),
                                               destination.appendingPathComponent($0.rel).deletingLastPathComponent()] }
                ListerManager.shared.reloadListers(showing: [source, destination] + touched)
                guard let self else { return }
                if !result.failures.isEmpty {
                    self.model.errorMessage = result.failures.prefix(3).joined(separator: "; ")
                } else if result.cancelled {
                    self.flash(tr("Cancelled after %d of %d items", result.done.count, items.count))
                } else {
                    self.flash(tr("Synchronized %d items", result.done.count))
                }
            }
        }
    }
}
