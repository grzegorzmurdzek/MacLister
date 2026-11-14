import AppKit

// Starts as an agent (LSUIElement): no Dock icon until AppDelegate applies the "Show in the Dock" setting.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
