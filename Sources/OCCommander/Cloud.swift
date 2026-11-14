import AppKit

/// Sync state of files in iCloud Drive and File Provider clouds (Dropbox, Google Drive,
/// OneDrive, Box… everything under ~/Library/CloudStorage) via the ubiquitous-item keys.
enum Cloud {
    enum State: Equatable {
        case none, local, cloudOnly, downloading, uploading, conflict, excluded
    }

    static let keys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey,
        .ubiquitousItemIsExcludedFromSyncKey,
    ]

    static func state(_ v: URLResourceValues?) -> State {
        guard let v, v.isUbiquitousItem == true else { return .none }
        if v.ubiquitousItemHasUnresolvedConflicts == true { return .conflict }
        if v.ubiquitousItemIsExcludedFromSync == true { return .excluded }
        if v.ubiquitousItemIsDownloading == true { return .downloading }
        if v.ubiquitousItemIsUploading == true { return .uploading }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded { return .cloudOnly }
        return .local
    }

    /// Row badge symbol; nil for states that need no attention (fully synced).
    static func symbol(_ s: State) -> String? {
        switch s {
        case .none, .local: return nil
        case .cloudOnly: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle"
        case .uploading: return "arrow.up.circle"
        case .conflict: return "exclamationmark.icloud"
        case .excluded: return "icloud.slash"
        }
    }

    static func title(_ s: State) -> String {
        switch s {
        case .none: return "Yerel"
        case .local: return "İndirildi, eşitlendi"
        case .cloudOnly: return "Yalnızca bulutta"
        case .downloading: return "İndiriliyor"
        case .uploading: return "Yükleniyor"
        case .conflict: return "Çakışma var"
        case .excluded: return "Eşitlemeden hariç"
        }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var iCloudRoot: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }
    static var storageRoot: URL { home.appendingPathComponent("Library/CloudStorage") }

    /// Folders whose items may be ubiquitous (cloud keys are only worth fetching there).
    static func applies(to path: String) -> Bool {
        let h = home.path
        for root in [h + "/Library/Mobile Documents", storageRoot.path, h + "/Desktop", h + "/Documents"]
            where path == root || path.hasPrefix(root + "/") { return true }
        return false
    }

    struct Provider { let name: String; let url: URL; let symbol: String }

    /// iCloud Drive plus every File Provider domain folder.
    static func providers() -> [Provider] {
        var out: [Provider] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: iCloudRoot.path) { out.append(Provider(name: "iCloud Drive", url: iCloudRoot, symbol: "icloud")) }
        let dirs = (try? fm.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            out.append(Provider(name: displayName(folder: d.lastPathComponent), url: d, symbol: "cloud"))
        }
        return out
    }

    /// "GoogleDrive-me@gmail.com" → "Google Drive (me@gmail.com)", "OneDrive-Personal" → "OneDrive (Personal)".
    static func displayName(folder: String) -> String {
        let pretty = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box",
                      "pCloudDrive": "pCloud", "ProtonDrive": "Proton Drive", "SynologyDrive": "Synology Drive",
                      "Nextcloud": "Nextcloud", "MEGA": "MEGA", "iCloudDrive": "iCloud Drive"]
        guard let dash = folder.firstIndex(of: "-") else { return pretty[folder] ?? folder }
        let base = String(folder[..<dash]), rest = String(folder[folder.index(after: dash)...])
        let name = pretty[base] ?? base
        return rest.isEmpty || rest == base ? name : "\(name) (\(rest))"
    }

    /// Cloud service owning `path`, if any.
    static func providerName(for path: String) -> String? {
        if path.hasPrefix(home.path + "/Library/Mobile Documents/") { return "iCloud Drive" }
        let root = storageRoot.path + "/"
        guard path.hasPrefix(root) else { return nil }
        let first = path.dropFirst(root.count).split(separator: "/").first.map(String.init) ?? ""
        return displayName(folder: first)
    }

    /// Asks the provider to download items (folders recursively, capped).
    static func download(_ urls: [URL], done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            for u in urls {
                try? fm.startDownloadingUbiquitousItem(at: u)
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let e = fm.enumerator(at: u, includingPropertiesForKeys: nil) else { continue }
                var n = 0
                for case let f as URL in e {
                    try? fm.startDownloadingUbiquitousItem(at: f)
                    n += 1
                    if n > 20000 { break }
                }
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Removes local copies; data stays in the cloud ("yerden kazan").
    static func evict(_ urls: [URL], done: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var firstError: Error?
            for u in urls {
                do { try fm.evictUbiquitousItem(at: u) } catch {
                    // Some providers refuse folders: evict the files inside instead.
                    guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isDirectoryKey]) else {
                        firstError = firstError ?? error; continue
                    }
                    for case let f as URL in e where (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
                        do { try fm.evictUbiquitousItem(at: f) } catch { firstError = firstError ?? error }
                    }
                }
            }
            DispatchQueue.main.async { done(firstError) }
        }
    }
}
