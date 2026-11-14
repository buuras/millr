// Renders the Millr app icon (1024×1024 PNG) from plain geometric shapes.
// Usage: swift tools/make-icon.swift out.png
// An "M" made of three separate columns: the outer ones have sloped tops, the middle one
// is pointed. Nord palette on a Polar Night squircle.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

// Body: Polar Night squircle with soft drop shadow
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: hex(0x434C5E), ending: hex(0x2E3440))!.draw(in: bodyPath, angle: -90)
NSGraphicsContext.restoreGraphicsState()
bodyPath.addClip()

// A filled polygon whose corners are rounded by stroking it with a round join.
func column(_ pts: [NSPoint], _ color: UInt32) {
    let p = NSBezierPath()
    p.move(to: pts[0])
    pts.dropFirst().forEach { p.line(to: $0) }
    p.close()
    p.lineJoinStyle = .round
    p.lineWidth = 36
    hex(color).setFill()
    hex(color).setStroke()
    p.fill()
    p.stroke()
}

let bottom: CGFloat = 250, top: CGFloat = 780, middleTop: CGFloat = 560
let w: CGFloat = 150, gap: CGFloat = 34, r: CGFloat = 18
let x0 = (size - (3 * w + 2 * gap)) / 2
let x1 = x0 + w + gap, x2 = x1 + w + gap

// Left column: top slopes down towards the middle
column([NSPoint(x: x0 + r, y: bottom + r), NSPoint(x: x0 + w - r, y: bottom + r),
        NSPoint(x: x0 + w - r, y: top - 120), NSPoint(x: x0 + r, y: top - r)], 0x81A1C1)
// Middle column: lower, with a V notch on top
column([NSPoint(x: x1 + r, y: bottom + r), NSPoint(x: x1 + w - r, y: bottom + r),
        NSPoint(x: x1 + w - r, y: middleTop), NSPoint(x: x1 + w / 2, y: middleTop - 70),
        NSPoint(x: x1 + r, y: middleTop)], 0x88C0D0)
// Right column: mirror of the left one
column([NSPoint(x: x2 + r, y: bottom + r), NSPoint(x: x2 + w - r, y: bottom + r),
        NSPoint(x: x2 + w - r, y: top - r), NSPoint(x: x2 + r, y: top - 120)], 0x8FBCBB)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
