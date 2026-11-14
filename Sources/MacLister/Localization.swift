import Foundation

/// Interface language. "System" follows the macOS language list (Polish on a Polish system, English
/// otherwise); the other two force a language. The choice is stored where macOS itself keeps a
/// per-app language (AppleLanguages), so SwiftUI, AppKit and NSLocalizedString all agree, and it
/// takes effect when the app starts.
enum AppLanguage: String, CaseIterable {
    case system, english, polish

    var menuTitle: String {
        switch self {
        case .system: return tr("System Default")
        case .english: return "English"
        case .polish: return "Polski"
        }
    }

    var code: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .polish: return "pl"
        }
    }

    /// The language the user chose (read from AppleLanguages, written by `apply`).
    static var current: AppLanguage {
        guard let first = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first else {
            return .system
        }
        return first.hasPrefix("pl") ? .polish : first.hasPrefix("en") ? .english : .system
    }

    /// Stores the choice. The running app keeps its language until restarted.
    func apply() {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The language this run actually uses.
    static var effectiveCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}

/// The string in the current interface language. The English text is the key; Polish is in
/// Resources/pl.lproj/Localizable.strings.
func tr(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localised format string with arguments (use %@ for text, %d for integers).
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: arguments)
}

/// Counted texts ("1 item", "2 elementy", "5 elementów") come from Localizable.stringsdict, which
/// knows each language's plural rules. Same call shape as `tr`.
func trCount(_ key: String, _ count: Int) -> String {
    String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), count)
}
