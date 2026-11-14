import SwiftUI
import AppKit

/// The operation log: every copy, move, upload and trashing with its outcome, newest first.
struct OperationLogView: View {
    @ObservedObject var log: OperationLog = .shared
    @State private var retention = OperationLog.retentionDays
    @State private var confirmClear = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if log.records.isEmpty {
                Text("No operations yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(log.records) { record in row(record) }
                    .listStyle(.inset)
            }
            Divider()
            HStack {
                Picker("Keep the log for", selection: $retention) {
                    ForEach(OperationLog.retentionChoices, id: \.self) { days in
                        Text(days == 365 ? tr("1 year") : tr("%d days", days)).tag(days)
                    }
                }
                .fixedSize()
                .onChange(of: retention) { days in
                    OperationLog.retentionDays = days
                    log.prune()
                }
                Spacer()
                Button("Undo Last Operation") {
                    log.undoLast { outcome in
                        if let outcome { ListerManager.shared.reloadListers(showing: outcome.folders) }
                    }
                }
                .disabled(log.lastUndoable == nil)
                Button("Clear Log…") { confirmClear = true }
                    .disabled(log.records.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 320)
        .confirmationDialog("Clear the operation log?", isPresented: $confirmClear) {
            Button("Clear Log", role: .destructive) { log.clear() }
        } message: {
            Text("Files are not affected, but Undo will no longer be possible.")
        }
    }

    private func row(_ record: OperationRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.kind.symbol)
                .frame(width: 20)
                .foregroundStyle(record.status == .done ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.kind.title).fontWeight(.medium)
                    Text(record.itemsText).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Self.formatter.string(from: record.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(record.from)  →  \(record.to)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                HStack(spacing: 6) {
                    Text(record.status.title).font(.caption)
                        .foregroundStyle(record.status == .done ? Color.secondary : Color.orange)
                    if record.undone { Text("Undone").font(.caption.weight(.medium)).foregroundStyle(.purple) }
                }
                ForEach(record.problems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

enum OperationLogWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            NSApp.bringToFront()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: OperationLogView())
        let created = NSWindow(contentViewController: host)
        created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        created.title = tr("Operation Log")
        created.isReleasedWhenClosed = false
        created.setContentSize(NSSize(width: 640, height: 420))
        created.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in window = nil }
        window = created
        NSApp.bringToFront()
        created.makeKeyAndOrderFront(nil)
    }
}
