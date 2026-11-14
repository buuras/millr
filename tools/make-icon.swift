// Renders the OC Commander app icon (1024×1024 PNG) from plain geometric shapes.
// Usage: swift tools/make-icon.swift out.png
// Left: two stacked panes made of column blocks (thin strips → wide columns).
// Right: tall preview panel with a sun and a mountain. Nord palette.
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

func rr(_ r: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

// Body: Polar Night squircle with soft drop shadow
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
rr(body, 186, hex(0x2E3440))
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: hex(0x434C5E), ending: hex(0x2E3440))!
    .draw(in: NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186), angle: -90)

let inset: CGFloat = 92
let content = body.insetBy(dx: inset, dy: inset)       // 640×640 drawing area
let gap: CGFloat = 26
let previewW: CGFloat = 196
let panesW = content.width - previewW - gap
let paneH = (content.height - gap) / 2

/// One pane: two thin strips, then three columns growing in width.
func pane(_ r: NSRect, base: NSColor, active: Bool) {
    rr(r, 34, base)
    let pad: CGFloat = 20
    let inner = r.insetBy(dx: pad, dy: pad)
    let strip: CGFloat = 20
    var x = inner.minX
    for _ in 0..<2 {
        rr(NSRect(x: x, y: inner.minY, width: strip, height: inner.height), 10, hex(0x2E3440, 0.35))
        x += strip + 10
    }
    let widths: [CGFloat] = [0.27, 0.30, 0.43].map { $0 * (inner.maxX - x - 20) }
    for (i, w) in widths.enumerated() {
        let col = NSRect(x: x, y: inner.minY, width: w, height: inner.height)
        rr(col, 16, hex(0xECEFF4, i == 2 ? 1 : 0.92))
        // one selected row per column, stepping down like a path
        let rowH: CGFloat = 30
        let y = col.maxY - 22 - rowH - CGFloat(i) * (rowH + 12)
        rr(NSRect(x: col.minX + 10, y: y, width: col.width - 20, height: rowH), 10, active ? hex(0x5E81AC) : hex(0x81A1C1))
        if i == 2 {
            // colored age dots in the detailed column
            let dots = [hex(0xA3BE8C), hex(0xEBCB8B), hex(0xBF616A)]
            for (d, c) in dots.enumerated() {
                let cy = y - 34 - CGFloat(d) * 34
                guard cy > col.minY + 8 else { break }
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: col.maxX - 40, y: cy, width: 22, height: 22)).fill()
            }
        }
        x += w + 10
    }
}

pane(NSRect(x: content.minX, y: content.minY + paneH + gap, width: panesW, height: paneH), base: hex(0x88C0D0), active: true)
pane(NSRect(x: content.minX, y: content.minY, width: panesW, height: paneH), base: hex(0x81A1C1), active: false)

// Preview: snow panel with sun + mountains
let pv = NSRect(x: content.maxX - previewW, y: content.minY, width: previewW, height: content.height)
rr(pv, 34, hex(0xECEFF4))
let pic = NSRect(x: pv.minX + 20, y: pv.midY - 20, width: pv.width - 40, height: pv.height / 2)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: pic, xRadius: 22, yRadius: 22).addClip()
hex(0x8FBCBB).setFill()
pic.fill()
hex(0xEBCB8B).setFill()
NSBezierPath(ovalIn: NSRect(x: pic.maxX - 78, y: pic.maxY - 82, width: 52, height: 52)).fill()
let m = NSBezierPath()
m.move(to: NSPoint(x: pic.minX - 10, y: pic.minY))
m.line(to: NSPoint(x: pic.minX + 58, y: pic.minY + 150))
m.line(to: NSPoint(x: pic.minX + 102, y: pic.minY + 80))
m.line(to: NSPoint(x: pic.minX + 128, y: pic.minY + 112))
m.line(to: NSPoint(x: pic.maxX + 10, y: pic.minY))
m.close()
hex(0xA3BE8C).setFill()
m.fill()
NSGraphicsContext.restoreGraphicsState()
// info blocks below the picture (solid blocks, no text-like lines)
let blockH: CGFloat = 46
for i in 0..<3 {
    let y = pic.minY - 26 - blockH - CGFloat(i) * (blockH + 16)
    guard y > pv.minY + 14 else { break }
    rr(NSRect(x: pv.minX + 20, y: y, width: pv.width - 40, height: blockH), 14,
       [hex(0xD8DEE9), hex(0xE5E9F0), hex(0xD8DEE9)][i])
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
