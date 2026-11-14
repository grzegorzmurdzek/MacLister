import Foundation
import Combine

/// One line of the operation log: what was done, where, and how it ended.
struct OperationRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case copy, move, upload, download, moveOnServer, trash, duplicate

        var title: String {
            switch self {
            case .copy: return tr("Copy")
            case .move: return tr("Move")
            case .upload: return tr("Upload")
            case .download: return tr("Download")
            case .moveOnServer: return tr("Move on server")
            case .trash: return tr("Move to Trash")
            case .duplicate: return tr("Duplicate")
            }
        }

        var symbol: String {
            switch self {
            case .copy, .duplicate: return "doc.on.doc"
            case .move, .moveOnServer: return "arrowshape.turn.up.right"
            case .upload: return "arrow.up.circle"
            case .download: return "arrow.down.circle"
            case .trash: return "trash"
            }
        }
    }

    enum Status: String, Codable {
        case done, partial, cancelled, failed
        var title: String {
            switch self {
            case .done: return tr("Done")
            case .partial: return tr("With problems")
            case .cancelled: return tr("Cancelled")
            case .failed: return tr("Failed")
            }
        }
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var status: Status
    var count: Int                  // items asked for
    var done: Int                   // items that arrived
    var first: String               // name of the first item
    var from: String
    var to: String
    var problems: [String] = []
    var undone = false

    /// "report.pdf +2"
    var itemsText: String { count > 1 ? "\(first) +\(count - 1)" : first }
}

/// What it takes to take an operation back (kept in memory only: after a restart the log stays, Undo does not).
struct UndoStep {
    let recordID: UUID
    let kind: OperationRecord.Kind
    let pairs: [TransferPair]
    let label: String               // "Copy of report.pdf +2"

    var isUndoable: Bool { pairs.contains(where: \.undoable) }
}

extension Notification.Name {
    static let operationLogChanged = Notification.Name("MacListerOperationLogChanged")
}

/// The persistent history of copies, moves, uploads, trashing… with a retention limit, plus the stack of
/// operations that can still be undone.
final class OperationLog: ObservableObject {
    static let shared = OperationLog()

    /// Newest first.
    @Published private(set) var records: [OperationRecord] = []
    private(set) var undoStack: [UndoStep] = []
    private(set) var isUndoing = false

    static let maxRecords = 1000
    static let maxUndoSteps = 20
    static let retentionChoices = [7, 30, 90, 365]

    /// Overrides the clock in tests.
    var now: () -> Date = Date.init

    private var file: URL { AppSupport.directory.appendingPathComponent("operations.json") }

    private init() { load() }

    // MARK: Retention

    static var retentionDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "logRetentionDays")
            return retentionChoices.contains(stored) ? stored : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "logRetentionDays") }
    }

    /// Drops records older than the retention period and everything beyond the size limit.
    @discardableResult
    func prune() -> Int {
        let limit = now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let before = records.count
        records = Array(records.filter { $0.date >= limit }.prefix(Self.maxRecords))
        if records.count != before { save() }
        return before - records.count
    }

    // MARK: Recording

    /// Adds a line; when the operation can be taken back it also goes onto the undo stack.
    @discardableResult
    func record(kind: OperationRecord.Kind, items: [URL], result: TransferResult, from: String, to: String,
                trashed: Bool = false) -> OperationRecord {
        let names = items.map { RemoteURL.isRemote($0) ? (RemoteURL.path(of: $0) as NSString).lastPathComponent : $0.lastPathComponent }
        let status: OperationRecord.Status
        if result.cancelled { status = .cancelled }
        else if !result.failures.isEmpty { status = result.done.isEmpty && result.pairs.isEmpty ? .failed : .partial }
        else { status = .done }
        let record = OperationRecord(date: now(), kind: kind, status: status, count: items.count,
                                     done: max(result.done.count, result.pairs.count), first: names.first ?? "",
                                     from: from, to: to, problems: Array(result.failures.prefix(5)))
        records.insert(record, at: 0)
        prune()
        save()

        let undoable = result.pairs.filter(\.undoable)
        if !undoable.isEmpty, kind != .upload, kind != .download, kind != .moveOnServer {
            let step = UndoStep(recordID: record.id, kind: kind, pairs: result.pairs, label: kind.title + " · " + record.itemsText)
            undoStack.append(step)
            if undoStack.count > Self.maxUndoSteps { undoStack.removeFirst(undoStack.count - Self.maxUndoSteps) }
        }
        NotificationCenter.default.post(name: .operationLogChanged, object: nil)
        return record
    }

    func clear() {
        records = []
        undoStack = []
        save()
        NotificationCenter.default.post(name: .operationLogChanged, object: nil)
    }

    // MARK: Undo

    var lastUndoable: UndoStep? { undoStack.last(where: \.isUndoable) }

    /// Takes back the most recent operation that can be taken back. `completion` runs on the main queue.
    /// A second call while one is still running gets `nil`: the step leaves the stack only when it finishes,
    /// so without this guard a quick double ⌘Z would take the same operation back twice.
    func undoLast(completion: @escaping (UndoOutcome?) -> Void) {
        guard !isUndoing, let step = lastUndoable else { completion(nil); return }
        isUndoing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = OperationUndo.run(step)
            DispatchQueue.main.async {
                self.isUndoing = false
                self.finishUndo(step, outcome)
                completion(outcome)
            }
        }
    }

    /// Synchronous variant for the self-test.
    func undoLastSync() -> UndoOutcome? {
        guard let step = lastUndoable else { return nil }
        let outcome = OperationUndo.run(step)
        finishUndo(step, outcome)
        return outcome
    }

    private func finishUndo(_ step: UndoStep, _ outcome: UndoOutcome) {
        undoStack.removeAll { $0.recordID == step.recordID }
        if let index = records.firstIndex(where: { $0.id == step.recordID }) {
            records[index].undone = outcome.failures.isEmpty
            if !outcome.failures.isEmpty { records[index].problems = Array((["Undo: " + outcome.failures[0]] + records[index].problems).prefix(5)) }
        }
        save()
        NotificationCenter.default.post(name: .operationLogChanged, object: nil)
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([OperationRecord].self, from: data) { records = saved }
        prune()
    }

    /// Reads the file again (the self-test redirects the folder).
    func reloadFromDisk() {
        records = []
        undoStack = []
        load()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: - Undo

struct UndoOutcome {
    var restored = 0
    var failures: [String] = []
    var folders: [URL] = []          // folders whose listing changed
    var label = ""
}

enum OperationUndo {
    /// Copies and duplicates: the new items go to the Trash. Moves and Trash: the items go back where they
    /// came from. A replaced item is put back in its place. Nothing is ever deleted for good.
    static func run(_ step: UndoStep) -> UndoOutcome {
        let fm = FileManager.default
        var outcome = UndoOutcome(label: step.label)

        for pair in step.pairs.reversed() where pair.undoable {
            let name = pair.target.lastPathComponent
            guard (try? fm.attributesOfItem(atPath: pair.target.path)) != nil else {
                outcome.failures.append(tr("“%@” is no longer there", name))
                continue
            }
            do {
                switch step.kind {
                case .copy, .duplicate:
                    try fm.trashItem(at: pair.target, resultingItemURL: nil)
                    outcome.folders.append(pair.target.deletingLastPathComponent())
                case .move, .trash:
                    if (try? fm.attributesOfItem(atPath: pair.source.path)) != nil {
                        outcome.failures.append(tr("“%@” cannot go back: something else is at its old place", name))
                        continue
                    }
                    var isDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: pair.source.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        outcome.failures.append(tr("“%@” cannot go back: its old folder is gone", name))
                        continue
                    }
                    try fm.moveItem(at: pair.target, to: pair.source)
                    outcome.folders += [pair.target.deletingLastPathComponent(), pair.source.deletingLastPathComponent()]
                default:
                    continue
                }
                if let replaced = pair.replaced, (try? fm.attributesOfItem(atPath: replaced.path)) != nil {
                    let spot = step.kind == .trash ? pair.source : pair.target
                    if (try? fm.attributesOfItem(atPath: spot.path)) == nil {
                        try fm.moveItem(at: replaced, to: spot)
                    }
                }
                outcome.restored += 1
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
