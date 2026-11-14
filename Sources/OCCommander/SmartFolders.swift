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
        } else {
            folders = Self.defaults
        }
    }

    static let defaults: [SmartFolder] = [
        SmartFolder(id: "recent-downloads", name: "Son 7 Gün İndirilenler", symbol: "arrow.down.circle",
                    query: "kMDItemDateAdded >= $time.today(-7)", scopes: ["~/Downloads"]),
        SmartFolder(id: "large-files", name: "Büyük Dosyalar (>100 MB)", symbol: "externaldrive",
                    query: "kMDItemFSSize > 104857600", scopes: ["~"]),
        SmartFolder(id: "changed-today", name: "Bugün Değişenler", symbol: "clock",
                    query: "kMDItemFSContentChangeDate >= $time.today && kMDItemContentType != \"public.folder\"", scopes: ["~"]),
        SmartFolder(id: "recent-opened", name: "Son Açılanlar (7 gün)", symbol: "eye",
                    query: "kMDItemLastUsedDate >= $time.today(-7) && kMDItemContentType != \"public.folder\" && kMDItemContentTypeTree != \"com.apple.application\"",
                    scopes: ["~"]),
        SmartFolder(id: "screenshots", name: "Ekran Görüntüleri", symbol: "camera.viewfinder",
                    query: "kMDItemIsScreenCapture == 1", scopes: ["~"]),
        SmartFolder(id: "recent-pdfs", name: "PDF'ler (30 gün)", symbol: "doc.richtext",
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
        let f = SmartFolder(id: "search-\(abs(text.hashValue))-\(abs(scope.path.hashValue))", name: "Ara: \(text)",
                            symbol: "magnifyingglass",
                            query: "kMDItemFSName == \"*\(esc)*\"cd || kMDItemTextContent == \"\(esc)*\"cdw",
                            scopes: [scope.path])
        temporary[f.id] = f
        stop(f.id)
        return url(for: f)
    }

    func saveTemporary(path: String, window: NSWindow?) {
        guard let id = Self.id(fromPath: path), let t = temporary[id] else { return }
        promptText("Akıllı klasör adı", value: t.name.replacingOccurrences(of: "Ara: ", with: ""), window: window) { name in
            var f = t
            f.name = name
            self.add(f)
        }
    }

    // MARK: Builder dialog

    private static let kinds: [(String, String?)] = [
        ("Tüm türler", nil), ("Görsel", "public.image"), ("Video", "public.movie"), ("Ses", "public.audio"),
        ("PDF", "com.adobe.pdf"), ("Metin / kod", "public.text"), ("Arşiv", "public.archive"),
        ("Uygulama", "com.apple.application"), ("Klasör", "public.folder"),
    ]

    /// Asks for conditions and saves a new smart folder. `current` is offered as scope.
    func promptCreate(window: NSWindow?, current: URL?, done: @escaping (SmartFolder) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Yeni Akıllı Klasör"
        alert.informativeText = "Boş bıraktığın koşullar yok sayılır. Sonuçlar canlı güncellenir."
        alert.addButton(withTitle: "Oluştur")
        alert.addButton(withTitle: "Vazgeç")

        func field(_ ph: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = ph
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return f
        }
        let name = field("Örn. Büyük videolar")
        let contains = field("Adında geçen (isteğe bağlı)")
        let kind = NSPopUpButton()
        Self.kinds.forEach { kind.addItem(withTitle: $0.0) }
        let minSize = field("MB, örn. 50")
        let days = field("gün, örn. 14")
        let scope = NSPopUpButton()
        scope.addItems(withTitles: ["Ana klasör (~)", "Tüm Mac"])
        if let current { scope.addItem(withTitle: "Etkin klasör: \(current.lastPathComponent)") ; scope.selectItem(at: 2) }

        let grid = NSGridView(views: [
            [label("Ad:"), name], [label("Ad içerir:"), contains], [label("Tür:"), kind],
            [label("En az boyut:"), minSize], [label("Son … günde değişen:"), days], [label("Nerede:"), scope],
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
            let f = SmartFolder(id: "smart-\(UUID().uuidString.prefix(8))", name: title.isEmpty ? "Akıllı Klasör" : title,
                                symbol: "gearshape.2", query: parts.joined(separator: " && "), scopes: scopes)
            self.add(f)
            done(f)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}
