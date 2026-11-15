import Foundation
import Darwin

/// Reads archives with the system's libarchive (the library behind bsdtar), in this process: the list of what is
/// inside comes without unpacking anything, and single files can be taken out one by one, the way the XAD library
/// does on the Amiga. libarchive ships with macOS but not its headers, so its functions are looked up by name.
final class ArchiveLibrary {
    typealias Handle = OpaquePointer
    typealias Entry = OpaquePointer

    static let shared: ArchiveLibrary? = ArchiveLibrary()

    let readNew: @convention(c) () -> Handle?
    let supportFilterAll: @convention(c) (Handle?) -> Int32
    let supportFormatAll: @convention(c) (Handle?) -> Int32
    let addPassphrase: @convention(c) (Handle?, UnsafePointer<CChar>?) -> Int32
    let openFilename: @convention(c) (Handle?, UnsafePointer<CChar>?, Int) -> Int32
    let nextHeader: @convention(c) (Handle?, UnsafeMutablePointer<Entry?>?) -> Int32
    let dataSkip: @convention(c) (Handle?) -> Int32
    let readData: @convention(c) (Handle?, UnsafeMutableRawPointer?, Int) -> Int
    let readClose: @convention(c) (Handle?) -> Int32
    let readFree: @convention(c) (Handle?) -> Int32
    let errorString: @convention(c) (Handle?) -> UnsafePointer<CChar>?
    let entryPathnameUTF8: @convention(c) (Entry?) -> UnsafePointer<CChar>?
    let entryPathname: @convention(c) (Entry?) -> UnsafePointer<CChar>?
    let entrySize: @convention(c) (Entry?) -> Int64
    let entrySizeIsSet: @convention(c) (Entry?) -> Int32
    let entryFiletype: @convention(c) (Entry?) -> UInt16
    let entryPerm: @convention(c) (Entry?) -> UInt16
    let entryMtime: @convention(c) (Entry?) -> Int
    let entryMtimeIsSet: @convention(c) (Entry?) -> Int32
    let entryIsDataEncrypted: @convention(c) (Entry?) -> Int32
    /// Not in every build: a hard link in a tar is a name for a file stored elsewhere in the archive.
    let entryHardlink: (@convention(c) (Entry?) -> UnsafePointer<CChar>?)?

    private init?() {
        guard let lib = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW) ?? dlopen("libarchive.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(lib, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard let readNew = load("archive_read_new", as: (@convention(c) () -> Handle?).self),
              let supportFilterAll = load("archive_read_support_filter_all", as: (@convention(c) (Handle?) -> Int32).self),
              let supportFormatAll = load("archive_read_support_format_all", as: (@convention(c) (Handle?) -> Int32).self),
              let addPassphrase = load("archive_read_add_passphrase", as: (@convention(c) (Handle?, UnsafePointer<CChar>?) -> Int32).self),
              let openFilename = load("archive_read_open_filename", as: (@convention(c) (Handle?, UnsafePointer<CChar>?, Int) -> Int32).self),
              let nextHeader = load("archive_read_next_header", as: (@convention(c) (Handle?, UnsafeMutablePointer<Entry?>?) -> Int32).self),
              let dataSkip = load("archive_read_data_skip", as: (@convention(c) (Handle?) -> Int32).self),
              let readData = load("archive_read_data", as: (@convention(c) (Handle?, UnsafeMutableRawPointer?, Int) -> Int).self),
              let readClose = load("archive_read_close", as: (@convention(c) (Handle?) -> Int32).self),
              let readFree = load("archive_read_free", as: (@convention(c) (Handle?) -> Int32).self),
              let errorString = load("archive_error_string", as: (@convention(c) (Handle?) -> UnsafePointer<CChar>?).self),
              let entryPathnameUTF8 = load("archive_entry_pathname_utf8", as: (@convention(c) (Entry?) -> UnsafePointer<CChar>?).self),
              let entryPathname = load("archive_entry_pathname", as: (@convention(c) (Entry?) -> UnsafePointer<CChar>?).self),
              let entrySize = load("archive_entry_size", as: (@convention(c) (Entry?) -> Int64).self),
              let entrySizeIsSet = load("archive_entry_size_is_set", as: (@convention(c) (Entry?) -> Int32).self),
              let entryFiletype = load("archive_entry_filetype", as: (@convention(c) (Entry?) -> UInt16).self),
              let entryPerm = load("archive_entry_perm", as: (@convention(c) (Entry?) -> UInt16).self),
              let entryMtime = load("archive_entry_mtime", as: (@convention(c) (Entry?) -> Int).self),
              let entryMtimeIsSet = load("archive_entry_mtime_is_set", as: (@convention(c) (Entry?) -> Int32).self),
              let entryIsDataEncrypted = load("archive_entry_is_data_encrypted", as: (@convention(c) (Entry?) -> Int32).self)
        else { return nil }
        self.readNew = readNew; self.supportFilterAll = supportFilterAll; self.supportFormatAll = supportFormatAll
        self.addPassphrase = addPassphrase; self.openFilename = openFilename; self.nextHeader = nextHeader
        self.dataSkip = dataSkip; self.readData = readData; self.readClose = readClose; self.readFree = readFree
        self.errorString = errorString; self.entryPathnameUTF8 = entryPathnameUTF8; self.entryPathname = entryPathname
        self.entrySize = entrySize; self.entrySizeIsSet = entrySizeIsSet; self.entryFiletype = entryFiletype
        self.entryPerm = entryPerm; self.entryMtime = entryMtime; self.entryMtimeIsSet = entryMtimeIsSet
        self.entryIsDataEncrypted = entryIsDataEncrypted
        self.entryHardlink = load("archive_entry_hardlink", as: (@convention(c) (Entry?) -> UnsafePointer<CChar>?).self)
    }
}

enum ArchiveReader {
    struct Entry: Equatable {
        var path: String                 // below the top of the archive, no leading or trailing slash
        var size: Int64
        var modified: Date?
        var isDirectory: Bool
        var mode: UInt16
        var encrypted: Bool
    }

    enum Failure: Error, Equatable {
        case unavailable
        case passphraseRequired
        case wrongPassphrase
        /// 7z and RAR passwords: the system's libarchive cannot decrypt them.
        case unsupportedEncryption
        case cancelled
        case failed(String)

        var message: String {
            switch self {
            case .unavailable: return tr("The system's archive library is not available")
            case .passphraseRequired: return tr("This archive is protected by a password")
            case .wrongPassphrase: return tr("The password is not correct")
            case .unsupportedEncryption: return tr("This archive is encrypted in a way macOS cannot read (only ZIP passwords are supported)")
            case .cancelled: return tr("Cancelled")
            case .failed(let text): return text
            }
        }
    }

    static var isAvailable: Bool { ArchiveLibrary.shared != nil }

    private static let ok: Int32 = 0, eof: Int32 = 1, warn: Int32 = -20

    /// "dir/./file", "/abs", "a//b/", "../x": the path below the archive's top, or nil when it points outside or at nothing.
    static func normalized(_ raw: String) -> String? {
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func open(_ lib: ArchiveLibrary, _ url: URL, passphrase: String?) -> Result<ArchiveLibrary.Handle, Failure> {
        guard let handle = lib.readNew() else { return .failure(.failed("archive_read_new")) }
        _ = lib.supportFilterAll(handle)
        _ = lib.supportFormatAll(handle)
        if let passphrase, !passphrase.isEmpty { _ = lib.addPassphrase(handle, passphrase) }
        let status = lib.openFilename(handle, url.path, 256 * 1024)
        if status < warn {
            let failure = classify(lib, handle, fallback: status)
            _ = lib.readFree(handle)
            return .failure(failure)
        }
        return .success(handle)
    }

    private static func errorText(_ lib: ArchiveLibrary, _ handle: ArchiveLibrary.Handle?) -> String {
        lib.errorString(handle).map { String(cString: $0) } ?? ""
    }

    /// Turns libarchive's message into something the interface can act on (ask for a password, explain).
    private static func classify(_ lib: ArchiveLibrary, _ handle: ArchiveLibrary.Handle?, fallback: Int32) -> Failure {
        let text = errorText(lib, handle)
        let lower = text.lowercased()
        if lower.contains("incorrect passphrase") || lower.contains("wrong passphrase") { return .wrongPassphrase }
        if lower.contains("passphrase required") || lower.contains("passphrase is required") { return .passphraseRequired }
        if lower.contains("crypt") { return .unsupportedEncryption }          // encrypted, decrypt, cryptographic …
        return .failed(text.isEmpty ? "libarchive error \(fallback)" : text)
    }

    private static func entry(_ lib: ArchiveLibrary, _ raw: ArchiveLibrary.Entry) -> Entry? {
        let name = lib.entryPathnameUTF8(raw).map { String(cString: $0) } ?? lib.entryPathname(raw).map { String(cString: $0) } ?? ""
        guard let path = normalized(name) else { return nil }
        if let hardlink = lib.entryHardlink?(raw), hardlink.pointee != 0 { return nil }          // would show up as an empty file
        let type = lib.entryFiletype(raw) & 0o170000
        // regular files and folders only: links and devices are not shown
        guard type == 0o100000 || type == 0o040000 else { return nil }
        return Entry(path: path,
                     size: type == 0o040000 ? 0 : (lib.entrySizeIsSet(raw) != 0 ? max(0, lib.entrySize(raw)) : 0),
                     modified: lib.entryMtimeIsSet(raw) != 0 ? Date(timeIntervalSince1970: TimeInterval(lib.entryMtime(raw))) : nil,
                     isDirectory: type == 0o040000, mode: lib.entryPerm(raw),
                     encrypted: lib.entryIsDataEncrypted(raw) != 0)
    }

    /// Everything inside the archive, without unpacking it. A password is only needed here for archives that hide
    /// their file names as well.
    static func list(_ url: URL, passphrase: String? = nil) -> Result<[Entry], Failure> {
        guard let lib = ArchiveLibrary.shared else { return .failure(.unavailable) }
        let handle: ArchiveLibrary.Handle
        switch open(lib, url, passphrase: passphrase) {
        case .failure(let failure): return .failure(failure)
        case .success(let opened): handle = opened
        }
        defer { _ = lib.readClose(handle); _ = lib.readFree(handle) }
        var result: [Entry] = []
        while true {
            var raw: ArchiveLibrary.Entry?
            let status = lib.nextHeader(handle, &raw)
            if status == eof { break }
            if status < warn { return .failure(classify(lib, handle, fallback: status)) }
            if let raw, let item = entry(lib, raw) { result.append(item) }
            _ = lib.dataSkip(handle)
        }
        return .success(result)
    }

    /// Takes the wanted files (and folders) out of the archive into `root`, keeping their paths. One pass over the
    /// archive; stops as soon as everything wanted has been found. Returns how many files were written.
    static func extract(_ url: URL, wanting: Set<String>, to root: URL, passphrase: String?, cancel: CancelToken? = nil,
                        progress: ((Int64) -> Void)? = nil) -> Result<Int, Failure> {
        guard let lib = ArchiveLibrary.shared else { return .failure(.unavailable) }
        let handle: ArchiveLibrary.Handle
        switch open(lib, url, passphrase: passphrase) {
        case .failure(let failure): return .failure(failure)
        case .success(let opened): handle = opened
        }
        defer { _ = lib.readClose(handle); _ = lib.readFree(handle) }
        let fm = FileManager.default
        var remaining = wanting
        var written = 0
        var bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while !remaining.isEmpty {
            if cancel?.isCancelled == true { return .failure(.cancelled) }
            var raw: ArchiveLibrary.Entry?
            let status = lib.nextHeader(handle, &raw)
            if status == eof { break }
            if status < warn { return .failure(classify(lib, handle, fallback: status)) }
            guard let raw, let item = entry(lib, raw), remaining.contains(item.path) else {
                _ = lib.dataSkip(handle)
                continue
            }
            remaining.remove(item.path)
            let destination = root.appendingPathComponent(item.path, isDirectory: item.isDirectory)
            if item.isDirectory {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
                _ = lib.dataSkip(handle)
                continue
            }
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).part")
            fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: Int((item.mode | 0o600) & 0o777)])
            guard let out = try? FileHandle(forWritingTo: temporary) else { return .failure(.failed(tr("Cannot create “%@”", destination.lastPathComponent))) }
            var failure: Failure?
            while true {
                if cancel?.isCancelled == true { failure = .cancelled; break }
                let count = buffer.withUnsafeMutableBytes { lib.readData(handle, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 { failure = classify(lib, handle, fallback: Int32(truncatingIfNeeded: count)); break }
                do { try out.write(contentsOf: buffer[0..<count]) }              // a full disk is an error, not a crash
                catch { failure = .failed(error.localizedDescription); break }
                bytes += Int64(count)
                progress?(bytes)
            }
            try? out.close()
            if let failure {
                try? fm.removeItem(at: temporary)
                return .failure(failure)
            }
            if let date = item.modified { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path) }
            if rename(temporary.path, destination.path) != 0 {           // replaces a placeholder in one step
                try? fm.removeItem(at: temporary)
                return .failure(.failed(String(cString: strerror(errno))))
            }
            written += 1
        }
        return .success(written)
    }
}
