import AppKit
import SwiftUI
import ObjectiveC

/// Development aid: records every text that was looked up in the string table but has no translation,
/// so a Polish run shows what is still English. Only installed by `--selftest-language`.
enum LocalizationAudit {
    static var misses = Set<String>()
    private static var installed = false

    static func install() {
        guard !installed, let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
              let spy = class_getInstanceMethod(Bundle.self, #selector(Bundle.audit_localizedString(forKey:value:table:))) else { return }
        method_exchangeImplementations(original, spy)
        installed = true
    }

    /// Draws a SwiftUI view in a hidden window long enough for its texts to be looked up.
    static func touch<V: View>(_ view: V, size: NSSize = NSSize(width: 520, height: 600)) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false          // ARC owns it; closing must not release it a second time
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        window.close()
    }
}

extension Bundle {
    @objc func audit_localizedString(forKey key: String, value: String?, table: String?) -> String {
        let result = audit_localizedString(forKey: key, value: value, table: table)      // the original, after the swap
        if self == Bundle.main, result == key, key.contains(where: \.isLetter) { LocalizationAudit.misses.insert(key) }
        return result
    }
}
