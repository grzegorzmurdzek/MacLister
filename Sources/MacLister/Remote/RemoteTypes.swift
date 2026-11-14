import Foundation

// MARK: - Protocols and servers

/// URL schemes used for remote listers. `ftpes` is the informal scheme for explicit FTPS (AUTH TLS).
enum RemoteScheme: String, CaseIterable, Codable, Identifiable {
    case ftp, ftpes, ftps, sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ftp: return "FTP"
        case .ftpes: return "FTPS (explicit TLS)"
        case .ftps: return "FTPS (implicit TLS)"
        case .sftp: return "SFTP (SSH)"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ftp, .ftpes: return 21
        case .ftps: return 990
        case .sftp: return 22
        }
    }

    var isEncrypted: Bool { self != .ftp }
}

/// A saved or ad-hoc server. The password is never stored here (see SecretStore).
struct ServerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var scheme: RemoteScheme = .sftp
    var host = ""
    var port = 22
    var user = ""
    var keyPath: String?                     // SFTP: private key file
    var acceptInvalidCertificate = false     // FTPS only: skip certificate validation (unsafe)

    var displayName: String {
        name.isEmpty ? (user.isEmpty ? host : "\(user)@\(host)") : name
    }

    /// Identifies the connection behind a remote URL.
    var sessionKey: String { RemoteURL.sessionKey(scheme: scheme, user: user, host: host, port: port) }

    func url(path: String) -> URL { RemoteURL.make(self, path: path) }
}

struct RemoteEntry: Equatable {
    var name: String
    var isDirectory: Bool
    var isSymlink = false
    var size: Int64?
    var modified: Date?
    var permissions: Int?
}

struct RemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static let cancelled = RemoteError(message: "Cancelled")
}

/// Lets the UI stop a running transfer: the file system registers a closure that ends its process.
final class CancelToken {
    private let lock = NSLock()
    private var flag = false
    private var terminator: (() -> Void)?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }

    func cancel() {
        lock.lock()
        flag = true
        let action = terminator
        lock.unlock()
        action?()
    }

    func onCancel(_ action: (() -> Void)?) {
        lock.lock()
        terminator = action
        let already = flag
        lock.unlock()
        if already { action?() }
    }
}

/// Blocking operations on one server. Always call them from a background queue.
/// Paths are absolute and start with "/". For FTP "/" is the login folder.
protocol RemoteFileSystem: AnyObject {
    func list(_ path: String) throws -> [RemoteEntry]
    func download(_ path: String, to local: URL, cancel: CancelToken?) throws
    func upload(_ local: URL, to path: String, cancel: CancelToken?) throws
    func makeDirectory(_ path: String) throws
    func remove(_ path: String, isDirectory: Bool) throws
    func rename(_ from: String, to: String) throws
    /// Folder shown right after connecting.
    func homeDirectory() throws -> String
    func close()
}

// MARK: - URLs of remote locations

enum RemoteURL {
    static func sessionKey(scheme: RemoteScheme, user: String, host: String, port: Int) -> String {
        "\(scheme.rawValue)://\(user)@\(host):\(port)"
    }

    /// nil for file URLs and for schemes we do not know.
    static func sessionKey(of url: URL) -> String? {
        guard let scheme = url.scheme.flatMap(RemoteScheme.init(rawValue:)), let host = url.host else { return nil }
        return sessionKey(scheme: scheme, user: url.user ?? "", host: host, port: url.port ?? scheme.defaultPort)
    }

    static func isRemote(_ url: URL) -> Bool { !url.isFileURL && sessionKey(of: url) != nil }

    /// Percent-encodes every component of a path ("/a b/c" → "/a%20b/c").
    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
    }

    static func make(_ profile: ServerProfile, path: String) -> URL {
        var components = URLComponents()
        components.scheme = profile.scheme.rawValue
        components.user = profile.user.isEmpty ? nil : profile.user
        components.host = profile.host
        components.port = profile.port
        components.percentEncodedPath = encode(path)
        return components.url ?? URL(string: "\(profile.scheme.rawValue)://\(profile.host)/")!
    }

    /// Absolute remote path of a URL ("/" when empty).
    static func path(of url: URL) -> String {
        let path = url.path
        return path.isEmpty ? "/" : path
    }

    /// The same server with another path; ".." and "." are resolved.
    static func with(path: String, on url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.percentEncodedPath = encode((path as NSString).standardizingPath)
        return components.url ?? url
    }

    /// No trailing slash, no "..": equal locations compare equal.
    static func normalized(_ url: URL) -> URL { with(path: path(of: url), on: url) }

    static func child(of url: URL, named name: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let base = components.percentEncodedPath
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        components.percentEncodedPath = (base.hasSuffix("/") ? base : base + "/") + encoded
        return components.url ?? url
    }

    /// "ftp://me@host:21/dir/file" → "me@host"
    static func serverLabel(of url: URL) -> String {
        let host = url.host ?? ""
        return (url.user.map { "\($0)@" } ?? "") + host
    }

    static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}

// MARK: - Directory listings (the output of FTP LIST and sftp ls -l)

enum RemoteListParser {
    private static let unixWithGroup = try! NSRegularExpression(pattern:
        #"^([\-dlbcps])([r\-][w\-][xsStT\-][r\-][w\-][xsStT\-][r\-][w\-][xsStT\-])[+@.]?\s+(?:\d+|\?)\s+(\S+)\s+(\S+)\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$"#)
    private static let unixNoGroup = try! NSRegularExpression(pattern:
        #"^([\-dlbcps])([r\-][w\-][xsStT\-][r\-][w\-][xsStT\-][r\-][w\-][xsStT\-])[+@.]?\s+(?:\d+|\?)\s+(\S+)\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$"#)
    private static let dos = try! NSRegularExpression(pattern:
        #"^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*([AP]M)?\s+(<DIR>|\d+)\s+(.*)$"#)

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func parse(_ text: String, now: Date = Date()) -> [RemoteEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0), now: now) }
    }

    static func parseLine(_ rawLine: String, now: Date = Date()) -> RemoteEntry? {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if let entry = parseUnix(line, now: now) ?? parseDOS(line) {
            return entry.name == "." || entry.name == ".." ? nil : entry
        }
        return nil
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }

    private static func mode(from symbolic: String) -> Int {
        var value = 0
        for (i, c) in symbolic.enumerated() {
            let bit = 1 << (8 - i)
            switch i % 3 {
            case 0: if c == "r" { value |= bit }
            case 1: if c == "w" { value |= bit }
            default: if "xst".contains(c) { value |= bit }
            }
        }
        return value
    }

    private static func parseUnix(_ line: String, now: Date) -> RemoteEntry? {
        let range = NSRange(line.startIndex..., in: line)
        var type = "", perms = "", size = "", month = "", day = "", timeOrYear = "", rest = ""
        if let m = unixWithGroup.firstMatch(in: line, range: range) {
            type = group(m, 1, in: line); perms = group(m, 2, in: line); size = group(m, 5, in: line)
            month = group(m, 6, in: line); day = group(m, 7, in: line); timeOrYear = group(m, 8, in: line); rest = group(m, 9, in: line)
        } else if let m = unixNoGroup.firstMatch(in: line, range: range) {
            type = group(m, 1, in: line); perms = group(m, 2, in: line); size = group(m, 4, in: line)
            month = group(m, 5, in: line); day = group(m, 6, in: line); timeOrYear = group(m, 7, in: line); rest = group(m, 8, in: line)
        } else {
            return nil
        }
        var name = rest
        let isSymlink = type == "l"
        if isSymlink, let arrow = rest.range(of: " -> ") {      // FTP shows the target, OpenSSH's sftp does not
            name = String(rest[..<arrow.lowerBound])
        }
        return RemoteEntry(
            name: name, isDirectory: type == "d", isSymlink: isSymlink,
            size: type == "d" ? nil : Int64(size), modified: unixDate(month: month, day: day, timeOrYear: timeOrYear, now: now),
            permissions: mode(from: perms)
        )
    }

    /// "Nov 14 10:11" has no year: it is the current year, or last year if that would lie in the future.
    private static func unixDate(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        guard let monthIndex = months.firstIndex(of: month.lowercased()), let dayNumber = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var parts = DateComponents(month: monthIndex + 1, day: dayNumber)
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2 else { return nil }
            parts.hour = hm[0]; parts.minute = hm[1]
            parts.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: parts), date > now.addingTimeInterval(86_400) { parts.year = (parts.year ?? 0) - 1 }
        } else {
            parts.year = Int(timeOrYear)
        }
        return calendar.date(from: parts)
    }

    private static func parseDOS(_ line: String) -> RemoteEntry? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = dos.firstMatch(in: line, range: range) else { return nil }
        let month = Int(group(m, 1, in: line)) ?? 1, day = Int(group(m, 2, in: line)) ?? 1
        var year = Int(group(m, 3, in: line)) ?? 1970
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        var hour = Int(group(m, 4, in: line)) ?? 0
        let minute = Int(group(m, 5, in: line)) ?? 0
        let meridiem = group(m, 6, in: line)
        if meridiem == "PM", hour < 12 { hour += 12 }
        if meridiem == "AM", hour == 12 { hour = 0 }
        let sizeOrDir = group(m, 7, in: line)
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        return RemoteEntry(name: group(m, 8, in: line), isDirectory: sizeOrDir == "<DIR>",
                           size: Int64(sizeOrDir), modified: date, permissions: nil)
    }
}

// MARK: - Running helper programs

enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Runs a program without a shell, so arguments are never interpreted. `stdin` is written and closed.
    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil,
                    environment: [String: String]? = nil, cancel: CancelToken? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        if cancel?.isCancelled == true { throw RemoteError.cancelled }
        do { try process.run() } catch { throw RemoteError(message: "Cannot start \(executable): \(error.localizedDescription)") }
        cancel?.onCancel { if process.isRunning { process.terminate() } }

        // Drain both pipes concurrently so a chatty program can never block on a full pipe.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        group.wait()
        cancel?.onCancel(nil)
        if cancel?.isCancelled == true { throw RemoteError.cancelled }
        return Output(status: process.terminationStatus, stdout: outData,
                      stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
