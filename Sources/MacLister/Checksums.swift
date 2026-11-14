import SwiftUI
import AppKit
import CryptoKit

/// MD5, SHA-1, SHA-256 and SHA-512 of files, all four in one pass over the file.
enum FileHash {
    enum Algorithm: String, CaseIterable, Identifiable {
        case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256", sha512 = "SHA-512"
        var id: String { rawValue }
    }

    typealias Digests = [Algorithm: String]

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let chunk = 1 << 20

    /// The next piece of the file; empty at the end, nil when reading failed (an error must never look like the end).
    private static func readChunk(_ handle: FileHandle, _ count: Int = chunk) -> Data? {
        do { return try handle.read(upToCount: count) ?? Data() } catch { return nil }
    }

    /// Reads the file once and returns the checksums; nil when it cannot be read or `cancel` fired.
    /// `progress` gets the number of bytes read so far (on the calling thread).
    static func digests(of url: URL, cancel: CancelToken? = nil, progress: ((Int64) -> Void)? = nil) -> Digests? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        var total: Int64 = 0
        while true {
            if cancel?.isCancelled == true { return nil }
            var finished = false
            let ok: Bool = autoreleasepool {
                guard let data = readChunk(handle) else { return false }
                if data.isEmpty { finished = true; return true }
                md5.update(data: data); sha1.update(data: data); sha256.update(data: data); sha512.update(data: data)
                total += Int64(data.count)
                return true
            }
            if !ok { return nil }
            if finished { break }
            progress?(total)
        }
        return [.md5: hex(md5.finalize()), .sha1: hex(sha1.finalize()), .sha256: hex(sha256.finalize()), .sha512: hex(sha512.finalize())]
    }

    /// SHA-256 of the first `bytes` bytes (or of the whole file when it is shorter): a cheap first look for duplicates.
    static func sha256Prefix(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = readChunk(handle, bytes) else { return nil }
        return hex(SHA256.hash(data: data))
    }

    /// SHA-256 of the whole file.
    static func sha256(of url: URL, cancel: CancelToken? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancel?.isCancelled == true { return nil }
            var finished = false
            let ok: Bool = autoreleasepool {
                guard let data = readChunk(handle) else { return false }
                if data.isEmpty { finished = true; return true }
                hasher.update(data: data)
                return true
            }
            if !ok { return nil }
            if finished { break }
        }
        return hex(hasher.finalize())
    }

    /// Lower case, without spaces, colons or a "sha256:" style prefix: what you pasted, comparable with a checksum.
    static func normalized(_ text: String) -> String {
        var cleaned = text.lowercased()
        if let colon = cleaned.firstIndex(of: ":"), cleaned[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), cleaned.distance(from: cleaned.startIndex, to: colon) <= 8 {
            cleaned = String(cleaned[cleaned.index(after: colon)...])
        }
        return cleaned.filter { $0.isHexDigit }
    }
}

// MARK: - The window

struct ChecksumRow: Identifiable, Equatable {
    let url: URL
    var size: Int64
    var digests: FileHash.Digests?
    var failed = false
    var id: URL { url }
}

struct ChecksumsView: View {
    let urls: [URL]
    var close: () -> Void

    @State private var rows: [ChecksumRow]
    @State private var done = false
    @State private var fraction = 0.0
    @State private var currentFile: URL?
    @State private var expected = ""
    @State private var token = CancelToken()

    init(urls: [URL], close: @escaping () -> Void) {
        self.urls = urls
        self.close = close
        _rows = State(initialValue: urls.map { url in
            ChecksumRow(url: url, size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        })
    }

    /// Which checksum of which file equals what was pasted, if any.
    private var match: (algorithm: FileHash.Algorithm, file: URL)? {
        let wanted = FileHash.normalized(expected)
        guard wanted.count >= 8 else { return nil }
        for row in rows {
            for algorithm in FileHash.Algorithm.allCases where row.digests?[algorithm] == wanted { return (algorithm, row.url) }
        }
        return nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "hash  name" lines, the format `shasum -a 256 -c` reads.
    private func shasumList(_ algorithm: FileHash.Algorithm) -> String {
        rows.compactMap { row in row.digests?[algorithm].map { "\($0)  \(row.url.lastPathComponent)" } }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checksums").font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.url.lastPathComponent).font(.system(.body, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)).foregroundStyle(.secondary)
                            }
                            if let digests = row.digests {
                                ForEach(FileHash.Algorithm.allCases) { algorithm in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(algorithm.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                                        Text(digests[algorithm] ?? "")
                                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                            .foregroundStyle(match?.algorithm == algorithm && match?.file == row.url ? Color.green : Color.primary)
                                        Spacer(minLength: 0)
                                        Button { copy(digests[algorithm] ?? "") } label: { Image(systemName: "doc.on.doc") }
                                            .buttonStyle(.borderless).help("Copy")
                                    }
                                }
                            } else if row.failed {
                                Text("Cannot read this file").foregroundStyle(.red)
                            } else if currentFile == row.url {
                                ProgressView(value: fraction)
                            } else {
                                Text("Waiting…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180)

            HStack {
                Text("Compare with")
                TextField("paste a checksum", text: $expected).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            if FileHash.normalized(expected).count >= 8 {
                if let match {
                    Label(tr("Matches the %@ of “%@”", match.algorithm.rawValue, match.file.lastPathComponent), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if done {
                    Label("Does not match any checksum here", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }

            HStack {
                Menu("Copy List") {
                    ForEach(FileHash.Algorithm.allCases) { algorithm in
                        Button(tr("%@ list (shasum format)", algorithm.rawValue)) { copy(shasumList(algorithm)) }
                    }
                }
                .disabled(!done).fixedSize()
                Spacer()
                Button(done ? "Close" : "Cancel") { token.cancel(); close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .onAppear { compute() }
    }

    private func compute() {
        let token = token
        let urls = urls
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, url) in urls.enumerated() {
                if token.isCancelled { return }
                let size = max(1, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                DispatchQueue.main.async { currentFile = url; fraction = 0 }
                var lastReport = Date.distantPast
                let digests = FileHash.digests(of: url, cancel: token) { read in
                    guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
                    lastReport = Date()
                    DispatchQueue.main.async { fraction = min(1, Double(read) / Double(size)) }
                }
                if token.isCancelled { return }
                DispatchQueue.main.async {
                    rows[index].digests = digests
                    rows[index].failed = digests == nil
                    if index == urls.count - 1 { done = true; currentFile = nil }
                }
            }
        }
    }
}

extension ListerViewController {
    /// The checksums window for the given files (folders are left out).
    func showChecksums(for urls: [URL]) {
        if remoteUnavailable(tr("Checksums")) { return }
        let files = urls.filter { url in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        guard !files.isEmpty, let window = view.window else {
            flash(tr("Checksums need files: select a file, not a folder"))
            return
        }
        materialized(files) {
            SheetPresenter().present(on: window, size: NSSize(width: 640, height: 460)) { close in
                ChecksumsView(urls: files, close: close)
            }
        }
    }
}
