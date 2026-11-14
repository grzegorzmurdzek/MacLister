import AppKit

/// Listens (passively) for left-button double-clicks anywhere on screen and reports the ones that
/// land on empty desktop.
///
/// Primary mechanism: a listen-only CGEventTap (needs Accessibility permission). If the tap cannot
/// be created, falls back to NSEvent's global monitor, which sees mouse events of other apps too.
final class DesktopDoubleClickMonitor {
    enum Mode { case stopped, eventTap, globalMonitor }

    /// Called on the main thread with the click position in Cocoa screen coordinates.
    var onDesktopDoubleClick: ((NSPoint) -> Void)?

    private(set) var mode: Mode = .stopped
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMonitor: Any?

    private static let ignoredModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    @discardableResult
    func start() -> Mode {
        guard mode == .stopped else { return mode }
        // Since macOS 10.15 even a listen-only tap is gated by Input Monitoring; ask for it (no-op if granted).
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if installEventTap() {
            mode = .eventTap
        } else {
            installGlobalMonitor()
            mode = .globalMonitor
        }
        DebugLog.write("monitor started: \(mode) (AX trusted: \(AXIsProcessTrusted()), input monitoring: \(CGPreflightListenEventAccess()))")
        return mode
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        tap = nil; tapSource = nil; globalMonitor = nil
        mode = .stopped
    }

    deinit { stop() }

    // MARK: - CGEventTap

    private func installEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)

        // C callback: cannot capture, so `self` travels through refcon.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DesktopDoubleClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleTapEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)   // listen-only: never alters the event stream
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches slow/unresponsive taps off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            if Settings.debugHitTest { DebugLog.write("mouse down, clickState=\(event.getIntegerValueField(.mouseEventClickState))") }
            guard Settings.desktopTrigger.accepts(button: 0, clickCount: Int(event.getIntegerValueField(.mouseEventClickState))),
                  event.flags.intersection(Self.ignoredModifiers).isEmpty else { return }
            let location = event.location
            if Settings.debugHitTest { DebugLog.write("double-click seen via tap at \(location)") }
            // Return from the tap immediately; the hit test (window list + AX) runs afterwards.
            DispatchQueue.main.async { [weak self] in self?.evaluate(cgPoint: location) }
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if Settings.debugHitTest { DebugLog.write("other button down, button=\(button) clickState=\(event.getIntegerValueField(.mouseEventClickState))") }
            guard Settings.desktopTrigger.accepts(button: button, clickCount: Int(event.getIntegerValueField(.mouseEventClickState))),
                  event.flags.intersection(Self.ignoredModifiers).isEmpty else { return }
            let location = event.location
            if Settings.debugHitTest { DebugLog.write("middle click seen via tap at \(location)") }
            DispatchQueue.main.async { [weak self] in self?.evaluate(cgPoint: location) }
        default:
            break
        }
    }

    // MARK: - NSEvent fallback

    private func installGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .otherMouseDown]) { [weak self] event in
            guard Settings.desktopTrigger.accepts(button: event.type == .leftMouseDown ? 0 : event.buttonNumber, clickCount: event.clickCount),
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return }
            let cocoa = NSEvent.mouseLocation
            if Settings.debugHitTest { DebugLog.write("double-click seen via global monitor") }
            self?.evaluate(cgPoint: CoordinateSpace.cgPoint(fromCocoa: cocoa))
        }
    }

    // MARK: - Decision

    private func evaluate(cgPoint: CGPoint) {
        guard DesktopHitTest.isEmptyDesktop(atCGPoint: cgPoint) else { return }
        onDesktopDoubleClick?(CoordinateSpace.cocoaPoint(fromCG: cgPoint))
    }
}
