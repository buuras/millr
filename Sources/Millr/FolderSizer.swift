import Foundation

extension Notification.Name {
    static let folderSizesUpdated = Notification.Name("OCFolderSizesUpdated")
}

/// Computes recursive folder sizes in the background and caches them.
/// One computation also stores the sizes of subfolders (2 levels deep), so
/// navigating into a measured folder shows sizes instantly.
final class FolderSizer {
    static let shared = FolderSizer()

    private struct Entry {
        var size: Int64
        var date: Date
        var stale: Bool
    }

    private var cache: [String: Entry] = [:]
    private var inFlight = Set<String>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private static let skip: Set<String> = ["/Volumes", "/System/Volumes", "/dev", "/private/var/vm", "/net", "/home"]
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    /// Known size (possibly stale); schedules a computation when missing or outdated.
    func size(for path: String) -> Int64? {
        if let e = cache[path] {
            if e.stale && Date().timeIntervalSince(e.date) > 20 { request(path) }
            return e.size
        }
        request(path)
        return nil
    }

    func cachedSize(for path: String) -> Int64? { cache[path]?.size }

    /// Marks changed folders and all their ancestors as outdated.
    func invalidate(_ dirs: Set<String>) {
        for d in dirs {
            var p = d
            while !p.isEmpty {
                cache[p]?.stale = true
                if p == "/" { break }
                p = (p as NSString).deletingLastPathComponent
            }
        }
    }

    private func request(_ path: String) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        // newest requests (what the user looks at now) first
        for o in queue.operations where !o.isExecuting { o.queuePriority = .low }
        let op = BlockOperation()
        op.queuePriority = .high
        op.addExecutionBlock { [weak op] in
            var results: [String: Int64] = [:]
            let cancelled = { op?.isCancelled ?? true }
            let total = Self.dfs(URL(fileURLWithPath: path), depth: 0, results: &results, cancelled: cancelled)
            let wasCancelled = cancelled()
            results[path] = total
            DispatchQueue.main.async {
                self.inFlight.remove(path)
                guard !wasCancelled else { return }
                let now = Date()
                for (p, s) in results { self.cache[p] = Entry(size: s, date: now, stale: false) }
                NotificationCenter.default.post(name: .folderSizesUpdated, object: nil,
                                                userInfo: ["paths": Set(results.keys)])
            }
        }
        queue.addOperation(op)
    }

    private static func dfs(_ url: URL, depth: Int, results: inout [String: Int64], cancelled: () -> Bool) -> Int64 {
        if depth > 0 && skip.contains(url.path) { return 0 }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total: Int64 = 0
        for u in items {
            if cancelled() { return total }
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true {
                total += dfs(u, depth: depth + 1, results: &results, cancelled: cancelled)
            } else {
                total += Int64(v.fileSize ?? 0)
            }
        }
        if depth > 0 && depth <= 2 { results[url.path] = total }
        return total
    }
}
