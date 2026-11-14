import Foundation
import CoreServices

/// Calls `onChange` (on the main queue) shortly after something inside one folder changed on disk:
/// files added, removed, renamed or modified. Built on FSEvents, in directory mode, which is cheap even
/// for big folders. Events for sub-folders are ignored; a lister only shows direct children.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let resolvedPath: String
    private let onChange: () -> Void

    init(directory: URL, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        // FSEvents reports canonical paths (/private/var…); the lister may know the symlinked form (/var…).
        // (URL.resolvingSymlinksInPath would turn /private/var back into /var, so use realpath.)
        resolvedPath = Self.canonicalPath(directory)
        self.onChange = onChange

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(paths.prefix(count)))
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [resolvedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    static func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(url.path, &buffer) != nil ? String(cString: buffer) : url.path
    }

    private func handle(_ paths: [String]) {
        // Directory mode reports the folder in which something changed; only our own folder matters.
        let relevant = paths.contains { path in
            let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            return clean == resolvedPath
        }
        if relevant { onChange() }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// "420 GB free of 994 GB (58% used)" for the volume that holds a folder.
enum VolumeInfo {
    /// Pictures for the README leave the disk figures out.
    static var hidden = false

    static func summary(for url: URL) -> String? {
        if hidden { return nil }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let used = max(0, min(100, Int((Double(Int64(total) - free) / Double(total) * 100).rounded())))
        return tr("%@ free of %@ (%d%% used)", formatter.string(fromByteCount: free), formatter.string(fromByteCount: Int64(total)), Int(used))
    }
}
