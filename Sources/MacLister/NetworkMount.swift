import AppKit
import NetFS

/// Mounts a network share (smb://, afp://, nfs://) and takes the lister into it, so there is no Finder window and no
/// second step: the system asks for the login itself, and when the share is there the lister shows it.
enum NetworkMount {
    static let schemes = ["smb", "afp", "nfs"]

    /// smb://server/share, afp://… and nfs://… addresses (typed in the path field, or found on the network).
    static func isMountable(_ url: URL) -> Bool {
        url.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }

    /// The address of a computer found on the network: smb://host (no share yet).
    static func address(scheme: String, host: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        return components.url
    }

    /// What the lister says while it waits: "Connecting to server…".
    static func label(of url: URL) -> String { url.host ?? url.absoluteString }

    /// Mounts `url` and, once it is mounted, shows the share in `model`. A share that is mounted already is just opened.
    /// When the system cannot mount the address by itself (a server without a share name, an unusual login) Finder is
    /// asked to, and the lister follows the disk when it appears.
    static func mount(_ url: URL, in model: ListerModel) {
        model.statusMessage = tr("Connecting to %@…", label(of: url))
        let options = NSMutableDictionary()
        options[kNAUIOptionKey as String] = kNAUIOptionAllowUI as String       // the system shows its login window
        var request: AsyncRequestID?
        let started = NetFSMountURLAsync(url as CFURL, nil, nil, nil, options as CFMutableDictionary, nil, &request,
                                         DispatchQueue.main) { [weak model] status, _, mountpoints in
            guard let model else { return }
            model.statusMessage = nil
            let path = (mountpoints as? [String])?.first
            switch status {
            case 0, EEXIST:
                if let path { model.navigate(to: URL(fileURLWithPath: path, isDirectory: true)) }
                else { followFinder(url, in: model) }
            case ECANCELED, -128:       // the user closed the login window
                break
            default:
                followFinder(url, in: model)
            }
        }
        if started != 0 { followFinder(url, in: model) }
    }

    /// Finder mounts the address (it asks for the share and the login itself); the lister goes into the first network
    /// disk that appears within a minute.
    private static func followFinder(_ url: URL, in model: ListerModel) {
        var observer: NSObjectProtocol?
        let stop = { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observer = nil }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak model] note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false else { return }
            stop()
            model?.navigate(to: volume)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { stop() }
        NSWorkspace.shared.open(url)
    }
}
