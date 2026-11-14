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
        // A trailing number is part of the name ("Report 2024"); it is never stripped.
        let base = ns.deletingPathExtension
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            dest = dir.appendingPathComponent(n)
            i += 1
        } while exists(dest)
        return dest
    }

    /// Same file system object (device + inode), whatever path, symlinked folder or letter case
    /// leads to it. The last path component itself is not followed.
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// True if `inner` is inside folder `outer` (after resolving symlinked parent folders).
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let o = outer.resolvingSymlinksInPath().path
        let i = inner.deletingLastPathComponent().resolvingSymlinksInPath().path
        return i == o || i.hasPrefix(o + "/")
    }

    private static func posixError(_ code: Int32, _ u: URL) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: u.path])
    }

    /// rename(2) that fails with EEXIST instead of replacing an existing item.
    static func renameExcl(_ a: URL, _ b: URL) throws {
        if renamex_np(a.path, b.path, UInt32(RENAME_EXCL)) != 0 { throw posixError(errno, a) }
    }

    /// Plain rename(2); used for case-only renames, where the "existing" item is the file itself.
    static func renamePlain(_ a: URL, _ b: URL) throws {
        if Darwin.rename(a.path, b.path) != 0 { throw posixError(errno, a) }
    }

    /// Runs `op` with `preferred`, and with the next free "name N" while the name is taken.
    static func place(_ preferred: URL, _ op: (URL) throws -> Void) throws -> URL {
        var d = preferred
        for _ in 0..<1000 {
            do {
                try op(d)
                return d
            } catch let e as POSIXError where e.code == .EEXIST {
                d = uniqueURL(for: preferred.lastPathComponent, in: preferred.deletingLastPathComponent())
            }
        }
        throw posixError(EEXIST, preferred)
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
        let rd = dir.resolvingSymlinksInPath().path
        return urls.contains { u in
            let p = u.standardizedFileURL.path
            // The item itself is not followed (moving a symlink is fine), only its parent folders.
            let rp = u.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(u.lastPathComponent).path
            return d == p || d.hasPrefix(p + "/") || rd == rp || rd.hasPrefix(rp + "/")
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
                let base = ns.deletingPathExtension + L(" copy")
                let dest = uniqueURL(for: ext.isEmpty ? base : "\(base).\(ext)", in: u.deletingLastPathComponent())
                try fm.copyItem(at: u, to: dest)
                return dest
            }
        }, completion: completion)
    }

    static func newFolder(in dir: URL) throws -> URL {
        let dest = uniqueURL(for: L("New Folder"), in: dir)
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        return dest
    }

    static func newFile(in dir: URL) throws -> URL {
        // O_EXCL: never truncate a file another app created under the same name meanwhile.
        return try place(uniqueURL(for: L("New Text File.txt"), in: dir)) { u in
            let fd = open(u.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd < 0 { throw posixError(errno, u) }
            close(fd)
        }
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        if dest.path == url.path { return url }
        // Case-only rename on a case-insensitive volume: the "existing" item is the file itself.
        if exists(dest) && sameItem(url, dest) {
            try renamePlain(url, dest)
            return dest
        }
        do {
            try renameExcl(url, dest)
        } catch let e as POSIXError where e.code == .EEXIST {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path])
        }
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
                dest = uniqueURL(for: L("Archive.zip"), in: dir)
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = dir
                // "--": names starting with "-" are not options.
                p.arguments = ["-r", "-y", "-q", dest.path, "--"] + urls.map(\.lastPathComponent)
            }
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                try? fm.removeItem(at: dest)       // no half-written archive
                throw CocoaError(.fileWriteUnknown)
            }
            return [dest]
        }, completion: completion)
    }

    static func setLabel(_ urls: [URL], _ n: Int) {
        for u in urls {
            try? (u as NSURL).setResourceValue(NSNumber(value: n), forKey: .labelNumberKey)
        }
    }
}
