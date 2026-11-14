import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command,
         symbol: String? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Click-able plain view (used by sidebar rows and tabs).
class HoverView: NSView {
    var onClick: (() -> Void)?
    var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

func symbolButton(_ name: String, _ tip: String, target: AnyObject?, action: Selector) -> NSButton {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage()
    let b = NSButton(image: img, target: target, action: action)
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.toolTip = tip
    b.contentTintColor = .secondaryLabelColor
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: 22).isActive = true
    b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return b
}

func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

/// Simple horizontal tab strip.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(titles: [(String, NSImage?)], selected: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in titles.enumerated() {
            let v = TabItemView(title: t.0, icon: t.1, selected: i == selected, closable: titles.count > 1)
            Theme.current.retint(v)
            v.onClick = { [weak self] in self?.onSelect?(i) }
            v.onCloseTab = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(v)
        }
        let add = symbolButton("plus", "Yeni sekme (⌘T)", target: self, action: #selector(addTab))
        add.contentTintColor = Theme.current.secondary
        stack.addArrangedSubview(add)
    }

    @objc private func addTab() { onAdd?() }
}

final class TabItemView: HoverView {
    var onCloseTab: (() -> Void)?
    private let selected: Bool

    init(title: String, icon: NSImage?, selected: Bool, closable: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let iv = NSImageView(image: icon ?? NSImage())
        iv.translatesAutoresizingMaskIntoConstraints = false
        let l = label(title, size: 11.5, weight: selected ? .semibold : .medium,
                      color: selected ? .labelColor : .secondaryLabelColor)
        l.font = Fonts.rounded(11.5, selected ? .semibold : .medium)
        addSubview(iv)
        addSubview(l)
        var cons = [
            widthAnchor.constraint(equalToConstant: 150),
            heightAnchor.constraint(equalToConstant: 22),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 14), iv.heightAnchor.constraint(equalToConstant: 14),
            l.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if closable {
            let x = symbolButton("xmark", "Sekmeyi kapat (⌘W)", target: self, action: #selector(closeTab))
            (x.image)?.size = NSSize(width: 8, height: 8)
            addSubview(x)
            cons += [
                x.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                x.centerYAnchor.constraint(equalTo: centerYAnchor),
                l.trailingAnchor.constraint(lessThanOrEqualTo: x.leadingAnchor, constant: -2),
            ]
        } else {
            cons.append(l.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(cons)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTab() { onCloseTab?() }

    override func otherMouseUp(with event: NSEvent) { onCloseTab?() }

    override func draw(_ dirtyRect: NSRect) {
        let t = Theme.current
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
        if selected {
            t.column.setFill()
            p.fill()
            t.separator.setStroke()
            p.stroke()
        } else if isHovered {
            t.hover.setFill()
            p.fill()
        }
    }
}
