import AppKit

extension Notification.Name {
    static let shelfChanged = Notification.Name("OCShelfChanged")
}

/// Dropover-style holding area: file references collected from anywhere, dragged out
/// together later (copy by default, Shift/Cmd = move). Items are references, never copies.
final class Shelf {
    static let shared = Shelf()
    private let key = "shelfItems"

    private(set) var items: [URL] {
        didSet {
            UserDefaults.standard.set(items.map(\.path), forKey: key)
            NotificationCenter.default.post(name: .shelfChanged, object: nil)
        }
    }

    private init() {
        items = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let have = Set(items.map(\.path))
        let new = urls.map(\.standardizedFileURL).filter { !have.contains($0.path) }
        if !new.isEmpty { items += new }
    }

    func remove(_ url: URL) { items.removeAll { $0.path == url.path } }
    func clear() { if !items.isEmpty { items = [] } }

    /// Drops references whose file no longer exists (moved or deleted).
    func prune() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if alive.count != items.count { items = alive }
    }
}

final class ShelfView: NSView, NSDraggingSource {
    var onTransfer: (([URL], Bool) -> Void)?
    var onReveal: ((URL) -> Void)?

    private static let headerH: CGFloat = 24
    private static let boxH: CGFloat = 68
    private static let rowH: CGFloat = 22
    private static let maxRows = 8

    private var expanded = UserDefaults.standard.bool(forKey: "shelfExpanded") {
        didSet { UserDefaults.standard.set(expanded, forKey: "shelfExpanded"); relayout() }
    }
    private var dropHighlight = false { didSet { needsDisplay = true } }
    private var hoverRow: Int? { didSet { if hoverRow != oldValue { needsDisplay = true } } }
    private var heightConstraint: NSLayoutConstraint!
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    private var downTarget: Hit = .none
    private var dragging = false

    private let titleLabel = label(L("SHELF"), size: 10.5, weight: .bold)
    private lazy var listBtn = symbolButton("list.bullet", L("Show/hide list"), target: self, action: #selector(toggleList))
    private lazy var menuBtn = symbolButton("ellipsis.circle", L("Shelf actions"), target: self, action: #selector(showMenu(_:)))
    private lazy var clearBtn = symbolButton("xmark.circle", L("Clear shelf"), target: self, action: #selector(clearAll))

    private enum Hit: Equatable { case none, box, row(Int), remove(Int) }

    private var items: [URL] { Shelf.shared.items }
    private var visibleRows: Int { expanded ? min(items.count, Self.maxRows) : 0 }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL])
        titleLabel.font = Fonts.rounded(10.5, .bold)
        [titleLabel, listBtn, menuBtn, clearBtn].forEach(addSubview)
        let buttons = NSStackView(views: [listBtn, menuBtn, clearBtn])
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        heightConstraint = heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            heightConstraint,
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerH / 2),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            buttons.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed), name: .shelfChanged, object: nil)
        nc.addObserver(self, selector: #selector(redraw), name: .folderSizesUpdated, object: nil)
        nc.addObserver(self, selector: #selector(prune), name: NSApplication.didBecomeActiveNotification, object: nil)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { relayout() }
    @objc private func redraw() { needsDisplay = true }
    @objc private func prune() { Shelf.shared.prune() }

    func applyTheme() {
        let t = Theme.current
        titleLabel.textColor = t.secondary
        [listBtn, menuBtn, clearBtn].forEach { $0.contentTintColor = t.secondary }
        needsDisplay = true
    }

    private func relayout() {
        let empty = items.isEmpty
        listBtn.isHidden = empty
        menuBtn.isHidden = empty
        clearBtn.isHidden = empty
        listBtn.contentTintColor = expanded ? Theme.current.accent : Theme.current.secondary
        titleLabel.stringValue = empty ? L("SHELF") : L("SHELF") + "  ·  \(items.count)"
        var h = Self.headerH + Self.boxH + 4
        if visibleRows > 0 { h += CGFloat(visibleRows) * Self.rowH + 6 }
        if expanded, items.count > Self.maxRows { h += Self.rowH }
        heightConstraint.constant = h
        needsDisplay = true
    }

    // MARK: Geometry

    private var boxRect: NSRect {
        NSRect(x: 2, y: Self.headerH, width: bounds.width - 4, height: Self.boxH)
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 2, y: boxRect.maxY + 6 + CGFloat(i) * Self.rowH, width: bounds.width - 4, height: Self.rowH)
    }

    private func removeRect(_ i: Int) -> NSRect {
        let r = rowRect(i)
        return NSRect(x: r.maxX - 22, y: r.minY + 3, width: 16, height: 16)
    }

    private func hit(_ p: NSPoint) -> Hit {
        if boxRect.contains(p) { return items.isEmpty ? .none : .box }
        for i in 0..<visibleRows where rowRect(i).contains(p) {
            return removeRect(i).insetBy(dx: -3, dy: -3).contains(p) ? .remove(i) : .row(i)
        }
        return .none
    }

    // MARK: Drawing

    private func totalSize() -> String {
        var total: Int64 = 0
        var pending = false
        for u in items {
            let n = FileNode.node(for: u)
            if n.isContainer {
                if let s = FolderSizer.shared.size(for: n.path) { total += s } else { pending = true }
            } else {
                total += n.size
            }
        }
        return (pending ? "≥ " : "") + Fmt.size(total)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Theme.current
        let box = boxRect
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        (dropHighlight ? t.accent.withAlphaComponent(0.14) : t.column.withAlphaComponent(items.isEmpty ? 0.5 : 0.9)).setFill()
        path.fill()
        path.lineWidth = dropHighlight ? 2 : 1
        if items.isEmpty || dropHighlight { path.setLineDash([5, 4], count: 2, phase: 0) }
        (dropHighlight ? t.accent : t.separator).setStroke()
        path.stroke()

        if items.isEmpty {
            let sym = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            let tint = dropHighlight ? t.accent : t.tertiary
            if let sym = sym?.tinted(tint) {
                sym.draw(in: NSRect(x: box.midX - sym.size.width / 2, y: box.minY + 12,
                                    width: sym.size.width, height: sym.size.height))
            }
            drawText(L("Drop files here"), in: NSRect(x: box.minX, y: box.minY + 40, width: box.width, height: 16),
                     font: .systemFont(ofSize: 11), color: tint, align: .center)
            return
        }

        // Fanned stack of up to 3 icons
        let shown = Array(items.prefix(3))
        let iconSize: CGFloat = 40
        for (k, u) in shown.enumerated().reversed() {
            let img = NSWorkspace.shared.icon(forFile: u.path)
            let off = CGFloat(k) * 7
            let r = NSRect(x: box.minX + 10 + off, y: box.minY + 12 + off * 0.35, width: iconSize, height: iconSize)
            NSGraphicsContext.saveGraphicsState()
            let rot = NSAffineTransform()
            rot.translateX(by: r.midX, yBy: r.midY)
            rot.rotate(byDegrees: CGFloat(k) * 7)
            rot.translateX(by: -r.midX, yBy: -r.midY)
            rot.concat()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let tx = box.minX + 10 + iconSize + CGFloat(shown.count - 1) * 7 + 10
        let tw = box.maxX - tx - 8
        let title = items.count == 1 ? items[0].lastPathComponent : Fmt.items(items.count)
        drawText(title, in: NSRect(x: tx, y: box.minY + 12, width: tw, height: 16),
                 font: .systemFont(ofSize: 12, weight: .semibold), color: t.text)
        drawText(totalSize(), in: NSRect(x: tx, y: box.minY + 29, width: tw, height: 14),
                 font: FileRowView.smallFont, color: t.secondary)
        drawText(L("⌘ held: move"), in: NSRect(x: tx, y: box.minY + 45, width: tw, height: 14),
                 font: .systemFont(ofSize: 10), color: t.tertiary)

        for i in 0..<visibleRows {
            let r = rowRect(i)
            let u = items[i]
            if hoverRow == i {
                t.hover.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.draw(in: NSRect(x: r.minX + 6, y: r.minY + 3, width: 16, height: 16),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawText(u.lastPathComponent, in: NSRect(x: r.minX + 28, y: r.minY + 3, width: r.width - 56, height: 16),
                     font: .systemFont(ofSize: 12), color: t.text)
            if hoverRow == i, let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))?.tinted(t.secondary) {
                let rr = removeRect(i)
                x.draw(in: NSRect(x: rr.midX - x.size.width / 2, y: rr.midY - x.size.height / 2,
                                  width: x.size.width, height: x.size.height))
            }
        }
        if expanded, items.count > Self.maxRows {
            let r = rowRect(Self.maxRows)
            drawText(L("+%d more", items.count - Self.maxRows), in: NSRect(x: r.minX + 28, y: r.minY + 3, width: r.width - 30, height: 16),
                     font: .systemFont(ofSize: 11), color: t.tertiary)
        }
    }

    private func drawText(_ s: String, in r: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingMiddle
        (s as NSString).draw(in: r, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        if case .row(let i) = hit(convert(event.locationInWindow, from: nil)) { hoverRow = i }
        else if case .remove(let i) = hit(convert(event.locationInWindow, from: nil)) { hoverRow = i }
        else { hoverRow = nil }
    }

    override func mouseExited(with event: NSEvent) { hoverRow = nil }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        downTarget = hit(p)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        let urls: [URL]
        switch downTarget {
        case .box: urls = items
        case .row(let i): urls = [items[i]]
        default: return
        }
        dragging = true
        let dragItems = urls.enumerated().map { k, u -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: u as NSURL)
            let img = NSWorkspace.shared.icon(forFile: u.path)
            let off = CGFloat(min(k, 4)) * 6
            d.setDraggingFrame(NSRect(x: p.x - 16 + off, y: p.y - 16 + off, width: 32, height: 32), contents: img)
            return d
        }
        let s = beginDraggingSession(with: dragItems, event: event, source: self)
        s.animatesToStartingPositionsOnCancelOrFail = true
        s.draggingFormation = urls.count > 1 ? .stack : .none
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil; downTarget = .none }
        guard !dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hit(p) == downTarget else { return }
        switch downTarget {
        case .box: expanded.toggle()
        case .row(let i): onReveal?(items[i])
        case .remove(let i): Shelf.shared.remove(items[i])
        case .none: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        // Drops into our panes finish asynchronously; prune again once the copy/move is done.
        Shelf.shared.prune()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Shelf.shared.prune() }
    }

    // MARK: Drop target

    private func incoming(_ info: NSDraggingInfo) -> [URL] {
        guard info.draggingSource as? ShelfView !== self else { return [] }
        return ColumnsView.urls(info)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !incoming(sender).isEmpty
        dropHighlight = ok
        return ok ? .link : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlight ? .link : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let urls = incoming(sender)
        guard !urls.isEmpty else { return false }
        Shelf.shared.add(urls)
        return true
    }

    // MARK: Actions

    @objc private func toggleList() { expanded.toggle() }
    @objc private func clearAll() { Shelf.shared.clear() }

    @objc private func showMenu(_ sender: NSButton) {
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func buildMenu() -> NSMenu {
        let urls = items
        let m = NSMenu()
        m.addItem(ClosureMenuItem(L("Copy to Active Folder"), symbol: "doc.on.doc") { [weak self] in self?.onTransfer?(urls, false) })
        m.addItem(ClosureMenuItem(L("Move to Active Folder"), symbol: "folder") { [weak self] in self?.onTransfer?(urls, true) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Show in Finder"), symbol: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })
        m.addItem(ClosureMenuItem(L("Copy Paths"), symbol: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        })
        m.addItem(ClosureMenuItem(L("Share…"), symbol: "square.and.arrow.up") { [weak self] in
            guard let self else { return }
            NSSharingServicePicker(items: urls).show(relativeTo: self.boxRect, of: self, preferredEdge: .maxX)
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Clear Shelf"), symbol: "xmark.circle") { Shelf.shared.clear() })
        return m
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
