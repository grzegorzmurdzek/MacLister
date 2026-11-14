import Foundation

// MARK: - Pause

/// Lets a running job be paused. A job calls `waitWhilePaused` before it starts each file, so a pause
/// takes effect after the file in flight (copying one file cannot be interrupted half way).
final class PauseGate {
    private let condition = NSCondition()
    private var paused = false

    var isPaused: Bool { condition.lock(); defer { condition.unlock() }; return paused }

    func pause() { condition.lock(); paused = true; condition.unlock() }

    func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }

    /// Blocks while paused. Returns as soon as the job is resumed or `cancelled()` turns true.
    func waitWhilePaused(cancelled: () -> Bool) {
        condition.lock()
        while paused, !cancelled() { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.2)) }
        condition.unlock()
    }
}

// MARK: - Bytes of the file being copied

/// Polls the size of a file that is being written, so progress and speed move during one big file.
final class GrowthWatcher {
    private let url: URL
    private let handler: (Int64) -> Void
    private let timer: DispatchSourceTimer

    /// `handler` runs on a background queue about five times a second.
    init(url: URL, interval: TimeInterval = 0.2, handler: @escaping (Int64) -> Void) {
        self.url = url
        self.handler = handler
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "maclister.growth", qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [url, handler] in
            var info = stat()
            if lstat(url.path, &info) == 0 { handler(Int64(info.st_size)) }
        }
        timer.resume()
    }

    func stop() { timer.cancel() }

    deinit { timer.cancel() }
}

/// Bytes of the current file already written, shared between the worker thread and the poller.
final class LiveBytes {
    private let lock = NSLock()
    private var value: Int64 = 0

    var current: Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ bytes: Int64) { lock.lock(); value = bytes; lock.unlock() }
}

// MARK: - Monitor

/// Everything the transfer-details window shows: speed now, average and peak, a speed history for the
/// graph, elapsed and remaining time. Fed with the job's progress snapshots; all on the main thread.
final class TransferMonitor: ObservableObject {
    enum State: Equatable { case running, finished, cancelled, failed }

    struct Sample: Identifiable {
        let id: Int
        let seconds: Double               // since the start, without paused time
        let bytesPerSecond: Double
    }

    let title: String                     // "Copying", "Uploading" …
    let from: String
    let to: String
    let startedAt: Date

    @Published private(set) var progress = TransferProgress()
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var speed: Double = 0
    @Published private(set) var peak: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var state: State = .running

    /// Set by whoever starts the job.
    var onCancel: () -> Void = {}
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}

    private var history: [(time: Date, bytes: Int64)] = []
    private var lastSample: Date
    private var nextID = 0
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    static let sampleInterval: TimeInterval = 0.5
    static let maxSamples = 600           // five minutes of history
    private static let speedWindow: TimeInterval = 3
    private static let estimateWindow: TimeInterval = 12

    init(title: String, from: String, to: String, now: Date = Date()) {
        self.title = title
        self.from = from
        self.to = to
        startedAt = now
        lastSample = now
        history = [(now, 0)]
    }

    // MARK: Feeding

    func update(_ new: TransferProgress, now: Date = Date()) {
        guard state == .running else { return }
        progress = new
        history.append((now, new.effectiveBytes))
        history.removeAll { now.timeIntervalSince($0.time) > Self.estimateWindow }

        let recent = history.filter { now.timeIntervalSince($0.time) <= Self.speedWindow }
        if let first = recent.first, let last = recent.last, last.time.timeIntervalSince(first.time) >= 0.25 {
            speed = max(0, Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time))
        }
        if isPaused, new.effectiveBytes == (history.dropLast().last?.bytes ?? -1) { speed = 0 }
        peak = max(peak, speed)

        if now.timeIntervalSince(lastSample) >= Self.sampleInterval {
            lastSample = now
            addSample(now: now)
        }
    }

    private func addSample(now: Date) {
        samples.append(Sample(id: nextID, seconds: activeElapsed(now: now), bytesPerSecond: speed))
        nextID += 1
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    func pause(now: Date = Date()) {
        guard state == .running, !isPaused else { return }
        isPaused = true
        pausedAt = now
        onPause()
    }

    func resume(now: Date = Date()) {
        guard isPaused else { return }
        if let pausedAt { pausedTotal += now.timeIntervalSince(pausedAt) }
        pausedAt = nil
        isPaused = false
        history = [(now, progress.effectiveBytes)]          // the pause must not drag the speed down
        onResume()
    }

    func cancel() {
        resume()
        onCancel()
    }

    func finish(_ result: State, now: Date = Date()) {
        guard state == .running else { return }
        if let pausedAt { pausedTotal += now.timeIntervalSince(pausedAt); self.pausedAt = nil }
        isPaused = false
        speed = 0
        state = result
    }

    // MARK: Numbers

    func activeElapsed(now: Date = Date()) -> TimeInterval {
        let paused = pausedTotal + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, now.timeIntervalSince(startedAt) - paused)
    }

    func averageSpeed(now: Date = Date()) -> Double {
        let elapsed = activeElapsed(now: now)
        return elapsed > 0.5 ? Double(progress.effectiveBytes) / elapsed : 0
    }

    /// Time left, from the rate of the last seconds (steadier than the instant speed). nil: unknown.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard state == .running, progress.bytesTotal > 0, !isPaused else { return nil }
        let left = progress.bytesTotal - progress.effectiveBytes
        guard left > 0 else { return 0 }
        guard let first = history.first, let last = history.last, last.time.timeIntervalSince(first.time) >= 1 else { return nil }
        let rate = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        return rate > 1 ? Double(left) / rate : nil
    }

    // MARK: Text

    static func speedText(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false       // "0 KB", not "Zero KB"
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// 18 → "0:18", 140 → "2:20", 3725 → "1:02:05".
    static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
