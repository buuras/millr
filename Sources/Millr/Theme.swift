import AppKit

extension Notification.Name {
    static let themeChanged = Notification.Name("OCThemeChanged")
}

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

/// Color set used by every custom-drawn view.
struct Theme {
    let id: String
    let name: String
    let appearance: NSAppearance?
    /// window, toolbar, tab bar, gutters
    let chrome: NSColor
    let sidebar: NSColor?
    /// column / list background
    let column: NSColor
    /// collapsed ancestor strips
    let strip: NSColor
    let preview: NSColor
    let text: NSColor
    let secondary: NSColor
    let tertiary: NSColor
    let accent: NSColor
    let selection: NSColor
    let selectionText: NSColor
    let selectionInactive: NSColor
    let separator: NSColor
    let hover: NSColor
    let ageMinute: NSColor
    let ageHour: NSColor
    let ageDay: NSColor
    let ageMonth: NSColor
    let ageYear: NSColor

    var isDark: Bool {
        (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static let system = Theme(
        id: "system", name: "Sistem", appearance: nil,
        chrome: .windowBackgroundColor, sidebar: nil, column: .controlBackgroundColor,
        strip: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hex(0x2A2A2D) : hex(0xEDEDF0)
        },
        preview: .controlBackgroundColor,
        text: .labelColor, secondary: .secondaryLabelColor, tertiary: .tertiaryLabelColor,
        accent: .controlAccentColor, selection: .controlAccentColor, selectionText: .white,
        selectionInactive: .unemphasizedSelectedContentBackgroundColor, separator: .separatorColor,
        hover: NSColor.labelColor.withAlphaComponent(0.07),
        ageMinute: .systemRed, ageHour: .systemOrange, ageDay: .systemGreen, ageMonth: .systemBlue, ageYear: .systemGray)

    // Nord palette — Polar Night 2E3440 3B4252 434C5E 4C566A, Snow Storm D8DEE9 E5E9F0 ECEFF4,
    // Frost 8FBCBB 88C0D0 81A1C1 5E81AC, Aurora BF616A D08770 EBCB8B A3BE8C B48EAD
    static let nord = Theme(
        id: "nord", name: "Nord", appearance: NSAppearance(named: .aqua),
        chrome: hex(0xE5E9F0), sidebar: hex(0xDCE2EB), column: hex(0xF4F6F9), strip: hex(0xD8DEE9),
        preview: hex(0xECEFF4),
        text: hex(0x2E3440), secondary: hex(0x4C566A), tertiary: hex(0x7B88A1),
        accent: hex(0x5E81AC), selection: hex(0x5E81AC), selectionText: .white,
        selectionInactive: hex(0xD8DEE9), separator: hex(0xD3DAE4), hover: hex(0x81A1C1, 0.16),
        ageMinute: hex(0xBF616A), ageHour: hex(0xD08770), ageDay: hex(0x8FA876), ageMonth: hex(0x5E81AC), ageYear: hex(0x7B88A1))

    static let nordNight = Theme(
        id: "nordNight", name: "Nord Gece", appearance: NSAppearance(named: .darkAqua),
        chrome: hex(0x2B303B), sidebar: hex(0x262A33), column: hex(0x2E3440), strip: hex(0x3B4252),
        preview: hex(0x313744),
        text: hex(0xECEFF4), secondary: hex(0xD8DEE9, 0.72), tertiary: hex(0x7B88A1),
        accent: hex(0x88C0D0), selection: hex(0x5E81AC), selectionText: .white,
        selectionInactive: hex(0x434C5E), separator: hex(0x3B4252), hover: hex(0x88C0D0, 0.10),
        ageMinute: hex(0xBF616A), ageHour: hex(0xD08770), ageDay: hex(0xA3BE8C), ageMonth: hex(0x88C0D0), ageYear: hex(0x7B88A1))

    static let dark = Theme(
        id: "dark", name: "Koyu", appearance: NSAppearance(named: .darkAqua),
        chrome: hex(0x1C1D20), sidebar: hex(0x18191C), column: hex(0x232428), strip: hex(0x2C2E33),
        preview: hex(0x26272B),
        text: hex(0xE8E8EA), secondary: hex(0xA2A5AC), tertiary: hex(0x6E727A),
        accent: hex(0x4C8DFF), selection: hex(0x2F6FEB), selectionText: .white,
        selectionInactive: hex(0x3A3C42), separator: hex(0x313338), hover: hex(0xFFFFFF, 0.06),
        ageMinute: hex(0xFF6B6B), ageHour: hex(0xFFA94D), ageDay: hex(0x51CF66), ageMonth: hex(0x4DABF7), ageYear: hex(0x868E96))

    static let all: [Theme] = [system, nord, nordNight, dark]

    static var current: Theme {
        all.first { $0.id == Prefs.shared.themeID } ?? system
    }
}

enum Fonts {
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}

/// Split view whose dividers follow the theme (thick = gutter, thin = hairline).
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        dividerStyle == .thin ? Theme.current.separator : Theme.current.chrome
    }
}

/// Rounded, inset selection like modern macOS lists.
final class ThemedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let t = Theme.current
        (isEmphasized ? t.selection : t.selectionInactive).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

extension Theme {
    /// Maps the system label/accent colors used when building views to this theme.
    private func mapped(_ c: NSColor?) -> NSColor? {
        guard let c else { return nil }
        if c == NSColor.labelColor { return text }
        if c == NSColor.secondaryLabelColor { return secondary }
        if c == NSColor.tertiaryLabelColor { return tertiary }
        if c == NSColor.controlAccentColor { return accent }
        return nil
    }

    /// Recolors labels, symbol images and buttons in a freshly built view tree.
    func retint(_ v: NSView) {
        if let tf = v as? NSTextField, let m = mapped(tf.textColor) { tf.textColor = m }
        if let iv = v as? NSImageView, let m = mapped(iv.contentTintColor) { iv.contentTintColor = m }
        if let b = v as? NSButton, let m = mapped(b.contentTintColor) { b.contentTintColor = m }
        v.subviews.forEach(retint)
    }
}
