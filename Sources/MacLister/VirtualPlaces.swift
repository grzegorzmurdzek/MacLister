import AppKit
import Network

/// Places in the Go menu that are lists, not folders: files opened recently, and what is shared on the
/// network, and the results of a search. A lister showing one has the address maclister://recents, maclister://shared
/// or maclister://find?….
enum VirtualPlace: String, CaseIterable {
    case recents, shared, find

    static let scheme = "maclister"

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    var title: String {
        switch self {
        case .recents: return tr("Recents")
        case .shared: return tr("Shared")
        case .find: return tr("Find")
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
