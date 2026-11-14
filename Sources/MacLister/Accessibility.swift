import AppKit
import ApplicationServices

enum Accessibility {
    /// - Parameter prompt: true shows the system "grant Accessibility access" dialog if not trusted yet.
    static func isTrusted(prompt: Bool) -> Bool {
        // Literal instead of kAXTrustedCheckOptionPrompt (a mutable global, awkward under strict concurrency).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
