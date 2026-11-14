import AppKit

// Agent app (LSUIElement): no Dock icon, no main window. Everything starts in AppDelegate.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
