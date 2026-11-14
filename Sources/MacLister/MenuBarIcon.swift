import AppKit

/// The menu-bar icon: two overlapping lister windows, drawn as a template image so macOS tints it for
/// light and dark menu bars.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            func window(_ r: NSRect) {
                NSColor.black.setStroke()
                NSColor.black.setFill()
                let outline = NSBezierPath(roundedRect: r, xRadius: 2.2, yRadius: 2.2)
                outline.lineWidth = 1.25
                outline.stroke()
                let bar = NSBezierPath()
                bar.move(to: NSPoint(x: r.minX, y: r.maxY - 3.4))
                bar.line(to: NSPoint(x: r.maxX, y: r.maxY - 3.4))
                bar.lineWidth = 1.0
                bar.stroke()
                NSBezierPath(rect: NSRect(x: r.minX + 1.7, y: r.maxY - 2.7, width: 1.5, height: 1.5)).fill()   // close gadget
            }
            let back = NSRect(x: 7.8, y: 4.6, width: 11, height: 10)
            let front = NSRect(x: 1.4, y: 1.1, width: 11.4, height: 10)
            window(back)
            // cut the part of the back window that lies behind the front one
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            window(front)
            // a list line in the front window
            let line = NSBezierPath()
            line.move(to: NSPoint(x: front.minX + 2.4, y: front.minY + 3.2))
            line.line(to: NSPoint(x: front.maxX - 2.4, y: front.minY + 3.2))
            line.lineWidth = 1.1
            NSColor.black.setStroke()
            line.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacLister"
        return image
    }

    /// A progress ring (template image). `fraction == nil` draws a dashed ring: busy, length unknown.
    static func progress(fraction: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()
            NSColor.black.setStroke()
            if let fraction {
                let arc = NSBezierPath()
                let sweep = max(0.02, min(1, fraction)) * 360
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                arc.stroke()
            } else {
                let dashed = NSBezierPath()
                dashed.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                dashed.lineWidth = 2
                dashed.setLineDash([3, 3], count: 2, phase: 0)
                dashed.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
