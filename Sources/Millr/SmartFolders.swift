import AppKit

extension Notification.Name {
    static let smartFoldersChanged = Notification.Name("OCSmartFoldersChanged")
    static let virtualFolderUpdated = Notification.Name("OCVirtualFolderUpdated")
}

/// A saved Spotlight query shown as a folder.
struct SmartFolder: Codable, Equatable {
    var id: String
    var name: String
    var symbol: String
    /// Spotlight query string (mdfind syntax, `$time.today(-7)` allowed).
    var query: String
    /// Search scopes; "~" expands to the home folder.
    var scopes: [String]
}

/// Runs smart folder queries live (NSMetadataQuery) and feeds their virtual nodes.
final class SmartFolders: NSObject {
    static let shared = SmartFolders()
    private let key = "smartFolders"
    private static let resultLimit = 5000

    private(set) var folders: [SmartFolder] = []
    /// Unsaved ad-hoc searches (command palette "Spotlight'ta ara").
    private var temporary: [String: SmartFolder] = [:]
    private var queries: [String: NSMetadataQuery] = [:]

    private override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: key), let f = try? JSONDecoder().decode([SmartFolder].self, from: d) {
            folders = f
            // Saved built-in folders show in the current language unless the user renamed them.
            for i in folders.indices {
                if let key = Self.builtInNames[folders[i].id], Self.translations(of: key).contains(folders[i].name) {
                    folders[i].name = L(key)
                }
            }
        } else {
            folders = Self.defaults
        }
    }

    /// English keys of the built-in folders' names, by id.
    private static let builtInNames = [
        "recent-downloads": "Downloads, Last 7 Days", "large-files": "Large Files (>100 MB)",
        "changed-today": "Changed Today", "recent-opened": "Recently Opened (7 days)",
        "screenshots": "Screenshots", "recent-pdfs": "PDFs (30 days)",
    ]

    /// `key` in every language the app ships.
    private static func translations(of key: String) -> Set<String> {
        var out: Set<String> = [key]
        for lang in Bundle.main.localizations {
            if let path = Bundle.main.path(forResource: lang, ofType: "lproj"), let b = Bundle(path: path) {
                out.insert(b.localizedString(forKey: key, value: key, table: nil))
            }
        }
        return out
    }

    static let defaults: [SmartFolder] = [
        SmartFolder(id: "recent-downloads", name: L("Downloads, Last 7 Days"), symbol: "arrow.down.circle",
                    query: "kMDItemDateAdded >= $time.today(-7)", scopes: ["~/Downloads"]),
        SmartFolder(id: "large-files", name: L("Large Files (>100 MB)"), symbol: "externaldrive",
                    query: "kMDItemFSSize > 104857600", scopes: ["~"]),
        SmartFolder(id: "changed-today", name: L("Changed Today"), symbol: "clock",
                    query: "kMDItemFSContentChangeDate >= $time.today && kMDItemContentType != \"public.folder\"", scopes: ["~"]),
        SmartFolder(id: "recent-opened", name: L("Recently Opened (7 days)"), symbol: "eye",
                    query: "kMDItemLastUsedDate >= $time.today(-7) && kMDItemContentType != \"public.folder\" && kMDItemContentTypeTree != \"com.apple.application\"",
                    scopes: ["~"]),
        SmartFolder(id: "screenshots", name: L("Screenshots"), symbol: "camera.viewfinder",
                    query: "kMDItemIsScreenCapture == 1", scopes: ["~"]),
        SmartFolder(id: "recent-pdfs", name: L("PDFs (30 days)"), symbol: "doc.richtext",
                    query: "kMDItemContentType == \"com.adobe.pdf\" && kMDItemFSContentChangeDate >= $time.today(-30)", scopes: ["~"]),
    ]

    private func save() {
        if let d = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(d, forKey: key) }
        NotificationCenter.default.post(name: .smartFoldersChanged, object: nil)
    }

    func folder(id: String) -> SmartFolder? { folders.first { $0.id == id } ?? temporary[id] }

    static func id(fromPath p: String) -> String? {
        guard VirtualFolders.isVirtual(path: p) else { return nil }
        return String(p.dropFirst(VirtualFolders.prefix.count))
    }

    /// Virtual folder URL for `f`; starts its live query on first use.
    func url(for f: SmartFolder) -> URL {
        let n = VirtualFolders.node(id: f.id, name: f.name, symbol: f.symbol)
        if queries[f.id] == nil { start(f) }
        return n.url
    }

    func rerun(path: String) {
        guard let id = Self.id(fromPath: path), let f = folder(id: id) else { return }
        stop(id)
        start(f)
    }

    private func stop(_ id: String) {
        guard let q = queries.removeValue(forKey: id) else { return }
        q.stop()
        NotificationCenter.default.removeObserver(self, name: nil, object: q)
    }

    private func start(_ f: SmartFolder) {
        guard let pred = NSPredicate(fromMetadataQueryString: f.query) else {
            NSSound.beep()
            return
        }
        let q = NSMetadataQuery()
        q.predicate = pred
        q.searchScopes = f.scopes.map { ($0 as NSString).expandingTildeInPath }.map { $0 == "/" ? NSMetadataQueryLocalComputerScope : $0 }
        q.notificationBatchingInterval = 0.5
        q.operationQueue = .main
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidFinishGathering, object: q)
        nc.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidUpdate, object: q)
        queries[f.id] = q
        q.start()
    }

    @objc private func gathered(_ n: Notification) {
        guard let q = n.object as? NSMetadataQuery,
              let id = queries.first(where: { $0.value === q })?.key,
              let node = VirtualFolders.nodes[VirtualFolders.prefix + id] else { return }
        q.disableUpdates()
        var nodes: [FileNode] = []
        let count = min(q.resultCount, Self.resultLimit)
        nodes.reserveCapacity(count)
        for i in 0..<count {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let p = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            nodes.append(FileNode.node(for: URL(fileURLWithPath: p)))
        }
        q.enableUpdates()
        node.setVirtual(items: nodes)
        NotificationCenter.default.post(name: .virtualFolderUpdated, object: nil, userInfo: ["path": node.path])
    }

    // MARK: Editing

    func add(_ f: SmartFolder) {
        temporary[f.id] = nil
        folders.append(f)
        save()
    }

    func remove(id: String) {
        stop(id)
        folders.removeAll { $0.id == id }
        save()
    }

    func rename(id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        VirtualFolders.nodes[VirtualFolders.prefix + id]?.setVirtual(name: name)
        save()
    }

    func isTemporary(path: String) -> Bool {
        guard let id = Self.id(fromPath: path) else { return false }
        return temporary[id] != nil
    }

    /// Ad-hoc name/content search, shown as a virtual folder.
    func search(_ text: String, in scope: URL) -> URL {
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let f = SmartFolder(id: "search-\(abs(text.hashValue))-\(abs(scope.path.hashValue))", name: L("Search: %@", text),
                            symbol: "magnifyingglass",
                            query: "kMDItemFSName == \"*\(esc)*\"cd || kMDItemTextContent == \"\(esc)*\"cdw",
                            scopes: [scope.path])
        temporary[f.id] = f
        stop(f.id)
        return url(for: f)
    }

    func saveTemporary(path: String, window: NSWindow?) {
        guard let id = Self.id(fromPath: path), let t = temporary[id] else { return }
        promptText(L("Smart folder name"), value: t.name.replacingOccurrences(of: L("Search: %@", ""), with: ""), window: window) { name in
            var f = t
            f.name = name
            self.add(f)
        }
    }

    // MARK: Builder dialog

    private static let kinds: [(String, String?)] = [
        (L("All kinds"), nil), (L("Image"), "public.image"), (L("Video"), "public.movie"), (L("Audio"), "public.audio"),
        ("PDF", "com.adobe.pdf"), (L("Text / code"), "public.text"), (L("Archive"), "public.archive"),
        (L("Application"), "com.apple.application"), (L("Folder"), "public.folder"),
    ]

    /// Asks for conditions and saves a new smart folder. `current` is offered as scope.
    func promptCreate(window: NSWindow?, current: URL?, done: @escaping (SmartFolder) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("New Smart Folder")
        alert.informativeText = L("Empty conditions are ignored. Results update live.")
        alert.addButton(withTitle: L("Create"))
        alert.addButton(withTitle: L("Cancel"))

        func field(_ ph: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = ph
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return f
        }
        let name = field(L("E.g. Large videos"))
        let contains = field(L("Name contains (optional)"))
        let kind = NSPopUpButton()
        Self.kinds.forEach { kind.addItem(withTitle: $0.0) }
        let minSize = field(L("MB, e.g. 50"))
        let days = field(L("days, e.g. 14"))
        let scope = NSPopUpButton()
        scope.addItems(withTitles: [L("Home folder (~)"), L("Entire Mac")])
        if let current { scope.addItem(withTitle: L("Current folder: %@", current.lastPathComponent)) ; scope.selectItem(at: 2) }

        let grid = NSGridView(views: [
            [label(L("Name:")), name], [label(L("Name contains:")), contains], [label(L("Kind:")), kind],
            [label(L("Minimum size:")), minSize], [label(L("Changed in the last … days:")), days], [label(L("Where:")), scope],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: 200)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = name

        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            var parts: [String] = []
            let c = contains.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            if !c.isEmpty { parts.append("kMDItemFSName == \"*\(c)*\"cd") }
            if let uti = Self.kinds[kind.indexOfSelectedItem].1 { parts.append("kMDItemContentTypeTree == \"\(uti)\"") }
            if let mb = Double(minSize.stringValue.replacingOccurrences(of: ",", with: ".")), mb > 0 {
                parts.append("kMDItemFSSize > \(Int64(mb * 1_048_576))")
            }
            if let d = Int(days.stringValue), d > 0 { parts.append("kMDItemFSContentChangeDate >= $time.today(-\(d))") }
            guard !parts.isEmpty else { NSSound.beep(); return }
            let scopes: [String]
            switch scope.indexOfSelectedItem {
            case 1: scopes = ["/"]
            case 2: scopes = [current?.path ?? "~"]
            default: scopes = ["~"]
            }
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            let f = SmartFolder(id: "smart-\(UUID().uuidString.prefix(8))", name: title.isEmpty ? L("Smart Folder") : title,
                                symbol: "gearshape.2", query: parts.joined(separator: " && "), scopes: scopes)
            self.add(f)
            done(f)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}
