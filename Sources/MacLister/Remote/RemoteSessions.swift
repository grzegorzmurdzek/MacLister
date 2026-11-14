import Foundation
import Security

// MARK: - Passwords in the Keychain

enum SecretStore {
    private static let service = "MacLister"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// `allowUI: false` makes a request that would need a Keychain prompt fail instead (used by tests).
    static func get(_ account: String, allowUI: Bool = true) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ secret: String, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(secret.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) { SecItemDelete(baseQuery(account) as CFDictionary) }
}

// MARK: - Saved servers

/// servers.json: the saved servers without their passwords.
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [ServerProfile] = []
    private var file: URL { AppSupport.directory.appendingPathComponent("servers.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            servers = saved
        }
    }

    /// Adds the server, or replaces the one with the same id.
    func save(_ profile: ServerProfile) {
        if let index = servers.firstIndex(where: { $0.id == profile.id }) { servers[index] = profile } else { servers.append(profile) }
        persist()
    }

    func remove(_ profile: ServerProfile) {
        servers.removeAll { $0.id == profile.id }
        SecretStore.delete(profile.id.uuidString)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(servers).write(to: file, options: .atomic)
    }
}

// MARK: - Live connections

final class RemoteSession {
    let profile: ServerProfile
    let fs: RemoteFileSystem
    let home: String

    init(profile: ServerProfile, fs: RemoteFileSystem, home: String) {
        self.profile = profile
        self.fs = fs
        self.home = home
    }

    func url(path: String) -> URL { profile.url(path: path) }
}

/// The open connections, found again from the URL of any remote location.
final class RemoteSessions {
    static let shared = RemoteSessions()

    private let lock = NSLock()
    private var sessions: [String: RemoteSession] = [:]

    func session(for url: URL) -> RemoteSession? {
        guard let key = RemoteURL.sessionKey(of: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sessions[key]
    }

    var all: [RemoteSession] { lock.lock(); defer { lock.unlock() }; return Array(sessions.values) }

    /// Connects in the background and verifies the login by reading the home folder. `confirmHostKey` is
    /// called (on that background queue, may block) the first time an SFTP server is seen.
    func connect(profile: ServerProfile, secret: String,
                 confirmHostKey: @escaping ([HostKeyInfo]) -> Bool,
                 completion: @escaping (Result<RemoteSession, RemoteError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fs: RemoteFileSystem
                if profile.scheme == .sftp {
                    let sftp = SFTPFileSystem(profile: profile, secret: secret)
                    try sftp.verifyHostKey(confirm: confirmHostKey)
                    fs = sftp
                } else {
                    fs = FTPFileSystem(profile: profile, password: secret)
                }
                let session = RemoteSession(profile: profile, fs: fs, home: try fs.homeDirectory())
                self.register(session)
                DispatchQueue.main.async { completion(.success(session)) }
            } catch {
                let remote = error as? RemoteError ?? RemoteError(message: error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(remote)) }
            }
        }
    }

    func register(_ session: RemoteSession) {
        lock.lock()
        let previous = sessions[session.profile.sessionKey]
        sessions[session.profile.sessionKey] = session
        lock.unlock()
        previous?.fs.close()
    }

    func disconnect(_ url: URL) {
        guard let key = RemoteURL.sessionKey(of: url) else { return }
        lock.lock()
        let session = sessions.removeValue(forKey: key)
        lock.unlock()
        session?.fs.close()
    }

    /// Ends every connection (called when the app quits).
    func closeAll() {
        lock.lock()
        let open = Array(sessions.values)
        sessions = [:]
        lock.unlock()
        open.forEach { $0.fs.close() }
    }
}

// MARK: - Downloaded copies (open, Quick Look)

enum RemoteCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacLister/remote", isDirectory: true)
    }

    /// Where a remote file is kept locally; the remote folder structure is mirrored so names stay intact.
    static func localURL(for remote: URL) -> URL {
        var url = directory.appendingPathComponent(RemoteURL.sessionKey(of: remote)?.replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: "/", with: "_") ?? "unknown", isDirectory: true)
        for part in RemoteURL.path(of: remote).split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    static func purge(olderThan age: TimeInterval = 7 * 86_400) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, let date = values?.contentModificationDate, Date().timeIntervalSince(date) > age {
                try? fm.removeItem(at: url)
            }
        }
    }
}
