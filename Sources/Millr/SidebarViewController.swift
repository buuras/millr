import AppKit

/// Left column: drives with usage bars, standard places and user-defined groups.
final class SidebarViewController: NSViewController {
    var onOpen: ((URL) -> Void)?
    var onReveal: ((URL) -> Void)?
    var onOpenInOtherPane: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var currentFolder: (() -> URL?)?
    var onNewSmartFolder: (() -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    let shelf = ShelfView()
    private var timer: Timer?

    override func loadView() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // Shelf pinned to the bottom-left; the place list scrolls above it.
        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(shelf)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: shelf.topAnchor, constant: -6),
            shelf.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            shelf.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            shelf.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        reload()

        let wnc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            wnc.addObserver(self, selector: #selector(reloadNote), name: n, object: nil)
        }
        for n in [Notification.Name.favoritesChanged, .frequentChanged, .smartFoldersChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(reloadNote), name: n, object: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.reload() }
    }

    private var reloadScheduled = false

    /// Coalesced: the frequent list can change on every folder hop, and a rebuild costs a few ms.
    @objc private func reloadNote() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        defer { Theme.current.retint(stack) }
        scroll.drawsBackground = Theme.current.sidebar != nil
        scroll.backgroundColor = Theme.current.sidebar ?? .clear
        if let bg = Theme.current.sidebar {
            view.wantsLayer = true
            view.layer?.backgroundColor = bg.cgColor
        } else {
            view.layer?.backgroundColor = nil
        }
        shelf.applyTheme()

        addHeader(SectionHeader(title: L("Disks")))
        for vol in volumes() {
            let row = SidebarRow(title: vol.name, icon: NSWorkspace.shared.icon(forFile: vol.url.path),
                                 usage: vol.total > 0 ? Double(vol.total - vol.free) / Double(vol.total) : nil,
                                 subtitle: vol.total > 0 ? L("%@ free / %@", Fmt.size(vol.free), Fmt.size(vol.total)) : nil)
            add(row, url: vol.url, group: nil)
        }

        addHeader(SectionHeader(title: L("Locations")))
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let places: [(String, URL, String)] = [
            (NSUserName(), home, "house"),
            (L("Desktop"), home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            (L("Documents"), home.appendingPathComponent("Documents"), "doc"),
            (L("Downloads"), home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            (L("Applications"), URL(fileURLWithPath: "/Applications"), "square.grid.3x3"),
            (L("Pictures"), home.appendingPathComponent("Pictures"), "photo"),
            (L("Movies"), home.appendingPathComponent("Movies"), "film"),
            (L("Music"), home.appendingPathComponent("Music"), "music.note"),
        ]
        for (title, url, sym) in places where fm.fileExists(atPath: url.path) {
            add(SidebarRow(title: title, symbol: sym), url: url, group: nil)
        }

        let clouds = Cloud.providers()
        if !clouds.isEmpty {
            addHeader(SectionHeader(title: L("Cloud")))
            for c in clouds {
                let row = c.symbol == "icloud" ? SidebarRow(title: c.name, symbol: "icloud")
                                               : SidebarRow(title: c.name, icon: NSWorkspace.shared.icon(forFile: c.url.path))
                add(row, url: c.url, group: nil)
            }
        }

        let frequent = History.shared.frequent(limit: 5)
        if !frequent.isEmpty {
            addHeader(SectionHeader(title: L("Frequent")))
            for u in frequent {
                let row = SidebarRow(title: FileManager.default.displayName(atPath: u.path), icon: NSWorkspace.shared.icon(forFile: u.path))
                add(row, url: u, group: nil)
                row.menu?.addItem(.separator())
                row.menu?.addItem(ClosureMenuItem(L("Remove from List")) { History.shared.forget(u.path) })
            }
        }

        let smartHeader = SectionHeader(title: L("Smart Folders"), addButton: true)
        smartHeader.onAdd = { [weak self] in self?.onNewSmartFolder?() }
        smartHeader.toolTip = L("New smart folder (saved Spotlight query)")
        addHeader(smartHeader)
        for f in SmartFolders.shared.folders {
            let row = SidebarRow(title: f.name, symbol: f.symbol)
            row.onClick = { [weak self] in self?.onOpen?(SmartFolders.shared.url(for: f)) }
            let m = NSMenu()
            m.addItem(ClosureMenuItem(L("Open")) { [weak self] in self?.onOpen?(SmartFolders.shared.url(for: f)) })
            m.addItem(ClosureMenuItem(L("Open in Other Pane")) { [weak self] in self?.onOpenInOtherPane?(SmartFolders.shared.url(for: f)) })
            m.addItem(ClosureMenuItem(L("Rename…")) { [weak self] in
                promptText(L("Rename smart folder"), value: f.name, window: self?.view.window) { name in
                    SmartFolders.shared.rename(id: f.id, to: name)
                }
            })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("Delete")) { SmartFolders.shared.remove(id: f.id) })
            row.menu = m
            row.toolTip = f.query
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }

        let newGroup = SectionHeader(title: L("Groups"), addButton: true)
        newGroup.onAdd = { [weak self] in self?.createGroup(with: []) }
        newGroup.onDropURLs = { [weak self] urls in self?.createGroup(with: urls) }
        newGroup.toolTip = L("New group (you can also drag folders here)")
        addHeader(newGroup)

        let groups = Prefs.shared.groups
        for (gi, g) in groups.enumerated() {
            let h = GroupHeader(title: g.name, count: g.paths.count, collapsed: g.collapsed)
            h.onClick = { Prefs.shared.updateGroup(g.id) { $0.collapsed.toggle() } }
            h.onDropURLs = { urls in Prefs.shared.add(urls, toGroup: g.id) }
            h.menu = groupMenu(g, index: gi, count: groups.count)
            addHeader(h)
            guard !g.collapsed else { continue }
            if g.paths.isEmpty {
                let hint = label(L("Drag and drop folders"), size: 11, color: .tertiaryLabelColor)
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(hint)
                NSLayoutConstraint.activate([
                    hint.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 30),
                    hint.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                    wrap.heightAnchor.constraint(equalToConstant: 22),
                ])
                stack.addArrangedSubview(wrap)
                wrap.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            }
            for p in g.paths {
                let u = URL(fileURLWithPath: p)
                let exists = fm.fileExists(atPath: p)
                let icon = NSWorkspace.shared.icon(forFile: p)
                let row = SidebarRow(title: u.lastPathComponent, icon: icon, indent: 12)
                if !exists { row.alphaValue = 0.45 }
                row.onDropURLs = { urls in Prefs.shared.add(urls, toGroup: g.id) }
                add(row, url: u, group: g)
            }
        }
    }

    private func addHeader(_ h: NSView) {
        stack.addArrangedSubview(h)
        h.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
    }

    private func add(_ row: SidebarRow, url: URL, group: SidebarGroup?) {
        row.onClick = { [weak self] in self?.activate(url) }
        let m = NSMenu()
        m.addItem(ClosureMenuItem(L("Open")) { [weak self] in self?.activate(url) })
        m.addItem(ClosureMenuItem(L("Open in Other Pane")) { [weak self] in self?.onOpenInOtherPane?(url) })
        m.addItem(ClosureMenuItem(L("Open in New Tab")) { [weak self] in self?.onOpenInNewTab?(url) })
        m.addItem(ClosureMenuItem(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        let groups = Prefs.shared.groups
        if let group {
            m.addItem(.separator())
            if groups.count > 1 {
                let move = NSMenuItem(title: L("Move to Another Group"), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for g in groups where g.id != group.id {
                    sub.addItem(ClosureMenuItem(g.name) {
                        Prefs.shared.updateGroup(group.id) { $0.paths.removeAll { $0 == url.path } }
                        Prefs.shared.add([url], toGroup: g.id)
                    })
                }
                move.submenu = sub
                m.addItem(move)
            }
            m.addItem(ClosureMenuItem(L("Move Up")) { Self.moveItem(url.path, in: group.id, by: -1) })
            m.addItem(ClosureMenuItem(L("Move Down")) { Self.moveItem(url.path, in: group.id, by: 1) })
            m.addItem(ClosureMenuItem(L("Remove from Group")) {
                Prefs.shared.updateGroup(group.id) { $0.paths.removeAll { $0 == url.path } }
            })
        } else if !groups.isEmpty {
            m.addItem(.separator())
            m.addItem(Self.addToGroupMenu(urls: [url]))
        }
        row.menu = m
        row.toolTip = url.path
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
    }

    private func activate(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { NSSound.beep(); return }
        if isDir.boolValue && !FileNode.node(for: url).isPackage { onOpen?(url) } else { onReveal?(url) }
    }

    private static func moveItem(_ path: String, in id: String, by d: Int) {
        Prefs.shared.updateGroup(id) { g in
            guard let i = g.paths.firstIndex(of: path) else { return }
            let j = i + d
            guard g.paths.indices.contains(j) else { return }
            g.paths.swapAt(i, j)
        }
    }

    private func groupMenu(_ g: SidebarGroup, index: Int, count: Int) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(L("Add Current Folder")) { [weak self] in
            if let u = self?.currentFolder?() { Prefs.shared.add([u], toGroup: g.id) }
        })
        m.addItem(ClosureMenuItem(L("Rename…")) { [weak self] in
            promptText(L("Rename group"), value: g.name, window: self?.view.window) { name in
                Prefs.shared.updateGroup(g.id) { $0.name = name }
            }
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Move Up"), enabled: index > 0) {
            var all = Prefs.shared.groups
            all.swapAt(index, index - 1)
            Prefs.shared.groups = all
        })
        m.addItem(ClosureMenuItem(L("Move Down"), enabled: index < count - 1) {
            var all = Prefs.shared.groups
            all.swapAt(index, index + 1)
            Prefs.shared.groups = all
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("New Group…")) { [weak self] in self?.createGroup(with: []) })
        m.addItem(ClosureMenuItem(L("Delete Group")) { [weak self] in
            guard let window = self?.view.window else { return }
            let a = NSAlert()
            a.messageText = L("Delete the group “%@”?", g.name)
            a.informativeText = L("Only the sidebar group is deleted; the folders are not touched.")
            a.addButton(withTitle: L("Delete"))
            a.addButton(withTitle: L("Cancel"))
            a.beginSheetModal(for: window) { r in
                if r == .alertFirstButtonReturn { Prefs.shared.groups = Prefs.shared.groups.filter { $0.id != g.id } }
            }
        })
        return m
    }

    func createGroup(with urls: [URL]) {
        promptText(L("New Group"), value: L("New Group"), window: view.window) { name in
            Prefs.shared.createGroup(name, with: urls)
        }
    }

    /// "Gruba Ekle ▸" submenu used by the sidebar and the file context menu.
    static func addToGroupMenu(urls: [URL], window: NSWindow? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: L("Add to Group"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        let sub = NSMenu()
        for g in Prefs.shared.groups {
            sub.addItem(ClosureMenuItem(g.name) { Prefs.shared.add(urls, toGroup: g.id) })
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(L("New Group…")) {
            promptText(L("New Group"), value: L("New Group"), window: window ?? NSApp.keyWindow) { name in
                Prefs.shared.createGroup(name, with: urls)
            }
        })
        item.submenu = sub
        return item
    }

    private struct Volume { let url: URL; let name: String; let total: Int64; let free: Int64 }

    private func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return Volume(url: u, name: v.volumeLocalizedName ?? u.lastPathComponent, total: total, free: free)
        }
    }
}

/// Text prompt shown as a sheet (or modal when no window).
func promptText(_ title: String, value: String, window: NSWindow?, done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(string: value)
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: L("OK"))
    alert.addButton(withTitle: L("Cancel"))
    alert.window.initialFirstResponder = field
    let finish: (NSApplication.ModalResponse) -> Void = { r in
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if r == .alertFirstButtonReturn, !s.isEmpty { done(s) }
    }
    if let window {
        alert.beginSheetModal(for: window, completionHandler: finish)
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
    } else {
        finish(alert.runModal())
    }
}

/// Sidebar element that accepts dropped file URLs.
class DropTargetView: HoverView {
    var onDropURLs: (([URL]) -> Void)? {
        didSet { registerForDraggedTypes(onDropURLs == nil ? [] : [.fileURL]) }
    }
    private var dropHighlight = false { didSet { needsDisplay = true } }
    var isDropHighlighted: Bool { dropHighlight }

    private func urls(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropURLs != nil, !urls(sender).isEmpty else { return [] }
        dropHighlight = true
        return .link
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDropURLs?(u)
        return true
    }

    func drawBackground() {
        if isDropHighlighted {
            Theme.current.accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else if isHovered {
            Theme.current.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }
}

final class SectionHeader: DropTargetView {
    var onAdd: (() -> Void)?

    init(title: String, addButton: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let l = label(title, size: 11, weight: .semibold, color: .tertiaryLabelColor)
        addSubview(l)
        var cons = [
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 28),
        ]
        if addButton {
            let b = symbolButton("plus", L("New Group"), target: self, action: #selector(add))
            addSubview(b)
            cons += [b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                     b.centerYAnchor.constraint(equalTo: l.centerYAnchor)]
        }
        NSLayoutConstraint.activate(cons)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func add() { onAdd?() }
    override func mouseUp(with event: NSEvent) {}
    override func draw(_ dirtyRect: NSRect) { if isDropHighlighted { drawBackground() } }
}

final class GroupHeader: DropTargetView {
    init(title: String, count: Int, collapsed: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let chev = NSImageView(image: NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                              accessibilityDescription: nil) ?? NSImage())
        chev.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chev.contentTintColor = .tertiaryLabelColor
        chev.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemYellow
        icon.translatesAutoresizingMaskIntoConstraints = false
        let t = label(title, size: 12.5, weight: .semibold)
        let c = label("\(count)", size: 10.5, color: .tertiaryLabelColor)
        [chev, icon, t, c].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            chev.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            chev.centerYAnchor.constraint(equalTo: centerYAnchor),
            chev.widthAnchor.constraint(equalToConstant: 10),
            icon.leadingAnchor.constraint(equalTo: chev.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            t.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            t.centerYAnchor.constraint(equalTo: centerYAnchor),
            c.leadingAnchor.constraint(greaterThanOrEqualTo: t.trailingAnchor, constant: 4),
            c.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            c.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = L("Click: expand/collapse · Right-click: group actions · Drag a folder: add to group")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { drawBackground() }
}

final class SidebarRow: DropTargetView {
    init(title: String, icon: NSImage? = nil, symbol: String? = nil, usage: Double? = nil, subtitle: String? = nil, indent: CGFloat = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        if let symbol {
            iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iv.contentTintColor = .controlAccentColor
            iv.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        } else {
            iv.image = icon
        }
        iv.imageScaling = .scaleProportionallyUpOrDown
        let t = label(title, size: 13)
        addSubview(iv)
        addSubview(t)
        var cons = [
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 + indent),
            iv.widthAnchor.constraint(equalToConstant: 18), iv.heightAnchor.constraint(equalToConstant: 18),
            t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            t.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ]
        if let usage {
            let bar = UsageBar(fraction: usage)
            let sub = label(subtitle ?? "", size: 10, color: .secondaryLabelColor)
            let pct = label("\(Int((usage * 100).rounded()))%", size: 10, weight: .medium, color: .secondaryLabelColor)
            [bar, sub, pct].forEach(addSubview)
            cons += [
                heightAnchor.constraint(equalToConstant: 46),
                iv.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                t.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
                bar.leadingAnchor.constraint(equalTo: t.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                bar.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 4),
                bar.heightAnchor.constraint(equalToConstant: 4),
                pct.leadingAnchor.constraint(equalTo: t.leadingAnchor),
                pct.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
                sub.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                sub.firstBaselineAnchor.constraint(equalTo: pct.firstBaselineAnchor),
                sub.leadingAnchor.constraint(greaterThanOrEqualTo: pct.trailingAnchor, constant: 4),
            ]
        } else {
            cons += [
                heightAnchor.constraint(equalToConstant: 24),
                iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                t.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(cons)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { drawBackground() }
}

final class UsageBar: NSView {
    let fraction: Double

    init(fraction: Double) {
        self.fraction = min(1, max(0, fraction))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        Theme.current.separator.setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        let t = Theme.current
        let color: NSColor = fraction > 0.9 ? t.ageMinute : (fraction > 0.75 ? t.ageHour : t.accent)
        color.setFill()
        var f = r
        f.size.width = r.width * fraction
        NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
    }
}
