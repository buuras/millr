import Foundation

extension Notification.Name {
    static let frequentChanged = Notification.Name("OCFrequentChanged")
}

/// Folder visit log: drives "Sık Kullanılan" (frecency) and "Son Klasörler" (recency).
final class History {
    static let shared = History()
    private let key = "folderVisits"
    private let maxEntries = 600

    struct Visit: Codable {
        var count: Int
        var last: Date
    }

    private var visits: [String: Visit] = [:]
    private var lastTop: [String] = []
    private var saveScheduled = false

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: Visit].self, from: d) { visits = v }
        lastTop = frequent(limit: 6).map(\.path)
    }

    /// Paths not worth remembering: volume roots, the home folder itself, temp/cache areas.
    private static func ignored(_ p: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == "/" || p == home || p == "/Volumes" || p == "/Users" { return true }
        if VirtualFolders.isVirtual(path: p) || Archives.isExtracted(path: p) { return true }
        return p.hasPrefix("/private/") || p.hasPrefix(home + "/Library/Caches")
    }

    func record(_ url: URL) {
        let p = url.standardizedFileURL.path
        guard !Self.ignored(p) else { return }
        var v = visits[p] ?? Visit(count: 0, last: .distantPast)
        // Revisits within a minute (back/forward hopping) count once.
        if Date().timeIntervalSince(v.last) > 60 { v.count += 1 }
        v.last = Date()
        visits[p] = v
        if visits.count > maxEntries {
            let drop = visits.sorted { score($0.value) < score($1.value) }.prefix(visits.count - maxEntries)
            drop.forEach { visits[$0.key] = nil }
        }
        scheduleSave()
        let top = frequent(limit: 6).map(\.path)
        if top != lastTop {
            lastTop = top
            NotificationCenter.default.post(name: .frequentChanged, object: nil)
        }
    }

    func forget(_ path: String) {
        visits[path] = nil
        scheduleSave()
        lastTop = frequent(limit: 6).map(\.path)
        NotificationCenter.default.post(name: .frequentChanged, object: nil)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.visits) { UserDefaults.standard.set(d, forKey: self.key) }
        }
    }

    /// Frecency: visit count weighted by how recent the last visit was.
    func score(_ v: Visit) -> Double {
        let days = Date().timeIntervalSince(v.last) / 86400
        let w: Double = days < 1 ? 1.0 : days < 4 ? 0.8 : days < 14 ? 0.6 : days < 31 ? 0.4 : days < 90 ? 0.2 : 0.08
        return Double(v.count) * w
    }

    func score(path: String) -> Double { visits[path].map(score) ?? 0 }

    private func existing(_ list: [(String, Visit)], limit: Int) -> [URL] {
        var out: [URL] = []
        for (p, _) in list where FileManager.default.fileExists(atPath: p) {
            out.append(URL(fileURLWithPath: p))
            if out.count == limit { break }
        }
        return out
    }

    func frequent(limit: Int) -> [URL] {
        existing(visits.filter { $0.value.count >= 2 }.sorted { score($0.value) > score($1.value) }, limit: limit)
    }

    func recent(limit: Int) -> [URL] {
        existing(visits.sorted { $0.value.last > $1.value.last }, limit: limit)
    }

    /// Every remembered folder (for the command palette).
    var all: [(url: URL, score: Double)] {
        visits.map { (URL(fileURLWithPath: $0.key), score($0.value)) }
    }
}
