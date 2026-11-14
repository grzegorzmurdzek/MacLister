import AppKit

/// Shows the release notes of an update (GitHub Markdown) as formatted text instead of raw Markdown.
enum ReleaseNotes {
    /// The part of the notes worth showing in an update window: the section in the language of the interface
    /// (the notes carry the English text, a `---` line and the Polish text), from the first `###` heading
    /// (What's new) up to the install instructions.
    static func excerpt(from markdown: String, polish: Bool) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if let rule = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = polish ? Array(lines[(rule + 1)...]) : Array(lines[..<rule])
        }
        if let first = lines.firstIndex(where: { $0.hasPrefix("### ") }) { lines = Array(lines[first...]) }
        if let install = lines.firstIndex(where: { $0.hasPrefix("### Install") }) { lines = Array(lines[..<install]) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Headings, bullets, numbered lists, **bold**, *italic*, `code` and [links](url).
    static func attributed(_ markdown: String, size: CGFloat = NSFont.systemFontSize) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: size)
        let paragraphs = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for raw in paragraphs {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" { continue }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            var text = line
            var font = body
            var prefix = ""
            if let level = headingLevel(line) {
                text = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                font = NSFont.boldSystemFont(ofSize: size + (level == 1 ? 4 : level == 2 ? 2 : 0))
                style.paragraphSpacingBefore = out.length == 0 ? 0 : 6
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                text = String(line.dropFirst(2))
                prefix = "•\t"
                style.firstLineHeadIndent = 4
                style.headIndent = 20
                style.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
            } else if let number = numberedPrefix(line) {
                text = String(line.dropFirst(number.count)).trimmingCharacters(in: .whitespaces)
                prefix = number.trimmingCharacters(in: .whitespaces) + "\t"
                style.firstLineHeadIndent = 4
                style.headIndent = 20
                style.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
            }
            let piece = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            piece.append(inline(text, font: font))
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(piece)
        }
        return out
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        return (1...6).contains(hashes) && line.dropFirst(hashes).first == " " ? hashes : nil
    }

    private static func numberedPrefix(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.prefix(digits.count + 2))
    }

    /// Inline Markdown of one line.
    static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let plain = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return plain }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var traits: NSFontDescriptor.SymbolicTraits = font.fontDescriptor.symbolicTraits
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                if intent.contains(.code) { runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: traits.contains(.bold) ? .bold : .regular) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: NSColor.labelColor]
            if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    /// A scrolling, selectable text view with the formatted notes, for an alert's accessory view.
    static func accessoryView(for markdown: String, width: CGFloat = 440, height: CGFloat = 220) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 16, height: height))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textStorage?.setAttributedString(attributed(markdown))
        scroll.documentView = text
        return scroll
    }
}
