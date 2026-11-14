import AppKit

/// Browsing archives like folders. Disk images are mounted read-only; zip/rar/7z/tar…
/// are unpacked (bsdtar/libarchive) into a cache folder that is then shown in the pane.
enum Archives {
    static let imageExts: Set<String> = ["dmg", "iso", "sparseimage", "sparsebundle", "cdr"]
    static let archiveExts: Set<String> = ["zip", "rar", "7z", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz",
                                           "cpio", "xar", "lha", "lzh", "cab", "jar", "apk", "ipa", "epub"]

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OCCommander/Archives")
    }

    /// Extraction root → original archive (for "go up" out of the archive).
    private(set) static var origins: [String: URL] = [:]
    private static var mounted: [String] = []

    static func canBrowse(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        return imageExts.contains(e) || archiveExts.contains(e)
    }

    static func isExtracted(path: String) -> Bool { path.hasPrefix(cacheRoot.path + "/") }

    /// Archive whose extracted root is `path`.
    static func origin(ofRoot path: String) -> URL? { origins[path] }

    /// Archive containing an extracted `path`, and the root it was extracted to.
    static func container(of path: String) -> (archive: URL, root: String)? {
        for (root, archive) in origins where path == root || path.hasPrefix(root + "/") { return (archive, root) }
        return nil
    }

    private static func cacheDir(for u: URL) -> URL {
        let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(u.path)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v?.fileSize ?? 0)"
        var h: UInt64 = 1469598103934665603         // FNV-1a: stable across launches
        for b in stamp.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return cacheRoot.appendingPathComponent(String(h, radix: 36))
    }

    /// Opens `archive` and calls back with the folder to show.
    static func browse(_ archive: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if imageExts.contains(archive.pathExtension.lowercased()) { mount(archive, completion: completion); return }
        let dir = cacheDir(for: archive)
        let root = dir.appendingPathComponent((archive.lastPathComponent as NSString).deletingPathExtension)
        let marker = dir.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: marker.path) {
            origins[root.path] = archive
            completion(.success(root))
            return
        }
        let job = FileJob(kind: .extract, title: "Arşiv açılıyor: \(archive.lastPathComponent)")
        job.indeterminate = true
        let p = Process()
        job.onCancel = { if p.isRunning { p.terminate() } }
        FileJobs.shared.run(job, work: { job in
            let fm = FileManager.default
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            p.arguments = ["-x", "-f", archive.path, "-C", root.path]
            let msg = try runCollectingErrors(p)
            if job.isCancelled { try? fm.removeItem(at: dir); return }
            guard p.terminationStatus == 0 else {
                try? fm.removeItem(at: dir)
                throw NSError(domain: "OCArchive", code: Int(p.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Arşiv açılamadı." : msg])
            }
            fm.createFile(atPath: marker.path, contents: nil)
        }, completion: { job in
            switch job.state {
            case .done:
                origins[root.path] = archive
                completion(.success(root))
            case .failed(let m):
                completion(.failure(NSError(domain: "OCArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: m])))
            default:
                completion(.failure(CocoaError(.userCancelled)))
            }
        })
    }

    private static func mount(_ image: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let job = FileJob(kind: .extract, title: "Disk görüntüsü bağlanıyor: \(image.lastPathComponent)")
        job.indeterminate = true
        var mountPoint: String?
        FileJobs.shared.run(job, work: { _ in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["attach", "-nobrowse", "-readonly", "-noverify", "-plist", image.path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let ents = plist["system-entities"] as? [[String: Any]],
                  let mp = ents.compactMap({ $0["mount-point"] as? String }).first else {
                throw NSError(domain: "OCArchive", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Disk görüntüsü bağlanamadı (şifreli ya da bozuk olabilir)."])
            }
            mountPoint = mp
        }, completion: { job in
            if job.state == .done, let mp = mountPoint {
                mounted.append(mp)
                origins[mp] = image
                completion(.success(URL(fileURLWithPath: mp)))
            } else if case .failed(let m) = job.state {
                completion(.failure(NSError(domain: "OCArchive", code: 2, userInfo: [NSLocalizedDescriptionKey: m])))
            }
        })
    }

    /// Unpacks next to the archive into a new folder (real extraction, not the browse cache).
    static func extractHere(_ archive: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let dest = FileOps.uniqueURL(for: (archive.lastPathComponent as NSString).deletingPathExtension,
                                     in: archive.deletingLastPathComponent())
        let job = FileJob(kind: .extract, title: "Çıkarılıyor: \(archive.lastPathComponent)")
        job.indeterminate = true
        let p = Process()
        job.onCancel = { if p.isRunning { p.terminate() } }
        FileJobs.shared.run(job, work: { job in
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            p.arguments = ["-x", "-f", archive.path, "-C", dest.path]
            let msg = try runCollectingErrors(p)
            if job.isCancelled || p.terminationStatus != 0 {
                try? FileManager.default.removeItem(at: dest)
                if !job.isCancelled {
                    throw NSError(domain: "OCArchive", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Arşiv çıkarılamadı." : msg])
                }
            }
        }, completion: { job in
            if job.state == .done { completion(.success(dest)) }
            else if case .failed(let m) = job.state {
                completion(.failure(NSError(domain: "OCArchive", code: 3, userInfo: [NSLocalizedDescriptionKey: m])))
            }
        })
    }

    /// Runs `p` to the end with stderr going to a temporary file and returns its last lines.
    /// A pipe read only after exit would deadlock once the tool writes more than the pipe holds
    /// (~64 KB, e.g. one warning per entry of a large archive).
    private static func runCollectingErrors(_ p: Process) throws -> String {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let h = try FileHandle(forWritingTo: log)
        defer { try? h.close() }
        p.standardError = h
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let data = (try? Data(contentsOf: log)) ?? Data()
        let text = String(decoding: data.suffix(2000), as: UTF8.self)
        return text.split(separator: "\n").suffix(3).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops browse caches older than three days.
    static func cleanCache() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let limit = Date().addingTimeInterval(-3 * 86400)
            let dirs = (try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for d in dirs {
                let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m < limit { try? fm.removeItem(at: d) }
            }
        }
    }

    /// Unmounts images attached by the app.
    static func detachAll() {
        for mp in mounted {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["detach", mp, "-quiet"]
            try? p.run()
            p.waitUntilExit()
        }
        mounted = []
    }
}
