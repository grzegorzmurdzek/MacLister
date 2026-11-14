import AppKit

/// Recents and Shared: opening their rows, and keeping folder-only commands away from them.
extension ListerViewController {
    /// Folder commands make no sense in a list; says so and returns true.
    func refuseInList(_ what: String) -> Bool {
        guard let place = model.virtualPlace else { return false }
        flash(tr("%@ is not available in “%@”: open a folder first", what, place.title))
        return true
    }

    /// Double-click or Return on a row of the Shared list that is not a folder.
    func openSharedRow(_ item: FileItem) {
        switch SharedRow.parse(item.url) {
        case .server(let id)?:
            if let profile = ServerStore.shared.servers.first(where: { $0.id == id }) { connectChoice(profile) }
        case .computer(let name, let types)?:
            openComputer(name: name, types: types)
        case nil:
            break
        }
    }

    private func openComputer(name: String, types: [String]) {
        guard let type = types.first else { return }
        model.statusMessage = tr("Connecting to %@…", name)
        ServiceResolver.resolve(name: name, type: type) { [weak self] host, port in
            guard let self else { return }
            self.model.statusMessage = nil
            guard let host else {
                self.model.errorMessage = tr("Cannot find the server “%@”", name)
                return
            }
            switch type {
            case "_smb._tcp":
                NSWorkspace.shared.open(URL(string: "smb://\(host)")!)           // Finder mounts it and asks for the login
            case "_afpovertcp._tcp":
                NSWorkspace.shared.open(URL(string: "afp://\(host)")!)
            default:
                var profile = ServerProfile()
                profile.host = host
                profile.name = name
                profile.scheme = type == "_ftp._tcp" ? .ftp : .sftp
                profile.port = port > 0 ? port : profile.scheme.defaultPort
                self.connectToServer(prefill: profile)
            }
        }
    }

    /// The icon of a row: the file's own, or a symbol for rows that are not files.
    static func icon(for item: FileItem) -> NSImage? {
        if item.url.isFileURL { return NSWorkspace.shared.icon(forFile: item.url.path) }
        let name: String
        switch SharedRow.parse(item.url) {
        case .server?: name = "server.rack"
        default: name = "desktopcomputer"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
