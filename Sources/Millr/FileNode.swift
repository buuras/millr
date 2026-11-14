import AppKit

/// One file system item. Instances are unique per path (registry) so NSBrowser
/// keeps stable item identity across reloads.
final class FileNode: NSObject {
    private static let registry = NSMapTable<NSString, FileNode>.strongToWeakObjects()

    /// Cheap attributes (one getattrlist). Type descriptions, volume names and cloud state go
    /// through LaunchServices / File Provider and cost ~0.3 ms per file, so they are fetched
    /// only where needed (`kind` lazily, cloud keys inside cloud folders).
    static let baseKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .labelNumberKey,
    ]
    static let cloudKeys = baseKeys + Cloud.keys

    private static let baseSet = Set(baseKeys), cloudSet = Set(cloudKeys)
    static func keys(forFolder path: String) -> [URLResourceKey] { Cloud.applies(to: path) ? cloudKeys : baseKeys }
    private static func keySet(forFolder path: String) -> Set<URLResourceKey> { Cloud.applies(to: path) ? cloudSet : baseSet }

    static func node(for url: URL) -> FileNode {
        let u = url.standardizedFileURL
        if let v = VirtualFolders.nodes[u.path] { return v }
        let key = u.path as NSString
        if let n = registry.object(forKey: key) { return n }
        let n = FileNode(url: u)
        registry.setObject(n, forKey: key)
        return n
    }

    /// For entries of a directory listing (values read on the listing thread).
    private static func node(listed e: Listing.Entry) -> FileNode {
        let key = e.path as NSString
        if let n = registry.object(forKey: key) {
            n.apply(e.values)
            return n
        }
        let n = FileNode(url: e.url, path: e.path, name: e.name, values: e.values)
        registry.setObject(n, forKey: key)
        return n
    }

    static func existing(path: String) -> FileNode? {
        VirtualFolders.nodes[path] ?? registry.object(forKey: path as NSString)
    }

    static func invalidateAll() {
        guard let e = registry.objectEnumerator() else { return }
        for case let n as FileNode in e { n.invalidate() }
    }

    let url: URL
    /// Stored: URL.path decodes percent escapes on every call, which adds up over 50k items.
    let path: String
    private(set) var name = ""
    private(set) var isDirectory = false
    private(set) var isPackage = false
    private(set) var isSymlink = false
    private(set) var isHiddenFile = false
    private(set) var size: Int64 = 0
    private(set) var modified: Date?
    private(set) var created: Date?
    private(set) var labelNumber = 0
    private var _kind: String?
    private var _folded: String?
    private(set) var loadError: String?
    private(set) var cloud: Cloud.State = .none
    /// Virtual folders (smart folders, searches) list items from anywhere; they have no real path.
    private(set) var isVirtual = false
    private(set) var virtualSymbol = "gearshape"
    private var virtualItems: [FileNode] = []
    private var _children: [FileNode]?
    /// Order before the last invalidate: a reload re-sorts only what changed (see `sorted`).
    private var _stale: [FileNode]?
    private var _icon: NSImage?

    private init(url: URL, path: String, name: String, values: URLResourceValues?) {
        self.url = url
        self.path = path
        self.name = name
        super.init()
        apply(values)
    }

    private convenience init(url: URL) {
        let path = url.path
        let name = path == "/"
            ? (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
            : url.lastPathComponent
        self.init(url: url, path: path, name: name, values: Self.readValues(url, path: path))
    }

    private static func readValues(_ url: URL, path: String) -> URLResourceValues? {
        let v = try? url.resourceValues(forKeys: keySet(forFolder: (path as NSString).deletingLastPathComponent))
        (url as NSURL).removeAllCachedResourceValues()   // the node keeps `url`; don't keep the values twice
        return v
    }

    fileprivate init(virtualPath: String, name: String, symbol: String) {
        url = URL(fileURLWithPath: virtualPath)
        path = virtualPath
        super.init()
        isVirtual = true
        isDirectory = true
        self.name = name
        virtualSymbol = symbol
    }

    func setVirtual(name: String? = nil, items: [FileNode]? = nil) {
        if let name { self.name = name; _folded = nil }
        if let items { virtualItems = items; _children = nil }
    }

    func refreshAttributes() {
        guard !isVirtual else { return }
        (url as NSURL).removeAllCachedResourceValues()
        apply(Self.readValues(url, path: path))
    }

    private func apply(_ v: URLResourceValues?) {
        guard !isVirtual else { return }
        let oldModified = modified, oldDir = isDirectory, oldPackage = isPackage
        isSymlink = v?.isSymbolicLink ?? false
        var dir = v?.isDirectory ?? false
        if isSymlink {
            let r = url.resolvingSymlinksInPath()
            dir = (try? r.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        isPackage = v?.isPackage ?? false
        isDirectory = dir && !isPackage
        isHiddenFile = v?.isHidden ?? name.hasPrefix(".")
        size = Int64(v?.fileSize ?? 0)
        modified = v?.contentModificationDate
        created = v?.creationDate
        labelNumber = v?.labelNumber ?? 0
        cloud = Cloud.state(v)
        // Type and icon only change with the content (or a file/folder swap under the same name).
        if modified != oldModified || isDirectory != oldDir || isPackage != oldPackage {
            _kind = nil
            _icon = nil
        }
    }

    /// Name folded for filtering (case, diacritics, Turkish i/ı/İ), cached.
    var foldedName: String {
        if let f = _folded { return f }
        let f = Self.fold(name)
        _folded = f
        return f
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "ı", with: "i")
    }

    private static var kindCache: [String: String] = [:]

    /// Localized type ("PDF document"), cached per extension: the lookup is slow.
    var kind: String {
        if let k = _kind { return k }
        let ext = url.pathExtension.lowercased()
        let cacheKey = isSymlink ? "" : (isDirectory ? "/" : (isPackage ? "pkg." : ".") + ext)
        if !cacheKey.isEmpty, let k = Self.kindCache[cacheKey] { _kind = k; return k }
        let k = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? ""
        if !cacheKey.isEmpty && !(isPackage && ext == "app") { Self.kindCache[cacheKey] = k }
        _kind = k
        return k
    }

    var icon: NSImage {
        if let i = _icon { return i }
        if isVirtual {
            let img = NSImage(systemSymbolName: virtualSymbol, accessibilityDescription: nil) ?? NSImage()
            _icon = img
            return img
        }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 16, height: 16)
        _icon = i
        return i
    }

    var parentURL: URL { url.deletingLastPathComponent() }

    /// Folders and packages are measured recursively (FolderSizer).
    var isContainer: Bool { isDirectory || isPackage }

    var effectiveSize: Int64 {
        isContainer ? (FolderSizer.shared.cachedSize(for: path) ?? -1) : size
    }

    /// Display text for the size column: files exact, folders "~X" or "…" while measuring.
    var sizeText: String {
        guard isContainer else { return Fmt.size(size) }
        if let s = FolderSizer.shared.size(for: path) { return "~" + Fmt.size(s) }
        return "…"
    }

    /// Folders from the volume root down to `url` (inclusive).
    static func chain(to url: URL) -> [FileNode] {
        let u = url.standardizedFileURL
        if let v = VirtualFolders.nodes[u.path] { return [v] }
        let vol = (try? u.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path ?? "/"
        var urls: [URL] = []
        var cur = u
        while true {
            urls.insert(cur, at: 0)
            if cur.path == vol || cur.path == "/" { break }
            cur = cur.deletingLastPathComponent()
        }
        return urls.map { node(for: $0) }
    }

    // MARK: Children

    var childrenLoaded: Bool { _children != nil }
    /// A background listing is running (`loadChildrenAsync`); `children` returns the previous
    /// contents (or nothing) until it finishes.
    private(set) var isLoading = false
    /// Bumped by `invalidate` and synchronous loads: a background result that started earlier is stale.
    private var generation = 0
    private var lastUse = 0

    var children: [FileNode] {
        if _children == nil {
            if isLoading { return _stale ?? [] }
            loadChildren()
        }
        Self.useClock += 1
        lastUse = Self.useClock
        return _children ?? []
    }

    func invalidate() {
        if let c = _children { _stale = c }
        _children = nil
        generation += 1
    }

    func loadChildren() {
        generation += 1
        isLoading = false
        if isVirtual { _children = Self.sorted(virtualItems, for: path); Self.didLoad(self); return }
        guard isDirectory else { _children = []; return }
        apply(Self.list(url, folder: path, showHidden: Prefs.shared.showHidden))
    }

    private static let listingQueue = DispatchQueue(label: "oc.listing", qos: .userInitiated, attributes: .concurrent)

    /// Lists the folder on a background queue. Waits up to `wait` seconds so that small folders
    /// still appear in the same pass (no flicker); bigger ones finish later and post
    /// `.folderChildrenLoaded`, keeping the main thread free while 50k items are read.
    func loadChildrenAsync(wait: TimeInterval = 0.03) {
        guard _children == nil, !isLoading else { return }
        guard !isVirtual, isDirectory else { loadChildren(); return }
        isLoading = true
        let gen = generation, url = url, folder = path, hidden = Prefs.shared.showHidden
        let (key, asc) = Prefs.shared.sort(for: path)
        let box = ListingBox(), done = DispatchSemaphore(value: 0)
        Self.listingQueue.async {
            var l = Self.list(url, folder: folder, showHidden: hidden)
            l.presort(key, ascending: asc)
            box.put(l)
            done.signal()
            DispatchQueue.main.async { [weak self] in self?.finishLoad(box, gen, notify: true) }
        }
        if done.wait(timeout: .now() + wait) == .success { finishLoad(box, gen, notify: false) }
    }

    private func finishLoad(_ box: ListingBox, _ gen: Int, notify: Bool) {
        guard isLoading, let listing = box.take() else { return }
        isLoading = false
        // Invalidated while listing: the result may miss later changes, list again.
        if gen != generation { loadChildrenAsync(wait: 0); return }
        apply(listing)
        if notify { NotificationCenter.default.post(name: .folderChildrenLoaded, object: self) }
    }

    /// Thread-safe: runs on the listing queue.
    private static func list(_ url: URL, folder: String, showHidden: Bool) -> Listing {
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        let keys = keys(forFolder: folder), set = keySet(forFolder: folder)
        do {
            return try autoreleasepool {
                let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts)
                return Listing(entries: urls.map { u in
                    let v = try? u.resourceValues(forKeys: set)
                    (u as NSURL).removeAllCachedResourceValues()   // the node keeps `u`; drop its prefetched values
                    return Listing.Entry(url: u, path: u.path, name: u.lastPathComponent, values: v)
                })
            }
        } catch {
            return Listing(error: error.localizedDescription)
        }
    }

    private func apply(_ listing: Listing) {
        if let e = listing.error {
            loadError = e
            _children = []
            return
        }
        let nodes = listing.entries.map(Self.node(listed:))
        loadError = nil
        // A presorted listing is its own hint: `sorted` then only verifies the order.
        _children = Self.sorted(nodes, for: path, hint: listing.presorted ? nodes : _stale)
        _stale = nil
        Self.didLoad(self)
    }

    // MARK: Children cache

    /// Upper bound for cached child nodes across all folders. Past it, the least recently used
    /// folders that are not on screen drop their children (they are listed again when opened).
    static var cacheBudget = 100_000
    /// Folders currently shown; never evicted. Set by the UI.
    static var inUse: () -> [FileNode] = { [] }
    private static let loadedFolders = NSHashTable<FileNode>.weakObjects()
    private static var cachedEstimate = 0, useClock = 0

    /// Child nodes held by loaded folders (for tests and diagnostics).
    static var cachedChildCount: Int {
        loadedFolders.allObjects.reduce(0) { $0 + ($1._children ?? $1._stale ?? []).count }
    }

    private static func didLoad(_ n: FileNode) {
        useClock += 1
        n.lastUse = useClock
        loadedFolders.add(n)
        cachedEstimate += n._children?.count ?? 0
        if cachedEstimate > cacheBudget { evict() }
    }

    /// Drops cached children, least recently used first, down to 3/4 of the budget.
    static func evict() {
        let keep = Set(inUse().map(ObjectIdentifier.init))
        let folders = loadedFolders.allObjects.sorted { $0.lastUse < $1.lastUse }
        var total = folders.reduce(0) { $0 + ($1._children ?? $1._stale ?? []).count }
        for n in folders where total > cacheBudget * 3 / 4 && !keep.contains(ObjectIdentifier(n)) {
            total -= (n._children ?? n._stale ?? []).count
            n._children = nil
            n._stale = nil
            loadedFolders.remove(n)
        }
        // Dropping a folder can free whole cached subtrees; recount on the next pass.
        cachedEstimate = total
    }

    func index(ofChildPath p: String) -> Int? {
        children.firstIndex { $0.path == p }
    }

    func isAncestor(of other: String) -> Bool {
        let base = path == "/" ? "/" : path + "/"
        return other.hasPrefix(base) && other != path
    }

    /// Re-orders already loaded children after the folder's sort setting changed.
    func resort() {
        if let c = _children { _children = Self.sorted(c, for: path) }
    }

    /// With `hint` (the previous order), items still present keep their relative order if it is
    /// still valid (one linear check) and only new items are sorted and merged in. A reload of a
    /// 50k folder then costs ~50k comparisons instead of ~800k.
    static func sorted(_ a: [FileNode], for folder: String, hint: [FileNode]? = nil) -> [FileNode] {
        let less = comparator(for: folder)
        guard let hint, !hint.isEmpty, a.count > 64 else { return a.sorted(by: less) }
        var pos = [ObjectIdentifier: Int](minimumCapacity: hint.count)
        for (i, n) in hint.enumerated() { pos[ObjectIdentifier(n)] = i }
        var kept: [(Int, FileNode)] = [], added: [FileNode] = []
        kept.reserveCapacity(a.count)
        for n in a {
            if let i = pos[ObjectIdentifier(n)] { kept.append((i, n)) } else { added.append(n) }
        }
        kept.sort { $0.0 < $1.0 }
        let old = kept.map(\.1)
        for i in old.indices.dropFirst() where less(old[i], old[i - 1]) { return a.sorted(by: less) }
        added.sort(by: less)
        var out: [FileNode] = []
        out.reserveCapacity(a.count)
        var i = 0, j = 0
        while i < old.count && j < added.count {
            if less(added[j], old[i]) { out.append(added[j]); j += 1 } else { out.append(old[i]); i += 1 }
        }
        out += old[i...]
        out += added[j...]
        return out
    }

    private static func comparator(for folder: String) -> (FileNode, FileNode) -> Bool {
        let (key, asc) = Prefs.shared.sort(for: folder)
        return { x, y in
            if x.isDirectory != y.isDirectory { return x.isDirectory }
            var r: ComparisonResult
            switch key {
            case .name:
                r = x.name.localizedStandardCompare(y.name)
            case .kind:
                r = x.kind.localizedStandardCompare(y.kind)
            case .modified:
                let dx = x.modified ?? .distantPast, dy = y.modified ?? .distantPast
                r = dx == dy ? .orderedSame : (dx < dy ? .orderedAscending : .orderedDescending)
            case .size:
                let sx = x.effectiveSize, sy = y.effectiveSize
                r = sx == sy ? .orderedSame : (sx < sy ? .orderedAscending : .orderedDescending)
            }
            if r == .orderedSame {
                return x.name.localizedStandardCompare(y.name) == .orderedAscending
            }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }
}


extension Notification.Name {
    /// A background listing finished; `object` is the folder node.
    static let folderChildrenLoaded = Notification.Name("OCFolderChildrenLoaded")
}

/// Result of one directory listing, built off the main thread.
private struct Listing {
    struct Entry { let url: URL; let path: String; let name: String; let values: URLResourceValues? }
    var entries: [Entry] = []
    var error: String?
    private(set) var presorted = false

    /// Sorts on the listing thread like `FileNode.comparator` would, for the keys that need only
    /// the listed values (name, date). Any mismatch (symlinked folders, ...) is caught by `sorted`.
    mutating func presort(_ key: SortKey, ascending asc: Bool) {
        guard key == .name || key == .modified, entries.count > 64 else { return }
        func isDir(_ e: Entry) -> Bool { (e.values?.isDirectory ?? false) && !(e.values?.isPackage ?? false) }
        entries.sort { x, y in
            let dx = isDir(x), dy = isDir(y)
            if dx != dy { return dx }
            var r = ComparisonResult.orderedSame
            if key == .modified {
                let mx = x.values?.contentModificationDate ?? .distantPast, my = y.values?.contentModificationDate ?? .distantPast
                r = mx == my ? .orderedSame : (mx < my ? .orderedAscending : .orderedDescending)
            } else {
                r = x.name.localizedStandardCompare(y.name)
            }
            if r == .orderedSame { return x.name.localizedStandardCompare(y.name) == .orderedAscending }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        presorted = true
    }
}

/// Hands a listing from the listing queue to the main thread exactly once.
private final class ListingBox {
    private let lock = NSLock()
    private var value: Listing?
    func put(_ l: Listing) { lock.lock(); value = l; lock.unlock() }
    func take() -> Listing? { lock.lock(); defer { value = nil; lock.unlock() }; return value }
}

/// Registry of virtual folder nodes, addressed by fake paths under `/.oc-virtual/`.
enum VirtualFolders {
    static let prefix = "/.oc-virtual/"
    static var nodes: [String: FileNode] = [:]

    static func isVirtual(path: String) -> Bool { path.hasPrefix(prefix) }
    static func isVirtual(_ url: URL) -> Bool { isVirtual(path: url.path) }

    static func node(id: String, name: String, symbol: String) -> FileNode {
        let p = prefix + id
        if let n = nodes[p] { n.setVirtual(name: name); return n }
        let n = FileNode(virtualPath: p, name: name, symbol: symbol)
        nodes[p] = n
        return n
    }
}
