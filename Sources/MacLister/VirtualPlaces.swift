import AppKit
import Network

/// Places in the Go menu that are lists, not folders: files opened recently, and what is shared on the
/// network, and the results of a search. A lister showing one has the address maclister://recents, maclister://shared
/// or maclister://find?…; maclister://devices lists the disks (volumes) mounted on this Mac, as the device list of Directory Opus did.
enum VirtualPlace: String, CaseIterable {
    case recents, shared, find, devices

    static let scheme = "maclister"

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    var title: String {
        switch self {
        case .recents: return tr("Recents")
        case .shared: return tr("Shared")
        case .find: return tr("Find")
        case .devices: return tr("Devices and Places")
        }
    }

    /// Name of the list at `url`: a search is called after what it looks for.
    static func title(for url: URL) -> String? {
        guard let place = place(for: url) else { return nil }
        if place == .find, let query = FindQuery(url: url) { return query.title }
        return place.title
    }

    var symbol: String {
        switch self {
        case .recents: return "clock"
        case .shared: return "network"
        case .find: return "magnifyingglass"
        case .devices: return "externaldrive"
        }
    }

    static func place(for url: URL) -> VirtualPlace? {
        url.scheme == scheme ? VirtualPlace(rawValue: url.host ?? "") : nil
    }
}

/// A row of the Shared list that is not a folder: a saved server or a computer found on the network.
enum SharedRow {
    case server(UUID)
    case computer(name: String, types: [String])

    static func serverURL(_ id: UUID) -> URL { URL(string: "\(VirtualPlace.scheme)://server/\(id.uuidString)")! }

    static func computerURL(name: String, types: [String]) -> URL {
        var parts = URLComponents()
        parts.scheme = VirtualPlace.scheme
        parts.host = "computer"
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "types", value: types.joined(separator: ","))]
        return parts.url!
    }

    static func parse(_ url: URL) -> SharedRow? {
        guard url.scheme == VirtualPlace.scheme else { return nil }
        switch url.host {
        case "server":
            return UUID(uuidString: url.lastPathComponent).map { .server($0) }
        case "computer":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let name = items.first(where: { $0.name == "name" })?.value else { return nil }
            let types = (items.first(where: { $0.name == "types" })?.value ?? "").split(separator: ",").map(String.init)
            return .computer(name: name, types: types)
        default:
            return nil
        }
    }
}

// MARK: - Recents

/// Files opened in the last weeks, from Spotlight's "last used" date (what Finder's Recents shows).
final class RecentFiles: NSObject {
    struct Seed {
        let url: URL
        let lastUsed: Date
    }

    private static var running: Set<RecentFiles> = []
    private let query = NSMetadataQuery()
    private var completion: (([Seed]) -> Void)?

    /// `completion` runs on the main queue, once.
    /// Tests replace the Spotlight search with a fixed answer.
    static var override: ((@escaping ([Seed]) -> Void) -> Void)?

    static func fetch(days: Int = 30, limit: Int = 300, completion: @escaping ([Seed]) -> Void) {
        if let override { override { seeds in DispatchQueue.main.async { completion(seeds) } }; return }
        let job = RecentFiles()
        running.insert(job)
        job.start(days: days, limit: limit) { seeds in
            running.remove(job)
            completion(seeds)
        }
    }

    private func start(days: Int, limit: Int, completion: @escaping ([Seed]) -> Void) {
        self.completion = completion
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        query.predicate = NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, cutoff as NSDate)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(self, selector: #selector(finished), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(limit: limit) }   // never wait for ever
        self.limit = limit
    }

    private var limit = 300

    @objc private func finished() { finish(limit: limit) }

    private func finish(limit: Int) {
        guard let completion else { return }
        self.completion = nil
        query.disableUpdates()
        var seeds: [Seed] = []
        let fm = FileManager.default
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let date = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date else { continue }
            if let seed = Self.accept(path: path, date: date, fileManager: fm) { seeds.append(seed) }
            if seeds.count >= limit { break }
        }
        query.stop()
        NotificationCenter.default.removeObserver(self)
        DispatchQueue.main.async { completion(seeds.sorted { $0.lastUsed > $1.lastUsed }) }
    }

    /// Documents only: no folders, applications, hidden files or things inside ~/Library.
    static func accept(path: String, date: Date, fileManager fm: FileManager = .default) -> Seed? {
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) || path.contains("/Library/") { return nil }
        if path.hasSuffix(".app") || path.contains(".app/") { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return Seed(url: URL(fileURLWithPath: path), lastUsed: date)
    }
}

// MARK: - Devices

/// The disks mounted on this Mac: the startup disk, internal and external drives, disk images and network volumes.
/// A row is the volume itself (a folder: opening it shows its files); the size is the capacity of the disk, and the
/// Used, Free and Usage columns say how much of it is taken.
/// Below the disks come the folders you go to most (Home, Desktop …), which Directory Opus kept in the same list as its assigns.
enum DeviceList {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeLocalizedFormatDescriptionKey,
    ]

    /// Tests give a fixed set of volumes instead of the ones mounted.
    static var override: [URL]?

    static func mountedVolumes() -> [URL] {
        if let override { return override }
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    }

    /// Calls `changed` (on the main queue) when a disk is mounted, unmounted or renamed.
    static func observeChanges(_ changed: @escaping () -> Void) -> [NSObjectProtocol] {
        [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in changed() }
        }
    }

    static func stopObserving(_ observers: [NSObjectProtocol]) {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// "Internal disk", "External disk" or "Network volume".
    static func kindName(local: Bool, internal isInternal: Bool?, removable: Bool, ejectable: Bool) -> String {
        if !local { return tr("Network volume") }
        if removable || ejectable || isInternal == false { return tr("External disk") }
        return tr("Internal disk")
    }

    /// The usual folders of this Mac, one row each (they are not disks, so they have no size).
    static func placeRows() -> [FileItem] {
        let fm = FileManager.default
        func user(_ directory: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: directory, in: .userDomainMask).first }
        let places: [(String, URL?)] = [(tr("Home"), fm.homeDirectoryForCurrentUser), (tr("Desktop"), user(.desktopDirectory)),
                                        (tr("Documents"), user(.documentDirectory)), (tr("Downloads"), user(.downloadsDirectory)),
                                        (tr("Applications"), URL(fileURLWithPath: "/Applications"))]
        return places.compactMap { title, url in
            guard let url, fm.fileExists(atPath: url.path) else { return nil }
            var item = FileItem(url: url, name: title, isDirectory: true, isPackage: false, isHidden: false, size: nil, modified: nil)
            item.kind = tr("Place")
            return item
        }
    }

    /// Rows of the disks, unsorted.
    static func rows(volumes: [URL] = DeviceList.mountedVolumes()) -> [FileItem] {
        return volumes.map { volume in
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? FileManager.default.displayName(atPath: volume.path)
            var item = FileItem(url: volume, name: name, isDirectory: true, isPackage: false, isHidden: false,
                                size: values?.volumeTotalCapacity.map(Int64.init), modified: nil)
            let kind = kindName(local: values?.volumeIsLocal ?? true, internal: values?.volumeIsInternal,
                                removable: values?.volumeIsRemovable ?? false, ejectable: values?.volumeIsEjectable ?? false)
            // free the way Finder counts it: what is empty plus what macOS gives back when it is needed
            let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
            if let total = item.size, total > 0, let free {
                item.free = min(max(free, 0), total)
                item.used = total - (item.free ?? 0)
            }
            var parts = [kind]
            if let format = values?.volumeLocalizedFormatDescription { parts.append(format) }
            item.kind = parts.joined(separator: " · ")
            return item
        }
    }
}

// MARK: - Usage column

/// A thin bar for how full a disk is: blue, orange from 75 %, red from 90 %.
final class UsageBarView: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        guard let fraction, fraction > 0 else { return }
        var fill = bounds
        fill.size.width = max(bounds.height, bounds.width * fraction)
        (fraction >= 0.9 ? NSColor.systemRed : fraction >= 0.75 ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// The Usage cell of the Devices list: the bar and the percentage.
final class UsageCell: NSTableCellView {
    private let bar = UsageBarView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        for view in [bar, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = label
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.widthAnchor.constraint(equalToConstant: 38),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            bar.heightAnchor.constraint(equalToConstant: 8),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(fraction: Double?, text: String) {
        bar.fraction = fraction
        bar.isHidden = fraction == nil
        label.stringValue = text
    }
}

// MARK: - Shared

extension Notification.Name {
    static let sharedPlacesChanged = Notification.Name("MacListerSharedPlacesChanged")
}

/// What is shared with this Mac: mounted network volumes, the servers saved in MacLister, and computers
/// that announce file sharing on the local network (Bonjour: SMB, AFP, SFTP, FTP).
final class SharedPlaces {
    static let shared = SharedPlaces()

    struct Computer: Equatable {
        let name: String
        var types: [String]
    }

    /// Tests switch the network search off (it would ask for Local Network access).
    static var browsingEnabled = true

    static let serviceTypes = ["_smb._tcp", "_afpovertcp._tcp", "_sftp-ssh._tcp", "_ftp._tcp"]

    private(set) var computers: [Computer] = []
    private var browsers: [NWBrowser] = []
    private var found: [String: Set<String>] = [:]          // service type → computer names

    /// Starts looking for computers (once). The first call asks macOS for Local Network access.
    func start() {
        guard Self.browsingEnabled, browsers.isEmpty else { return }
        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names = results.compactMap { result -> String? in
                    if case let .service(name, _, _, _) = result.endpoint { return name }
                    return nil
                }
                DispatchQueue.main.async { self?.update(type: type, names: Set(names)) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }

    func update(type: String, names: Set<String>) {
        found[type] = names
        let own = Host.current().localizedName
        var table: [String: [String]] = [:]
        for serviceType in Self.serviceTypes {                // keep the preferred protocol first
            for name in found[serviceType] ?? [] where name != own { table[name, default: []].append(serviceType) }
        }
        let updated = table.map { Computer(name: $0.key, types: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard updated != computers else { return }
        computers = updated
        NotificationCenter.default.post(name: .sharedPlacesChanged, object: nil)
    }

    static func networkVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).volumeIsLocal) == false }
    }

    static func protocolName(_ type: String) -> String {
        switch type {
        case "_smb._tcp": return "SMB"
        case "_afpovertcp._tcp": return "AFP"
        case "_sftp-ssh._tcp": return "SFTP"
        case "_ftp._tcp": return "FTP"
        default: return type
        }
    }

    /// Rows of the Shared list, unsorted.
    func rows(servers: [ServerProfile] = ServerStore.shared.servers, volumes: [URL] = SharedPlaces.networkVolumes()) -> [FileItem] {
        var items: [FileItem] = []
        for volume in volumes {
            var item = FileItem(url: volume, name: FileManager.default.displayName(atPath: volume.path), isDirectory: true,
                                isPackage: false, isHidden: false, size: nil, modified: nil)
            item.kind = tr("Network volume")
            items.append(item)
        }
        for server in servers {
            var item = FileItem(url: SharedRow.serverURL(server.id), name: server.displayName, isDirectory: false,
                                isPackage: false, isHidden: false, size: nil, modified: nil)
            item.kind = tr("Saved server (%@)", server.scheme.title)
            items.append(item)
        }
        for computer in computers {
            var item = FileItem(url: SharedRow.computerURL(name: computer.name, types: computer.types), name: computer.name,
                                isDirectory: false, isPackage: false, isHidden: false, size: nil, modified: nil)
            item.kind = tr("Computer on the network (%@)", computer.types.map(Self.protocolName).joined(separator: ", "))
            items.append(item)
        }
        return items
    }
}

/// Finds the address of a computer announced over Bonjour.
final class ServiceResolver: NSObject, NetServiceDelegate {
    private static var running: Set<ServiceResolver> = []
    private let service: NetService
    private var completion: ((_ host: String?, _ port: Int) -> Void)?

    static func resolve(name: String, type: String, completion: @escaping (_ host: String?, _ port: Int) -> Void) {
        let resolver = ServiceResolver(name: name, type: type, completion: completion)
        running.insert(resolver)
        resolver.service.resolve(withTimeout: 6)
    }

    private init(name: String, type: String, completion: @escaping (String?, Int) -> Void) {
        service = NetService(domain: "local.", type: type, name: name)
        self.completion = completion
        super.init()
        service.delegate = self
    }

    private func done(_ host: String?, _ port: Int) {
        completion?(host, port)
        completion = nil
        service.stop()
        Self.running.remove(self)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var host = sender.hostName ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        done(host.isEmpty ? nil : host, sender.port)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { done(nil, 0) }
}
