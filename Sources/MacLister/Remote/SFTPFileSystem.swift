import Foundation

// MARK: - Host keys

struct HostKeyInfo {
    let type: String          // "ED25519"
    let fingerprint: String   // "SHA256:…"
    let line: String          // known_hosts line
}

/// Trust on first use, with the user's explicit confirmation, in a known_hosts file of our own.
enum SFTPHostKeys {
    static var knownHostsURL: URL { AppSupport.directory.appendingPathComponent("known_hosts") }

    static func hostSpec(host: String, port: Int) -> String { port == 22 ? host : "[\(host)]:\(port)" }

    static func isKnown(host: String, port: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: knownHostsURL.path) else { return false }
        let output = try? ProcessRunner.run("/usr/bin/ssh-keygen", ["-F", hostSpec(host: host, port: port), "-f", knownHostsURL.path])
        return output?.status == 0 && !(output?.stdout.isEmpty ?? true)
    }

    /// Asks the server for its public keys (ssh-keyscan) and computes their fingerprints.
    static func fetch(host: String, port: Int) throws -> [HostKeyInfo] {
        let scan = try ProcessRunner.run("/usr/bin/ssh-keyscan", ["-T", "10", "-p", "\(port)", host])
        let lines = String(decoding: scan.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !lines.isEmpty else {
            let why = scan.stderr.lowercased()
            if why.contains("resolve") || why.contains("nodename") { throw RemoteError(message: "Cannot find the server “\(host)”") }
            if why.contains("timed out") { throw RemoteError(message: "The server did not answer in time") }
            // refused, reset, broken pipe: nothing is listening, or it is not an SSH server
            throw RemoteError(message: "Cannot connect to \(host):\(port): no SSH server answered")
        }
        var keys: [HostKeyInfo] = []
        for line in lines {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hostkey-\(UUID().uuidString)")
            try? (line + "\n").write(to: temporary, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result = try? ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", temporary.path])
            let text = String(decoding: result?.stdout ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let type = parts.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) } ?? "?"
            keys.append(HostKeyInfo(type: type, fingerprint: parts[1], line: line))
        }
        // The strongest algorithm first, it is the one worth showing prominently.
        let order = ["ED25519", "ECDSA", "RSA"]
        return keys.sorted { (order.firstIndex(of: $0.type) ?? 9) < (order.firstIndex(of: $1.type) ?? 9) }
    }

    static func trust(_ keys: [HostKeyInfo]) throws {
        try? FileManager.default.createDirectory(at: knownHostsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        try (existing + keys.map(\.line).joined(separator: "\n") + "\n").write(to: knownHostsURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - SFTP through /usr/bin/sftp

/// The system curl has no SFTP, so this drives OpenSSH's `sftp` in batch mode. One SSH connection is kept
/// open in the background (ControlMaster), so every operation after the first is fast and the password is
/// used only once. Passwords reach ssh through SSH_ASKPASS, never on a command line.
final class SFTPFileSystem: RemoteFileSystem {
    private let profile: ServerProfile
    private let secret: String
    private let sftp = "/usr/bin/sftp"

    /// Tests only: run a local sftp-server directly (`sftp -D`), without SSH, a network or a listener.
    static var testServerPath: String?

    init(profile: ServerProfile, secret: String) {
        self.profile = profile
        self.secret = secret
    }

    // MARK: Setup

    private var controlPath: String { "/tmp/mcl-\(getuid())-\(profile.id.uuidString.prefix(8)).sock" }
    private var destination: String { profile.user.isEmpty ? profile.host : "\(profile.user)@\(profile.host)" }

    private var askpassURL: URL {
        let url = AppSupport.directory.appendingPathComponent("askpass.sh")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "#!/bin/sh\nprintf '%s\\n' \"$MACLISTER_SECRET\"\n".write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return url
    }

    /// Options shared by the connection that logs in and by every sftp call that rides on it.
    private var trustOptions: [String] {
        ["-o", "UserKnownHostsFile=\(SFTPHostKeys.knownHostsURL.path)", "-o", "StrictHostKeyChecking=yes",
         "-o", "HashKnownHosts=no", "-o", "LogLevel=ERROR"]
    }

    /// The master connection: plain `ssh -N`, because `sftp -b` forces BatchMode and so can never ask for a
    /// password or key passphrase (not even through SSH_ASKPASS). It logs in once and stays open for a while.
    private var masterArguments: [String] {
        var arguments = ["-N", "-p", "\(profile.port)",
                         "-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=120",
                         "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"] + trustOptions
        if let key = profile.keyPath, !key.isEmpty { arguments += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        arguments += secret.isEmpty ? ["-o", "BatchMode=yes"] : ["-o", "NumberOfPasswordPrompts=1"]   // no secret: agent or default keys
        return arguments + [destination]
    }

    private var environment: [String: String] {
        var env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = agent }
        if !secret.isEmpty {
            env["SSH_ASKPASS"] = askpassURL.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = "maclister:0"                // older ssh versions want DISPLAY before using askpass
            env["MACLISTER_SECRET"] = secret
        }
        return env
    }

    /// Asks for confirmation the first time a server is seen; later connections must match the stored key.
    func verifyHostKey(confirm: ([HostKeyInfo]) -> Bool) throws {
        if SFTPHostKeys.isKnown(host: profile.host, port: profile.port) { return }
        let keys = try SFTPHostKeys.fetch(host: profile.host, port: profile.port)
        guard confirm(keys) else { throw RemoteError(message: "The server's host key was not trusted") }
        try SFTPHostKeys.trust(keys)
    }

    // MARK: Master connection

    private let masterLock = NSLock()

    /// Makes sure the logged-in connection exists (it ends after 120 idle seconds) and starts it when not.
    private func ensureMaster(cancel: CancelToken?) throws {
        if Self.testServerPath != nil { return }
        masterLock.lock()
        defer { masterLock.unlock() }
        let check = try? ProcessRunner.run("/usr/bin/ssh", ["-O", "check", "-o", "ControlPath=\(controlPath)", destination])
        if check?.status == 0 { return }
        try? FileManager.default.removeItem(atPath: controlPath)       // a stale socket would stop the new master from starting
        let output = try ProcessRunner.run("/usr/bin/ssh", masterArguments, environment: environment, cancel: cancel)
        guard output.status == 0 else { throw Self.error(stderr: output.stderr, status: output.status, profile: profile) }
    }

    // MARK: Running sftp

    @discardableResult
    private func batch(_ commands: [String], cancel: CancelToken? = nil) throws -> String {
        for command in commands where command.contains("\n") || command.contains("\r") {
            throw RemoteError(message: "Invalid character in a file name")
        }
        try ensureMaster(cancel: cancel)
        let arguments = Self.testServerPath.map { ["-D", $0, "-b", "-"] }
            ?? (["-P", "\(profile.port)", "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)"] + trustOptions + ["-b", "-", destination])
        let output = try ProcessRunner.run(sftp, arguments, stdin: Data((commands.joined(separator: "\n") + "\n").utf8),
                                           environment: environment, cancel: cancel)
        guard output.status == 0 else { throw Self.error(stderr: output.stderr, status: output.status, profile: profile) }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    static func error(stderr: String, status: Int32, profile: ServerProfile) -> RemoteError {
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        let lower = stderr.lowercased()
        if lower.contains("permission denied (") || lower.contains("authentication failed") {
            return RemoteError(message: "Login denied: check the user name, password or key")
        }
        if lower.contains("host key verification failed") || lower.contains("identification has changed") {
            return RemoteError(message: "The server's host key does not match the one you trusted. This may be an attack; remove it from known_hosts only if the server was reinstalled")
        }
        if lower.contains("connection refused") { return RemoteError(message: "Cannot connect to \(profile.host):\(profile.port)") }
        if lower.contains("could not resolve hostname") { return RemoteError(message: "Cannot find the server “\(profile.host)”") }
        if lower.contains("timed out") { return RemoteError(message: "The server did not answer in time") }
        if lower.contains("no such file") { return RemoteError(message: "The file or folder was not found") }
        if lower.contains("permission denied") { return RemoteError(message: "Access denied") }
        return RemoteError(message: last.isEmpty ? "sftp failed (exit \(status))" : last)
    }

    // MARK: Wildcards in names
    //
    // sftp expands * ? [ ] { } in the paths of ls, get, put (local side) and rm. No escaping survives that
    // expansion (tested: backslashes are kept in the name), so a name such as "star*.txt" would also match
    // "starfish.txt". Instead of guessing, every such name is checked against the real folder listing first.

    struct AmbiguousName: Error { let component: String; let others: [String]; let isLast: Bool }

    private static let wildcardCharacters = CharacterSet(charactersIn: "*?[]{}\\")

    private func hasWildcard(_ text: String) -> Bool { text.rangeOfCharacter(from: Self.wildcardCharacters) != nil }

    /// Throws when a component of `path` would be read by sftp as a pattern that matches something else.
    private func ensureLiteral(_ path: String) throws {
        var parent = "/"
        for part in path.split(separator: "/") {
            let component = String(part)
            defer { parent = RemoteURL.join(parent, component) }
            guard hasWildcard(component) else { continue }
            if component.contains("{") || component.contains("}") {
                throw RemoteError(message: "A name with { or } cannot be handled safely over SFTP: “\(component)”")
            }
            let siblings = try listUnchecked(parent).map(\.name)
            let matches = siblings.filter { fnmatch(component, $0, 0) == 0 }
            if !matches.isEmpty && matches != [component] {
                let isLast = path.hasSuffix(component) && RemoteURL.join(parent, component) == path
                throw AmbiguousName(component: component, others: matches.filter { $0 != component }, isLast: isLast)
            }
        }
    }

    private func explain(_ error: Error) -> Error {
        guard let ambiguous = error as? AmbiguousName else { return error }
        let others = ambiguous.others.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return RemoteError(message: "“\(ambiguous.component)” contains wildcard characters that also match \(others). MacLister will not risk touching the wrong file")
    }

    /// Double quotes for sftp's own argument parser.
    private func q(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: RemoteFileSystem

    func homeDirectory() throws -> String {
        let output = try batch(["pwd"])
        for line in output.split(whereSeparator: \.isNewline) {
            if let colon = line.range(of: "directory: ") { return String(line[colon.upperBound...]) }
        }
        return "/"
    }

    func list(_ path: String) throws -> [RemoteEntry] {
        do { try ensureLiteral(path) } catch { throw explain(error) }
        return try listUnchecked(path)
    }

    /// `ls -la`: OpenSSH prints the full path as the name and "?" as the link count.
    private func listUnchecked(_ path: String) throws -> [RemoteEntry] {
        let output = try batch(["ls -la \(q(path))"])
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("sftp>") }.joined(separator: "\n")
        return RemoteListParser.parse(lines).compactMap { entry in
            var entry = entry
            entry.name = (entry.name as NSString).lastPathComponent
            return entry.name == "." || entry.name == ".." || entry.name.isEmpty ? nil : entry
        }
    }

    func download(_ path: String, to local: URL, cancel: CancelToken?) throws {
        do {
            try ensureLiteral(path)
            try batch(["get \(q(path)) \(q(local.path))"], cancel: cancel)
        } catch {
            try? FileManager.default.removeItem(at: local)
            throw explain(error)
        }
    }

    func upload(_ local: URL, to path: String, cancel: CancelToken?) throws {
        var source = local
        var cleanup: URL?
        if hasWildcard(local.path) {
            // the local side of put is expanded too: upload through a link with a plain name
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcl-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            source = folder.appendingPathComponent("file")
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: local)
            cleanup = folder
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        try batch(["put \(q(source.path)) \(q(path))"], cancel: cancel)
    }

    func makeDirectory(_ path: String) throws { try batch(["mkdir \(q(path))"]) }

    func remove(_ path: String, isDirectory: Bool) throws {
        if isDirectory { try batch(["rmdir \(q(path))"]); return }
        do {
            try ensureLiteral(path)
            try batch(["rm \(q(path))"])
        } catch let ambiguous as AmbiguousName where ambiguous.isLast {
            // rename does not expand wildcards: give the file a plain name first, then delete that
            let temporary = RemoteURL.join(RemoteURL.parentPath(of: path), ".maclister-delete-\(UUID().uuidString)")
            try batch(["rename \(q(path)) \(q(temporary))", "rm \(q(temporary))"])
        } catch {
            throw explain(error)
        }
    }

    func rename(_ from: String, to: String) throws { try batch(["rename \(q(from)) \(q(to))"]) }

    func close() {
        _ = try? ProcessRunner.run("/usr/bin/ssh", ["-O", "exit", "-o", "ControlPath=\(controlPath)", destination])
    }
}
