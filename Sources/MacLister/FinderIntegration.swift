import AppKit

/// "Open in MacLister" in Finder, as a Quick Action: an Automator workflow in ~/Library/Services that runs
/// `open -b com.example.MacLister "$@"` on the selected folders and files. Finder offers such workflows in the
/// right-click menu (Quick Actions) and in Finder → Services; the service that MacLister declares itself (Info.plist)
/// is not shown by Finder, so this is the way that works. MacLister then opens a lister on a folder, or on the folder
/// of a file with the file selected (see AppDelegate.openInLister).
enum FinderIntegration {
    static let workflowName = "Open in MacLister.workflow"

    static var servicesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services", isDirectory: true)
    }

    static func workflowURL(in directory: URL = servicesDirectory) -> URL {
        directory.appendingPathComponent(workflowName, isDirectory: true)
    }

    static func isInstalled(in directory: URL = servicesDirectory) -> Bool {
        FileManager.default.fileExists(atPath: workflowURL(in: directory).appendingPathComponent("Contents/document.wflow").path)
    }

    /// What the workflow runs: the selected items arrive as arguments.
    static func command(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.example.MacLister") -> String {
        "open -b \(bundleIdentifier) \"$@\""
    }

    /// Contents/Info.plist: the entry in the Services menu and in the Quick Actions of the right-click menu.
    static func infoPlist(title: String) -> [String: Any] {
        ["NSServices": [[
            "NSBackgroundColorName": "background",
            "NSIconName": "NSActionTemplate",
            "NSMenuItem": ["default": title],
            "NSMessage": "runWorkflowAsService",
            "NSSendFileTypes": ["public.item"],
        ] as [String: Any]]]
    }

    /// Contents/document.wflow: one "Run Shell Script" action (as Automator saves it), input "files or folders".
    static func document(command: String) -> [String: Any] {
        func argument(_ name: String, _ value: Any, _ index: String) -> [String: Any] {
            ["default value": value, "name": name, "required": "0", "type": "0", "uuid": index]
        }
        let action: [String: Any] = [
            "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]] as [String: Any],
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": ["COMMAND_STRING": [String: Any](), "CheckedForUserDefaultShell": [String: Any](),
                                      "inputMethod": [String: Any](), "shell": [String: Any](), "source": [String: Any]()],
            "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]] as [String: Any],
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script",
            "ActionParameters": ["COMMAND_STRING": command, "CheckedForUserDefaultShell": true, "inputMethod": 1,
                                 "shell": "/bin/zsh", "source": ""] as [String: Any],
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": false,
            "CanShowWhenRun": true,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "InputUUID": UUID().uuidString,
            "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
            "OutputUUID": UUID().uuidString,
            "UUID": UUID().uuidString,
            "UnlocalizedApplications": ["Automator"],
            "arguments": ["0": argument("inputMethod", 0, "0"), "1": argument("CheckedForUserDefaultShell", false, "1"),
                          "2": argument("source", "", "2"), "3": argument("COMMAND_STRING", "", "3"),
                          "4": argument("shell", "/bin/sh", "4")],
            "conversionLabel": 0,
            "isViewVisible": 1,
            "location": "309.000000:305.000000",
            "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
        ]
        return [
            "AMApplicationBuild": "534",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [["action": action, "isViewVisible": 1] as [String: Any]],
            "connectors": [String: Any](),
            "workflowMetaData": [
                "applicationBundleIDsByPath": [String: Any](),
                "applicationPaths": [String](),
                "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 15,
                "processesInput": false,
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": false,
                "systemImageName": "NSActionTemplate",
                "useAutomaticInputType": false,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            ] as [String: Any],
        ]
    }

    /// Writes the workflow (replacing an older one) and, unless `refresh` is off, asks macOS to re-read the services.
    @discardableResult
    static func install(in directory: URL = servicesDirectory, title: String = tr("Open in MacLister"), refresh: Bool = true) throws -> URL {
        let fm = FileManager.default
        let workflow = workflowURL(in: directory)
        let contents = workflow.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: infoPlist(title: title), format: .xml, options: 0)
        let document = try PropertyListSerialization.data(fromPropertyList: document(command: command()), format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try document.write(to: contents.appendingPathComponent("document.wflow"), options: .atomic)
        if refresh { refreshServices() }
        return workflow
    }

    static func uninstall(in directory: URL = servicesDirectory, refresh: Bool = true) throws {
        let workflow = workflowURL(in: directory)
        if FileManager.default.fileExists(atPath: workflow.path) { try FileManager.default.removeItem(at: workflow) }
        if refresh { refreshServices() }
    }

    /// `pbs -update` makes macOS notice a new or removed service without logging out.
    private static func refreshServices() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            process.arguments = ["-update"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
