import AppKit

/// Spring-loaded folders: hold a dragged file over a folder for a moment and the folder opens, so a file can be
/// carried several levels down in one drag. Drag updates arrive over and over while the pointer rests on a target;
/// this opens the target once the same one has been under the pointer for `delay` seconds.
final class SpringLoader {
    var delay: TimeInterval
    private var target: AnyHashable?
    private var since = Date.distantPast
    private var lastSeen = Date.distantPast
    private var fired = false
    private var action: (() -> Void)?
    private var timer: Timer?

    /// The drag updates are about ten times a second; a gap longer than this means the pointer has left.
    private static let staleAfter: TimeInterval = 0.6

    init(delay: TimeInterval = Settings.springLoadedDelay) { self.delay = delay }

    /// Called for every drag update over a folder; `open` runs once when the folder has been hovered long enough.
    func hover<Key: Hashable>(_ key: Key, open: @escaping () -> Void) {
        guard Settings.springLoadedFolders else { return }
        let now = Date()
        if target != AnyHashable(key) || now.timeIntervalSince(lastSeen) > Self.staleAfter {
            target = AnyHashable(key)
            since = now
            fired = false
        }
        lastSeen = now
        action = open
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    /// The pointer is over something that does not open (or the drag ended).
    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
        action = nil
        fired = false
    }

    var isWatching: Bool { timer != nil }

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastSeen) > Self.staleAfter { cancel(); return }
        // open only while updates are still coming in: a pointer that just left must not open the folder
        guard !fired, now.timeIntervalSince(since) >= delay, now.timeIntervalSince(lastSeen) <= 0.3 else { return }
        fired = true
        let open = action
        open?()
    }
}
