import AppKit

/// ⌘K: fuzzy jump to folders (history, places, groups, clouds, smart folders),
/// items of the active folder, typed paths, menu commands and Spotlight search.
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    struct Item {
        enum Kind { case folder, file, command, path, search }
        var kind: Kind
        var title: String
        var subtitle: String
        var icon: NSImage?
        /// Icon resolved only when the row is drawn (file icons are slow to fetch in bulk).
        var iconPath: String? = nil
        var shortcut: String = ""
        var boost: Double = 0
        var run: (_ alternate: Bool) -> Void
    }

    weak var controller: MainWindowController?
    private var panel: NSPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let hint = label("", size: 11)
    private var base: [Item] = []
    private var results: [Item] = []

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        guard let parent = controller?.window else { return }
        if panel == nil { build() }
        guard let panel else { return }
        base = collect()
        field.stringValue = ""
        filter()
        let w: CGFloat = 640, h: CGFloat = 420
        let f = parent.frame
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h - 110, width: w, height: h), display: false)
        applyTheme()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        controller?.window?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        if CommandLine.arguments.contains("--palette") { return }   // debug snapshots run unfocused
        close()
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovable = false
        p.hasShadow = true
        p.delegate = self
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        glass.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = "Klasöre git, komut çalıştır, yol yaz ( / ~ ) …"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(clicked)
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.stringValue = "↩ aç   ⌘↩ diğer panelde aç   ↑↓ seç   esc kapat"
        hint.alignment = .center

        [glass, field, sep, scroll, hint].forEach(bg.addSubview)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: bg.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -18),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
        ])
        p.contentView = bg
        panel = p
    }

    private func applyTheme() {
        let t = Theme.current
        panel?.appearance = t.appearance
        field.textColor = t.text
        hint.textColor = t.tertiary
        (panel?.contentView?.subviews.first as? NSImageView)?.contentTintColor = t.secondary
    }

    // MARK: Sources

    private func folderItem(_ u: URL, title: String? = nil, boost: Double, icon: NSImage? = nil) -> Item {
        let path = u.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sub = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        // Localized names ("İndirilenler") only for the home folder level; displayName is slow in bulk.
        let near = path == home || u.deletingLastPathComponent().path == home
        let name = title ?? (near ? FileManager.default.displayName(atPath: path) : u.lastPathComponent)
        return Item(kind: .folder, title: name, subtitle: String(sub),
                    icon: icon, iconPath: path, boost: boost) { [weak self] alt in
            self?.controller?.go(to: u, otherPane: alt)
        }
    }

    private func collect() -> [Item] {
        guard let c = controller else { return [] }
        var items: [Item] = []
        var seen = Set<String>()
        func addFolder(_ u: URL, title: String? = nil, boost: Double, icon: NSImage? = nil) {
            guard seen.insert(u.path).inserted else { return }
            items.append(folderItem(u, title: title, boost: boost, icon: icon))
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for (u, s) in History.shared.all where fm.fileExists(atPath: u.path) { addFolder(u, boost: min(s, 30)) }
        for g in Prefs.shared.groups { for p in g.paths { addFolder(URL(fileURLWithPath: p), boost: 6) } }
        for p in Cloud.providers() { addFolder(p.url, title: p.name, boost: 5) }
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] {
            addFolder(home.appendingPathComponent(name), boost: 4)
        }
        addFolder(home, boost: 4)
        addFolder(URL(fileURLWithPath: "/Applications"), boost: 3)
        for f in SmartFolders.shared.folders {
            let img = NSImage(systemSymbolName: f.symbol, accessibilityDescription: nil)
            items.append(Item(kind: .folder, title: f.name, subtitle: "Akıllı klasör", icon: img, boost: 4) { [weak c] alt in
                c?.go(to: SmartFolders.shared.url(for: f), otherPane: alt)
            })
        }
        // Items of the active folder
        let folder = c.activePane.currentFolderNode
        for n in folder.children.prefix(2000) {
            let node = n
            items.append(Item(kind: n.isDirectory ? .folder : .file, title: n.name, subtitle: "Bu klasörde",
                              icon: nil, iconPath: n.path, boost: 2) { [weak c] alt in
                if node.isDirectory { c?.go(to: node.url, otherPane: alt) } else { c?.activePane.reveal(node.url) }
            })
        }
        // Menu commands
        if let menu = NSApp.mainMenu { collectCommands(menu, path: [], into: &items) }
        return items
    }

    private func collectCommands(_ menu: NSMenu, path: [String], into items: inout [Item]) {
        menu.update()
        for mi in menu.items where !mi.isSeparatorItem && !mi.isHidden {
            if let sub = mi.submenu {
                if path.isEmpty && sub.title == "Pencere" { continue }
                collectCommands(sub, path: path + [mi.title], into: &items)
                continue
            }
            guard let action = mi.action, mi.isEnabled, path.count >= 1 else { continue }
            let item = mi
            var key = ""
            if !mi.keyEquivalent.isEmpty {
                let m = mi.keyEquivalentModifierMask
                if m.contains(.control) { key += "⌃" }
                if m.contains(.option) { key += "⌥" }
                if m.contains(.shift) { key += "⇧" }
                if m.contains(.command) { key += "⌘" }
                key += mi.keyEquivalent == "\u{8}" ? "⌫" : mi.keyEquivalent.uppercased()
            }
            let img = mi.image ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            items.append(Item(kind: .command, title: mi.title, subtitle: path.joined(separator: " › "),
                              icon: img, shortcut: key, boost: 1) { _ in
                NSApp.sendAction(action, to: item.target, from: item)
            })
        }
    }

    // MARK: Matching

    private static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i"))
    }

    /// Subsequence match: word-start and consecutive hits score higher. nil if no match.
    static func score(_ q: [Character], _ text: String) -> Double? {
        if q.isEmpty { return 0 }
        let t = fold(text)
        var qi = 0, score = 0.0, prev = -2
        for (i, ch) in t.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var s = 1.0
            if i == 0 { s += 3 } else if " -_./›".contains(t[i - 1]) { s += 2 }
            if prev == i - 1 { s += 2 }
            score += s
            prev = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - Double(t.count) * 0.02
    }

    private func filter() {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            out = pathItems(raw)
        } else {
            let q = Self.fold(raw).filter { $0 != " " }
            var scored: [(Double, Item)] = []
            for it in base {
                if raw.isEmpty {
                    guard it.kind == .folder, it.boost > 0 else { continue }
                    scored.append((it.boost, it))
                } else if let s = Self.score(q, it.title) ?? Self.score(q, it.subtitle).map({ $0 * 0.4 }) {
                    scored.append((s * 3 + it.boost, it))
                }
            }
            scored.sort { $0.0 > $1.0 }
            out = scored.prefix(60).map(\.1)
            if raw.count >= 2, let c = controller {
                let scope = c.activePane.currentFolder
                let home = FileManager.default.homeDirectoryForCurrentUser
                out.append(Item(kind: .search, title: "Spotlight'ta ara: “\(raw)”", subtitle: "Ana klasör (~) içinde, ad ve içerik",
                                icon: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)) { [weak c] alt in
                    c?.go(to: SmartFolders.shared.search(raw, in: home), otherPane: alt)
                })
                if !VirtualFolders.isVirtual(scope) {
                    out.append(Item(kind: .search, title: "Bu klasörde ara: “\(raw)”", subtitle: scope.path,
                                    icon: NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)) { [weak c] alt in
                        c?.go(to: SmartFolders.shared.search(raw, in: scope), otherPane: alt)
                    })
                }
            }
        }
        results = out
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
    }

    /// Typed path: the folder itself plus completions of its last component.
    private func pathItems(_ raw: String) -> [Item] {
        let expanded = (raw as NSString).expandingTildeInPath
        let fm = FileManager.default
        var out: [Item] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            let u = URL(fileURLWithPath: expanded)
            if isDir.boolValue {
                out.append(folderItem(u, boost: 0))
            } else {
                out.append(Item(kind: .path, title: u.lastPathComponent, subtitle: expanded,
                                icon: nil, iconPath: expanded) { [weak self] _ in self?.controller?.activePane.reveal(u) })
            }
        }
        let dir = expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent
        let q = Self.fold(prefix)
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") || prefix.hasPrefix(".") }
        for n in names.sorted() where q.isEmpty || Self.fold(n).starts(with: q) {
            let full = (dir as NSString).appendingPathComponent(n)
            guard full != expanded else { continue }
            var d: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &d)
            let u = URL(fileURLWithPath: full)
            if d.boolValue { out.append(folderItem(u, boost: 0)) }
            else {
                out.append(Item(kind: .path, title: n, subtitle: full, icon: nil, iconPath: full) { [weak self] _ in
                    self?.controller?.activePane.reveal(u)
                })
            }
            if out.count > 60 { break }
        }
        return out
    }

    // MARK: Keys / execution

    func controlTextDidChange(_ obj: Notification) { filter() }
    func debugSetText(_ s: String) { field.stringValue = s; filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            execute(alternate: NSEvent.modifierFlags.contains(.command)); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab completes a typed path with the selected folder.
            let r = table.selectedRow
            if results.indices.contains(r), field.stringValue.hasPrefix("/") || field.stringValue.hasPrefix("~") {
                let s = results[r].subtitle
                field.stringValue = results[r].kind == .folder ? s + "/" : s
                filter()
            }
            return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(results.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func clicked() { if table.clickedRow >= 0 { execute(alternate: false) } }

    private func execute(alternate: Bool) {
        let r = table.selectedRow
        guard results.indices.contains(r) else { NSSound.beep(); return }
        let item = results[r]
        close()
        DispatchQueue.main.async { item.run(alternate) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v = tableView.makeView(withIdentifier: .init("pc"), owner: nil) as? PaletteCell ?? PaletteCell()
        v.identifier = .init("pc")
        v.item = results[row]
        return v
    }
}

private final class PaletteCell: NSTableCellView {
    private static let iconCache = NSCache<NSString, NSImage>()

    private static func icon(forPath p: String) -> NSImage {
        if let i = iconCache.object(forKey: p as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: p)
        iconCache.setObject(i, forKey: p as NSString)
        return i
    }

    var item: CommandPalette.Item? { didSet { needsDisplay = true } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let t = Theme.current
        let emph = backgroundStyle == .emphasized
        let text = emph ? t.selectionText : t.text
        let sec = emph ? t.selectionText.withAlphaComponent(0.8) : t.secondary
        var icon = item.icon ?? item.iconPath.map(Self.icon(forPath:))
        if let i = icon, i.isTemplate || item.kind == .command || item.kind == .search {
            icon = i.withSymbolConfiguration(.init(paletteColors: [emph ? t.selectionText : t.accent])) ?? i
        }
        icon?.draw(in: NSRect(x: 12, y: bounds.midY - 11, width: 22, height: 22),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        var right = bounds.maxX - 12
        if !item.shortcut.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: sec]
            let sz = (item.shortcut as NSString).size(withAttributes: a)
            (item.shortcut as NSString).draw(at: NSPoint(x: right - sz.width, y: bounds.midY - sz.height / 2), withAttributes: a)
            right -= sz.width + 12
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        (item.title as NSString).draw(in: NSRect(x: 44, y: 4, width: right - 44, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: text, .paragraphStyle: p])
        (item.subtitle as NSString).draw(in: NSRect(x: 44, y: 21, width: right - 44, height: 15), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: sec, .paragraphStyle: p])
    }
}
