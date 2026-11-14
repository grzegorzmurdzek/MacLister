// Draws MacLister's app icon and writes Support/AppIcon.icns.
//   swift Tools/make_icon.swift            (run from the project folder)
// Two overlapping lister windows (source = blue, destination = orange) on a macOS-style rounded square,
// with Amiga Workbench details: hard navy outlines, a close gadget on the left, depth gadgets on the
// right and pin-striped title bars.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let navy = color(0x0B2A5B)
let blue = color(0x2F7FE8)
let orange = color(0xFF8A1E)

func squircle(_ r: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    for i in 0...400 {
        let t = Double(i) / 400 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * CGFloat(pow(abs(c), 2 / n)) * (c < 0 ? -1 : 1)
        let y = r.midY + b * CGFloat(pow(abs(s), 2 / n)) * (s < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let box = path.boundingBox
    ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

func shadowed(_ ctx: CGContext, offset: CGSize, blur: CGFloat, alpha: CGFloat, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: offset, blur: blur, color: color(0x000000, alpha))
    body()
    ctx.restoreGState()
}

/// One lister window. `frame` is in canvas coordinates (y up).
func drawWindow(_ ctx: CGContext, frame: CGRect, accent: CGColor, rows: Int, selected: Int?, scale s: CGFloat) {
    let radius = 26 * s
    let outline = 5 * s
    let titleHeight = 66 * s
    let body = rounded(frame, radius)

    shadowed(ctx, offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, alpha: 0.38) {
        ctx.addPath(body); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    }
    fill(ctx, body, top: color(0xFFFFFF), bottom: color(0xE6ECF4))

    // Title bar with pin stripes
    let titleRect = CGRect(x: frame.minX, y: frame.maxY - titleHeight, width: frame.width, height: titleHeight)
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.setFillColor(color(0xF4F6FA)); ctx.fill(titleRect)
    ctx.setFillColor(accent.copy(alpha: 0.95)!)
    var y = titleRect.minY + 12 * s
    while y < titleRect.maxY - 10 * s {
        ctx.fill(CGRect(x: titleRect.minX + 76 * s, y: y, width: titleRect.width - 152 * s, height: 3.4 * s))
        y += 9 * s
    }
    // title text plate
    let plate = CGRect(x: titleRect.midX - 90 * s, y: titleRect.midY - 17 * s, width: 180 * s, height: 34 * s)
    ctx.setFillColor(color(0xF4F6FA)); ctx.addPath(rounded(plate, 8 * s)); ctx.fillPath()
    ctx.setFillColor(color(0x5A6B85, 0.85)); ctx.addPath(rounded(plate.insetBy(dx: 22 * s, dy: 10 * s), 4 * s)); ctx.fillPath()
    // divider under the title bar
    ctx.setFillColor(navy); ctx.fill(CGRect(x: titleRect.minX, y: titleRect.minY - outline / 2, width: titleRect.width, height: outline * 0.75))
    ctx.restoreGState()

    // Amiga gadgets: close gadget (left), depth gadgets (right)
    let g = 36 * s
    let closeGadget = CGRect(x: frame.minX + 20 * s, y: titleRect.midY - g / 2, width: g, height: g)
    ctx.setFillColor(color(0xFFFFFF)); ctx.fill(closeGadget)
    ctx.setStrokeColor(navy); ctx.setLineWidth(outline * 0.8); ctx.stroke(closeGadget)
    let depthBack = CGRect(x: frame.maxX - 20 * s - g, y: titleRect.midY - g / 2 + 7 * s, width: g * 0.72, height: g * 0.72)
    let depthFront = CGRect(x: frame.maxX - 20 * s - g * 0.72, y: titleRect.midY - g / 2 - 3 * s, width: g * 0.72, height: g * 0.72)
    ctx.setFillColor(color(0xFFFFFF)); ctx.fill(depthBack)
    ctx.setStrokeColor(navy); ctx.setLineWidth(outline * 0.8); ctx.stroke(depthBack)
    ctx.setFillColor(accent); ctx.fill(depthFront)
    ctx.stroke(depthFront)

    // File list
    let rowHeight = 68 * s
    let gap = 6 * s
    let nameWidths: [CGFloat] = [210, 150, 235, 175, 195]
    let sizeWidths: [CGFloat] = [62, 52, 72, 56, 64]
    let iconColors = [orange, blue, color(0x8FA0B8), color(0x8FA0B8), color(0x8FA0B8)]
    var top = titleRect.minY - 26 * s
    for i in 0..<rows {
        let row = CGRect(x: frame.minX + 24 * s, y: top - rowHeight, width: frame.width - 48 * s, height: rowHeight)
        let isSelected = selected == i
        if isSelected {
            fill(ctx, rounded(row, 14 * s), top: color(0x4C97FF), bottom: color(0x1F6BDB))
        }
        // icon: a drawer (folder) for the first rows, a document for the rest
        let icon = CGRect(x: row.minX + 16 * s, y: row.midY - 17 * s, width: 50 * s, height: 36 * s)
        let tint = isSelected ? color(0xFFFFFF) : iconColors[i % iconColors.count]
        ctx.setFillColor(tint)
        ctx.addPath(rounded(icon, 7 * s)); ctx.fillPath()
        if i < 2 {   // folder tab
            ctx.addPath(rounded(CGRect(x: icon.minX, y: icon.maxY - 4 * s, width: 22 * s, height: 11 * s), 4 * s)); ctx.fillPath()
        }
        let nameRect = CGRect(x: icon.maxX + 18 * s, y: row.midY - 8 * s, width: nameWidths[i % 5] * s, height: 16 * s)
        ctx.setFillColor(isSelected ? color(0xFFFFFF, 0.95) : color(0x4F6078, 0.8))
        ctx.addPath(rounded(nameRect, 8 * s)); ctx.fillPath()
        let sizeW = sizeWidths[i % 5] * s
        let sizeRect = CGRect(x: row.maxX - 18 * s - sizeW, y: row.midY - 6 * s, width: sizeW, height: 12 * s)
        ctx.setFillColor(isSelected ? color(0xFFFFFF, 0.7) : color(0x9AA7BA, 0.9))
        ctx.addPath(rounded(sizeRect, 6 * s)); ctx.fillPath()
        top -= rowHeight + gap
    }

    // Hard Amiga-style outline on top of everything
    ctx.setStrokeColor(navy); ctx.setLineWidth(outline)
    ctx.addPath(rounded(frame.insetBy(dx: outline / 2, dy: outline / 2), radius)); ctx.strokePath()
}

func render() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Icon plate: macOS grid, 824 pt rounded square centred on a 1024 canvas
    let plate = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    shadowed(ctx, offset: CGSize(width: 0, height: -16), blur: 34, alpha: 0.42) {
        ctx.addPath(plate); ctx.setFillColor(color(0x0A4FB5)); ctx.fillPath()
    }
    fill(ctx, plate, top: color(0x3F96FF), bottom: color(0x0B4DB0))
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    // soft light from the top, and a faint Workbench-style stripe pattern at the bottom
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.38), color(0xFFFFFF, 0)]), startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 560, options: [])
    ctx.setFillColor(color(0x000000, 0.045))
    var y: CGFloat = 100
    while y < 330 { ctx.fill(CGRect(x: 100, y: y, width: 824, height: 5)); y += 14 }
    ctx.restoreGState()

    // Two listers: source (blue) behind, destination (orange) in front
    drawWindow(ctx, frame: CGRect(x: 419.6, y: 465.8, width: 440, height: 365.2), accent: blue, rows: 3, selected: nil, scale: 0.924)
    drawWindow(ctx, frame: CGRect(x: 164.4, y: 193, width: 534.6, height: 484), accent: orange, rows: 4, selected: 1, scale: 1.1)

    // Glass edge: thin light rim and a gloss over the upper part
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.28)); ctx.setLineWidth(3)
    ctx.addPath(plate); ctx.strokePath()

    return ctx.makeImage()!
}

func png(_ image: CGImage, pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let master = render()
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Support/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, pixels) in sizes {
    try png(master, pixels: pixels).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try png(master, pixels: 1024).write(to: URL(fileURLWithPath: "Support/AppIcon-1024.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try task.run(); task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote Support/AppIcon.icns and Support/AppIcon-1024.png" : "iconutil failed")
