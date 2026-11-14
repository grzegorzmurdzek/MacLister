import Foundation

/// One-time move of data from the app's earlier name (MagellanLister): the buttons.json folder and
/// the few user-facing preferences. Safe to run on every launch.
enum LegacyMigration {
    private static let oldName = "MagellanLister"
    private static let oldBundleID = "com.example.MagellanLister"

    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldName, isDirectory: true)
        let new = support.appendingPathComponent("MacLister", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromMagellanLister") else { return }
        if let legacy = defaults.persistentDomain(forName: oldBundleID) {
            for key in ["centerOnCursor", "startDirectory", "terminalBundleID", "showStatusItem"] {
                if let value = legacy[key], defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: "migratedFromMagellanLister")
    }
}
