import AppKit
import ApplicationServices

/// Decides whether a point on screen is "empty desktop": nothing but wallpaper (and Finder's
/// desktop layer) under the cursor — no app window, no menu bar / Dock, no desktop icon or widget.
///
/// All points here are in CG global coordinates (origin top-left of the primary display, y down),
/// which is what CGEvent.location, CGWindowList and the Accessibility API all use.
enum DesktopHitTest {

    static func isEmptyDesktop(atCGPoint point: CGPoint) -> Bool {
        guard isInUsableScreenArea(point) else {
            log("(\(point.x), \(point.y)) outside usable area (menu bar / Dock zone)")
            return false
        }
        guard onlyDesktopLayersUnder(point) else { return false }
        if hitsDesktopItem(at: point) {
            log("hit a desktop icon / widget")
            return false
        }
        log("empty desktop at (\(point.x), \(point.y))")
        return true
    }

    // MARK: - Step 1: not in the menu bar / Dock strip

    /// The Dock owns a transparent full-screen window (layer 20) and the menu bar is a Window Server
    /// window, so neither can be handled by the window list alone. `visibleFrame` already excludes
    /// both of them, so require the click to be inside it.
    private static func isInUsableScreenArea(_ cgPoint: CGPoint) -> Bool {
        let cocoa = CoordinateSpace.cocoaPoint(fromCG: cgPoint)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) else { return false }
        return screen.visibleFrame.contains(cocoa)
    }

    // MARK: - Step 2: no app window above the desktop

    /// Walks the on-screen windows front to back. The first window containing the point decides:
    /// a normal/floating/status window (layer >= 0) means "something is covering the desktop";
    /// a window at the desktop levels (wallpaper, Finder's icon layer) means "this is the desktop".
    private static func onlyDesktopLayersUnder(_ point: CGPoint) -> Bool {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

        for info in infos {
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.01 else { continue }          // invisible overlay windows

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point) else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            // System chrome that always spans large areas and is handled by step 1.
            if owner == "Dock" || owner == "Window Server" { continue }

            // "Click wallpaper to reveal desktop" (and Stage Manager) put a transparent window of the
            // window manager over the whole screen the moment the first click of a double-click lands.
            // Small WindowManager windows (Stage Manager strip) still count as covering.
            if owner == "WindowManager", bounds.width * bounds.height >= 0.8 * screenArea(containing: point) {
                log("ignoring full-screen WindowManager overlay \(bounds)")
                continue
            }

            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            if layer >= 0 {
                log("covered by \(owner) window (layer \(layer), \(bounds))")
                return false
            }
            if layer > iconLevel {
                // Negative layer but above Finder's icon layer: some unknown desktop overlay.
                log("covered by desktop overlay of \(owner) (layer \(layer))")
                return false
            }
            return true   // wallpaper / Finder desktop layer: nothing is above it
        }
        log("no desktop-level window under the point (full-screen Space?)")
        return false
    }

    private static func screenArea(containing cgPoint: CGPoint) -> CGFloat {
        let cocoa = CoordinateSpace.cocoaPoint(fromCG: cgPoint)
        let frame = NSScreen.screens.first(where: { $0.frame.contains(cocoa) })?.frame ?? .zero
        return frame.width * frame.height
    }

    // MARK: - Step 3: not on a desktop icon

    /// Finder draws desktop icons inside one full-screen window, so the window list cannot tell an
    /// icon from empty space. Ask Accessibility what lives under the cursor: the empty desktop
    /// resolves to a screen-sized container, an icon (or widget) to a small element.
    /// Any failure (no element, no frame, timeout) is treated as "empty".
    private static func hitsDesktopItem(at point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }

        var frameValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue) == .success,
              let frameValue, CFGetTypeID(frameValue) == AXValueGetTypeID() else { return false }

        var frame = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(frameValue, to: AXValue.self), .cgRect, &frame) else { return false }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        log("AX element role=\(role as? String ?? "?") frame=\(frame)")

        let cocoa = CoordinateSpace.cocoaPoint(fromCG: point)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) else { return false }
        let small = frame.width < screen.frame.width * 0.5 && frame.height < screen.frame.height * 0.5
        return small
    }

    private static func log(_ message: @autoclosure () -> String) {
        if Settings.debugHitTest { DebugLog.write("hit-test: " + message()) }
    }
}

/// Conversion between CG global coordinates (top-left origin) and Cocoa (bottom-left origin).
enum CoordinateSpace {
    /// Height of the primary display (the one whose frame origin is (0,0)) – the pivot of the flip.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaPoint(fromCG p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func cgPoint(fromCocoa p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
