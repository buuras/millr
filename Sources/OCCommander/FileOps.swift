import AppKit

enum FileOps {
    static let fm = FileManager.default

    static func exists(_ u: URL) -> Bool {
        fm.fileExists(atPath: u.path) || (try? u.checkResourceIsReachable()) == true
            || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil
    }

    static func uniqueURL(for name: String, in dir: URL) -> URL {
        var dest = dir.appendingPathComponent(name)
        if !exists(dest) { return dest }
        let ns = name as NSString
        let ext = ns.pathExtension
        var base = ns.deletingPathExtension
        // strip existing " copy N" style suffix number to avoid "a 2 2"
        if let r = base.range(of: #" \d+$"#, options: .regularExpression) { base.removeSubrange(r) }
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            dest = dir.appendingPathComponent(n)
            i += 1
        } while exists(dest)
        return dest
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    /// Returns true if `dir` is one of `urls` or inside one of them.
    static func isInvalidTarget(_ dir: URL, for urls: [URL]) -> Bool {
        let d = dir.standardizedFileURL.path
        return urls.contains { u in
            let p = u.standardizedFileURL.path
            return d == p || d.hasPrefix(p + "/")
        }
    }

    private static func run(_ work: @escaping () throws -> [URL], completion: @escaping ([URL], Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try work()
                DispatchQueue.main.async { completion(r, nil) }
            } catch {
                DispatchQueue.main.async { completion([], error) }
            }
        }
    }

    static func duplicate(_ urls: [URL], completion: @escaping ([URL], Error?) -> Void) {
        run({
            try urls.map { u in
                let ns = u.lastPathComponent as NSString
                let ext = ns.pathExtension
                let base = ns.deletingPathExtension + " kopya"
                let dest = uniqueURL(for: ext.isEmpty ? base : "\(base).\(ext)", in: u.deletingLastPathComponent())
                try fm.copyItem(at: u, to: dest)
                return dest
            }
        }, completion: completion)
    }

    static func newFolder(in dir: URL) throws -> URL {
        let dest = uniqueURL(for: "Yeni Klasör", in: dir)
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        return dest
    }

    static func newFile(in dir: URL) throws -> URL {
        let dest = uniqueURL(for: "Yeni Metin Dosyası.txt", in: dir)
        guard fm.createFile(atPath: dest.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return dest
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        if dest.path == url.path { return url }
        // allow case-only rename on case-insensitive volumes
        if dest.path.lowercased() != url.path.lowercased() && exists(dest) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path])
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    static func compress(_ urls: [URL], in dir: URL, completion: @escaping ([URL], Error?) -> Void) {
        run({
            let p = Process()
            let dest: URL
            if urls.count == 1 {
                dest = uniqueURL(for: urls[0].lastPathComponent + ".zip", in: dir)
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, dest.path]
            } else {
                dest = uniqueURL(for: "Arşiv.zip", in: dir)
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = dir
                p.arguments = ["-r", "-y", "-q", dest.path] + urls.map(\.lastPathComponent)
            }
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
            return [dest]
        }, completion: completion)
    }

    static func setLabel(_ urls: [URL], _ n: Int) {
        for u in urls {
            try? (u as NSURL).setResourceValue(NSNumber(value: n), forKey: .labelNumberKey)
        }
    }
}
