import AppKit
import QuickLookThumbnailing

/// Generates and caches Quick Look thumbnails for files shown in icon view.
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func shouldPreview(_ file: FileItem) -> Bool {
        Settings.showIconPreviews
            && file.url.isFileURL
            && !file.isDirectory
            && ArchiveBrowser.shared.location(of: file.url) == nil
    }

    private func cacheKey(for file: FileItem, iconSize: CGFloat) -> NSString {
        let stamp = file.modified?.timeIntervalSinceReferenceDate ?? 0
        let size = file.size ?? -1
        return "\(file.url.path)|\(Int(iconSize))|\(stamp)|\(size)" as NSString
    }

    func cached(for file: FileItem, iconSize: CGFloat) -> NSImage? {
        guard shouldPreview(file) else { return nil }
        return cache.object(forKey: cacheKey(for: file, iconSize: iconSize))
    }

    func request(for file: FileItem, iconSize: CGFloat, scale: CGFloat, completion: @escaping (NSImage?) -> Void) {
        guard shouldPreview(file) else { completion(nil); return }
        let key = cacheKey(for: file, iconSize: iconSize)
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        let targetSize = CGSize(width: iconSize, height: iconSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: targetSize,
            scale: max(scale, 1),
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            if let image { self?.cache.setObject(image, forKey: key) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
