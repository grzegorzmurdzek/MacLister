import Foundation

/// The codes in the command of a filetype (and the menu entries of a filetype), as in Directory Opus Magellan:
///
///     {f}   full path of a selected file      {F}   the full paths of all selected files
///     {o}   name of a selected file           {O}   the names of all selected files
///     {df} {dF} {do} {dO}                     the same for the selection of the destination lister
///     {d}   the folder of the destination lister      {s}   the folder of this lister
///
/// Lower case runs the command once for every file, upper case once for all of them. Every value is put in quotes
/// for the shell (write `code {F}`, not `code "{F}"`). A `-` after the letter cuts the extension (`{o-}`), a `!`
/// makes the code optional: it is empty when there is nothing to put in (`{df!}`), otherwise the command is not run.
/// Anything else in braces, such as `{}` of `find`, is left as it is.
enum FiletypeCommand {
    struct Context {
        var directory: URL
        var selection: [URL]
        var destinationDirectory: URL? = nil
        var destinationSelection: [URL] = []
    }

    struct Expansion: Equatable {
        var commands: [String] = []
        var error: String?
    }

    private struct Code {
        var range: Range<String.Index>
        var destination: Bool       // {d…}
        var kind: Character         // f F o O, or d / s for the folders
        var stripExtension: Bool
        var optional: Bool
        var perFile: Bool { kind == "f" || kind == "o" }
    }

    /// `{` then optional `d`, a letter, optional `-`, optional `!`, `}`.
    private static let pattern = try! NSRegularExpression(pattern: #"\{(d?)([fFoO]|(?<=\{)[ds])(-?)(!?)\}"#)

    private static func codes(in template: String) -> [Code] {
        let whole = NSRange(template.startIndex..., in: template)
        return pattern.matches(in: template, range: whole).compactMap { match in
            guard let range = Range(match.range, in: template),
                  let prefix = Range(match.range(at: 1), in: template),
                  let letter = Range(match.range(at: 2), in: template),
                  let kind = template[letter].first else { return nil }
            let destination = !template[prefix].isEmpty
            return Code(range: range, destination: destination, kind: kind,
                        stripExtension: match.range(at: 3).length > 0, optional: match.range(at: 4).length > 0)
        }
    }

    /// True when the text has at least one code that this type understands.
    static func hasCodes(_ template: String) -> Bool { !codes(in: template).isEmpty }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func text(for url: URL, code: Code) -> String {
        var path = code.kind == "o" || code.kind == "O" ? url.lastPathComponent : url.path
        if code.stripExtension {
            let ext = (path as NSString).pathExtension
            if !ext.isEmpty { path = String(path.dropLast(ext.count + 1)) }
        }
        return path
    }

    /// The command lines to run for the context: one per file when the template uses a lower-case code, else one.
    static func expand(_ template: String, in context: Context) -> Expansion {
        let found = codes(in: template)
        // A command without codes is run as it is (it can still read LISTER_SELECTION).
        guard !found.isEmpty else { return Expansion(commands: [template]) }

        let sourcePerFile = found.contains { !$0.destination && $0.perFile }
        let destinationPerFile = found.contains { $0.destination && $0.perFile }
        let count: Int
        if sourcePerFile { count = max(context.selection.count, 1) }
        else if destinationPerFile { count = max(context.destinationSelection.count, 1) }
        else { count = 1 }

        var commands: [String] = []
        for index in 0..<count {
            var line = template
            // from the end, so that the ranges stay valid
            for code in found.reversed() {
                let value: String?
                switch (code.kind, code.destination) {
                case ("s", _):
                    value = quote(context.directory.path)
                case ("d", _):
                    value = context.destinationDirectory.map { quote($0.path) }
                default:
                    let urls = code.destination ? context.destinationSelection : context.selection
                    if code.perFile {
                        value = urls.indices.contains(index) ? quote(text(for: urls[index], code: code)) : nil
                    } else {
                        value = urls.isEmpty ? nil : urls.map { quote(text(for: $0, code: code)) }.joined(separator: " ")
                    }
                }
                if let value {
                    line.replaceSubrange(code.range, with: value)
                } else if code.optional {
                    line.replaceSubrange(code.range, with: "")
                } else {
                    let name = String(template[code.range])
                    let why = code.destination || code.kind == "d"
                        ? tr("%@ needs a destination lister", name) : tr("%@ needs a selected file", name)
                    return Expansion(commands: [], error: why)
                }
            }
            commands.append(line)
        }
        return Expansion(commands: commands)
    }
}
