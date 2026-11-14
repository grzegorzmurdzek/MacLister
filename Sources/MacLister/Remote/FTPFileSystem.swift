import Foundation

/// FTP and FTPS through the system's /usr/bin/curl (libcurl in the SDK has FTP/FTPS but no SFTP).
/// Host, user and password go to curl through a config file on stdin, never on the command line,
/// and arguments are passed without a shell.
final class FTPFileSystem: RemoteFileSystem {
    private let profile: ServerProfile
    private let password: String
    private let curl = "/usr/bin/curl"

    init(profile: ServerProfile, password: String) {
        self.profile = profile
        self.password = password
    }

    // MARK: Building a curl call

    private func urlString(path: String, directory: Bool) -> String {
        let scheme = profile.scheme == .ftps ? "ftps" : "ftp"
        let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        var encoded = RemoteURL.encode(path)
        if directory, !encoded.hasSuffix("/") { encoded += "/" }
        return "\(scheme)://\(host):\(profile.port)\(encoded)"
    }

    private func quote(_ text: String) throws -> String {
        guard !text.contains("\n"), !text.contains("\r") else { throw RemoteError(message: "Invalid character in the server settings") }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    private func run(path: String, directory: Bool, extra: [String] = [], cancel: CancelToken? = nil) throws -> Data {
        var config = "url = \(try quote(urlString(path: path, directory: directory)))\n"
        if !profile.user.isEmpty { config += "user = \(try quote("\(profile.user):\(password)"))\n" }

        var arguments = ["--silent", "--show-error", "--connect-timeout", "15",
                         "-y", "60", "-Y", "1",              // give up when nothing moves for a minute
                         "--ftp-skip-pasv-ip"]               // use the control connection's address for data (NAT)
        if profile.scheme == .ftpes { arguments.append("--ssl-reqd") }
        if profile.acceptInvalidCertificate, profile.scheme != .ftp { arguments.append("-k") }
        arguments += extra
        arguments += ["-K", "-"]

        let output = try ProcessRunner.run(curl, arguments, stdin: Data(config.utf8), cancel: cancel)
        guard output.status == 0 else { throw Self.error(status: output.status, stderr: output.stderr, profile: profile) }
        return output.stdout
    }

    static func error(status: Int32, stderr: String, profile: ServerProfile) -> RemoteError {
        let detail = stderr.split(separator: "\n").last.map(String.init) ?? ""
        switch status {
        case 6: return RemoteError(message: "Cannot find the server “\(profile.host)”")
        case 7: return RemoteError(message: "Cannot connect to \(profile.host):\(profile.port)")
        case 9: return RemoteError(message: "The folder does not exist or access is denied")
        case 19, 78: return RemoteError(message: "The file or folder was not found")
        case 28: return RemoteError(message: "The server did not answer in time")
        case 60: return RemoteError(message: "The server's certificate is not trusted. Tick “Accept untrusted certificate” only if you know the server")
        case 35, 51, 53, 58, 59, 64, 66, 77, 80, 82, 83, 90, 91:
            return RemoteError(message: "TLS problem: \(detail)")
        case 67: return RemoteError(message: "Login denied: check the user name and password")
        case 21, 25: return RemoteError(message: "The server refused the command: \(detail)")
        default: return RemoteError(message: detail.isEmpty ? "curl failed (exit \(status))" : detail)
        }
    }

    // MARK: RemoteFileSystem

    func list(_ path: String) throws -> [RemoteEntry] {
        let data = try run(path: path, directory: true)
        return RemoteListParser.parse(String(decoding: data, as: UTF8.self))
    }

    func download(_ path: String, to local: URL, cancel: CancelToken?) throws {
        do {
            try run(path: path, directory: false, extra: ["-o", local.path], cancel: cancel)
        } catch {
            try? FileManager.default.removeItem(at: local)      // never leave a partial file behind
            throw error
        }
    }

    func upload(_ local: URL, to path: String, cancel: CancelToken?) throws {
        try run(path: path, directory: false, extra: ["-T", local.path, "--ftp-create-dirs"], cancel: cancel)
    }

    /// Commands are sent before curl changes directory, so paths are relative to the login folder.
    private func quoteCommands(_ commands: [String]) throws {
        var extra = ["-o", "/dev/null"]
        for command in commands { extra += ["-Q", command] }
        try run(path: "/", directory: true, extra: extra)
    }

    private func relative(_ path: String) -> String { String(path.drop(while: { $0 == "/" })) }

    func makeDirectory(_ path: String) throws { try quoteCommands(["MKD \(relative(path))"]) }

    func remove(_ path: String, isDirectory: Bool) throws {
        try quoteCommands([(isDirectory ? "RMD " : "DELE ") + relative(path)])
    }

    func rename(_ from: String, to: String) throws {
        try quoteCommands(["RNFR \(relative(from))", "RNTO \(relative(to))"])
    }

    func homeDirectory() throws -> String {
        _ = try list("/")          // also proves that the login works
        return "/"
    }

    func close() {}
}
