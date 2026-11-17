import SwiftUI
import AppKit
import Charts
import Combine

/// The window that opens when the progress bar of a lister is clicked: what is being copied, how far
/// it is, how fast, a graph of the speed, and Pause / Cancel.
struct TransferDetailsView: View {
    @ObservedObject var monitor: TransferMonitor
    let close: () -> Void

    private var progress: TransferProgress { monitor.progress }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(now: context.date)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 6) {
                if progress.itemsTotal > 0 || progress.bytesTotal > 0 {
                    ProgressView(value: min(1, max(0, progress.fraction)))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(progress.current.isEmpty ? " " : progress.current)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(percentText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                speedChart.frame(height: 120).padding(.top, 4)
            } label: {
                HStack {
                    Label("Speed", systemImage: "speedometer").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(monitor.isPaused ? tr("Paused") : TransferMonitor.speedText(monitor.speed))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(monitor.isPaused ? Color.secondary : Color.accentColor)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    stat("Elapsed", TransferMonitor.timeText(monitor.activeElapsed(now: now)))
                    stat("Remaining", remainingText(now: now))
                }
                GridRow {
                    stat("Average", TransferMonitor.speedText(monitor.averageSpeed(now: now)))
                    stat("Peak", TransferMonitor.speedText(monitor.peak))
                }
                GridRow {
                    stat("Items", progress.itemsTotal > 0 ? tr("%d of %d", min(progress.itemsDone + (monitor.state == .running ? 1 : 0), progress.itemsTotal), progress.itemsTotal) : "—")
                    stat("Size", sizeText)
                }
            }

            HStack {
                Spacer()
                if monitor.state == .running {
                    Button {
                        monitor.isPaused ? monitor.resume() : monitor.pause()
                    } label: {
                        Label(monitor.isPaused ? tr("Resume") : tr("Pause"), systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button("Cancel", role: .cancel) { monitor.cancel() }
                } else {
                    Button("Close") { close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).font(.headline)
                HStack(spacing: 4) {
                    Text(monitor.from).lineLimit(1).truncationMode(.head)
                    Image(systemName: "arrow.right").font(.caption2)
                    Text(monitor.to).lineLimit(1).truncationMode(.head)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerSymbol: String {
        switch monitor.state {
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .running: return "doc.on.doc.fill"
        }
    }

    private var headerTitle: String {
        switch monitor.state {
        case .finished: return tr("Finished")
        case .cancelled: return tr("Cancelled")
        case .failed: return tr("Finished with problems")
        case .running: return monitor.isPaused ? tr("%@ — paused", monitor.title) : monitor.title
        }
    }

    private var percentText: String {
        progress.bytesTotal > 0 || progress.itemsTotal > 0 ? "\(Int((min(1, max(0, progress.fraction)) * 100).rounded()))%" : ""
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard progress.bytesTotal > 0 else { return formatter.string(fromByteCount: progress.effectiveBytes) }
        return tr("%@ of %@", formatter.string(fromByteCount: min(progress.effectiveBytes, progress.bytesTotal)), formatter.string(fromByteCount: progress.bytesTotal))
    }

    private func remainingText(now: Date) -> String {
        if monitor.state != .running { return "—" }
        if monitor.isPaused { return tr("Paused") }
        guard let seconds = monitor.remaining(now: now) else { return tr("calculating…") }
        return TransferMonitor.timeText(seconds)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.callout)
        .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private var speedChart: some View {
        if monitor.samples.count < 2 {
            Text("Collecting speed data…").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let top = max(monitor.peak, 1) * 1.15
            Chart(monitor.samples) { sample in
                AreaMark(x: .value("Time", sample.seconds), y: .value("Speed", sample.bytesPerSecond))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.04)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.seconds), y: .value("Speed", sample.bytesPerSecond))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            .chartYScale(domain: 0...top)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(bytes < 1 ? "0" : TransferMonitor.speedText(bytes)).font(.caption2) }
                    }
                }
            }
        }
    }
}

/// Keeps one details window per transfer.
enum TransferDetailsWindows {
    private static var windows: [ObjectIdentifier: NSWindow] = [:]
    private static var observers: [ObjectIdentifier: AnyCancellable] = [:]

    static func show(_ monitor: TransferMonitor) {
        let key = ObjectIdentifier(monitor)
        if let existing = windows[key] {
            NSApp.bringToFront()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: TransferDetailsView(monitor: monitor, close: { close(monitor) }))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.title = title(for: monitor)
        window.center()
        windows[key] = window

        // The title follows the job: "37% — Copying", then "Finished". A finished window closes by itself.
        observers[key] = monitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak monitor] _ in
                guard let window, let monitor else { return }
                window.title = title(for: monitor)
                if monitor.state != .running { scheduleClose(monitor) }
            }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            windows[key] = nil
            observers[key] = nil
        }
        NSApp.bringToFront()
        window.makeKeyAndOrderFront(nil)
    }

    static func isOpen(for monitor: TransferMonitor) -> Bool { windows[ObjectIdentifier(monitor)] != nil }

    static func close(_ monitor: TransferMonitor) {
        windows[ObjectIdentifier(monitor)]?.close()
    }

    private static var closing: Set<ObjectIdentifier> = []

    private static func scheduleClose(_ monitor: TransferMonitor) {
        let key = ObjectIdentifier(monitor)
        guard !closing.contains(key) else { return }
        closing.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            closing.remove(key)
            close(monitor)
        }
    }

    private static func title(for monitor: TransferMonitor) -> String {
        switch monitor.state {
        case .running:
            let progress = monitor.progress
            let percent = progress.bytesTotal > 0 || progress.itemsTotal > 0 ? "\(Int((min(1, max(0, progress.fraction)) * 100).rounded()))% — " : ""
            return percent + monitor.title
        case .finished: return tr("Finished")
        case .cancelled: return tr("Cancelled")
        case .failed: return tr("Finished with problems")
        }
    }
}
