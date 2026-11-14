import AppKit

extension Notification.Name {
    static let prefsChanged = Notification.Name("OCPrefsChanged")
    static let favoritesChanged = Notification.Name("OCFavoritesChanged")
    static let folderSortChanged = Notification.Name("OCFolderSortChanged")
}

enum SortKey: Int, CaseIterable {
    case name, kind, modified, size

    var title: String {
        switch self {
        case .name: return "Ad"
        case .kind: return "Tür"
        case .modified: return "Değiştirilme Tarihi"
        case .size: return "Boyut"
        }
    }
}

final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var showHidden: Bool {
        get { d.bool(forKey: "showHidden") }
        set { d.set(newValue, forKey: "showHidden"); changed() }
    }

    /// Sorting is remembered per folder (like Finder's per-folder view options).
    func sort(for path: String) -> (key: SortKey, ascending: Bool) {
        guard let s = (d.dictionary(forKey: "folderSorts") as? [String: String])?[path] else { return (.name, true) }
        let parts = s.split(separator: ":")
        let key = parts.first.flatMap { Int($0) }.flatMap(SortKey.init(rawValue:)) ?? .name
        return (key, parts.count < 2 || parts[1] != "d")
    }

    func setSort(_ key: SortKey, ascending: Bool, for path: String) {
        var all = (d.dictionary(forKey: "folderSorts") as? [String: String]) ?? [:]
        if key == .name && ascending { all[path] = nil } else { all[path] = "\(key.rawValue):\(ascending ? "a" : "d")" }
        d.set(all, forKey: "folderSorts")
        NotificationCenter.default.post(name: .folderSortChanged, object: path)
    }

    /// Clicking the active sort column flips the direction, another column starts ascending.
    func toggleSort(_ key: SortKey, for path: String) {
        let cur = sort(for: path)
        setSort(key, ascending: cur.key == key ? !cur.ascending : (key == .name || key == .kind), for: path)
    }

    /// true: panes stacked top/bottom (over-under), false: side by side.
    var overUnder: Bool {
        get { d.object(forKey: "overUnder") as? Bool ?? true }
        set { d.set(newValue, forKey: "overUnder") }
    }

    var dualPane: Bool {
        get { d.object(forKey: "dualPane") as? Bool ?? true }
        set { d.set(newValue, forKey: "dualPane") }
    }

    /// Last column shows the detailed list (age, date, size).
    var detailsView: Bool {
        get { d.object(forKey: "detailsView") as? Bool ?? true }
        set { d.set(newValue, forKey: "detailsView"); changed() }
    }

    var themeID: String {
        get { d.string(forKey: "theme") ?? "system" }
        set {
            d.set(newValue, forKey: "theme")
            NotificationCenter.default.post(name: .themeChanged, object: nil)
        }
    }

    var previewVisible: Bool {
        get { d.object(forKey: "previewVisible") as? Bool ?? true }
        set { d.set(newValue, forKey: "previewVisible") }
    }

    // MARK: Sidebar groups

    var groups: [SidebarGroup] {
        get {
            if let data = d.data(forKey: "sidebarGroups"),
               let g = try? JSONDecoder().decode([SidebarGroup].self, from: data) {
                return g
            }
            // first run / migration from the old flat favorites list
            let old = d.stringArray(forKey: "favorites") ?? []
            return [SidebarGroup(name: "Favoriler", paths: old)]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "sidebarGroups") }
            NotificationCenter.default.post(name: .favoritesChanged, object: nil)
        }
    }

    func updateGroup(_ id: String, _ change: (inout SidebarGroup) -> Void) {
        var g = groups
        guard let i = g.firstIndex(where: { $0.id == id }) else { return }
        change(&g[i])
        groups = g
    }

    func add(_ urls: [URL], toGroup id: String) {
        updateGroup(id) { g in
            for u in urls where !g.paths.contains(u.path) { g.paths.append(u.path) }
        }
    }

    @discardableResult
    func createGroup(_ name: String, with urls: [URL] = []) -> String {
        let g = SidebarGroup(name: name, paths: urls.map(\.path))
        groups = groups + [g]
        return g.id
    }

    private func changed() {
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }
}

struct SidebarGroup: Codable {
    var id = UUID().uuidString
    var name: String
    var paths: [String]
    var collapsed = false
}

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ n: Int64) -> String {
        byteFormatter.string(fromByteCount: n)
    }

    /// OneCommander-style colored age: 5m (minutes), 3h, 10d, 7M (months), 2y.
    static func ageBadge(_ d: Date?) -> (String, NSColor)? {
        guard let d else { return nil }
        let s = max(0, Date().timeIntervalSince(d))
        switch s {
        case ..<3600: return ("\(max(1, Int(s / 60)))m", Theme.current.ageMinute)
        case ..<86400: return ("\(Int(s / 3600))h", Theme.current.ageHour)
        case ..<(86400 * 31): return ("\(Int(s / 86400))d", Theme.current.ageDay)
        case ..<(86400 * 365): return ("\(max(1, Int(s / (86400 * 30.4))))M", Theme.current.ageMonth)
        default: return ("\(Int(s / (86400 * 365)))y", Theme.current.ageYear)
        }
    }

    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return dateFormatter.string(from: d)
    }

    static func longDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        return longDateFormatter.string(from: d)
    }

    /// Compact age like OneCommander: 5dk, 3sa, 10g, 7ay, 2y
    static func age(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = max(0, Date().timeIntervalSince(d))
        switch s {
        case ..<60: return "şimdi"
        case ..<3600: return "\(Int(s / 60))dk"
        case ..<86400: return "\(Int(s / 3600))sa"
        case ..<(86400 * 31): return "\(Int(s / 86400))g"
        case ..<(86400 * 365): return "\(Int(s / (86400 * 30.4)))ay"
        default: return "\(Int(s / (86400 * 365)))y"
        }
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func permissions(_ mode: Int, isDir: Bool) -> String {
        let chars = ["r", "w", "x"]
        var out = isDir ? "d" : "-"
        for shift in stride(from: 6, through: 0, by: -3) {
            for (i, c) in chars.enumerated() {
                out += (mode >> (shift + 2 - i)) & 1 == 1 ? c : "-"
            }
        }
        return out + String(format: "  (%o)", mode)
    }
}
