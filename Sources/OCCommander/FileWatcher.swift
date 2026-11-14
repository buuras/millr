import Foundation
import CoreServices

/// Watches the whole file system (directory-level FSEvents) and reports changed folders.
final class FileWatcher {
    static let shared = FileWatcher()
    var onChange: (([String]) -> Void)?
    private var stream: FSEventStreamRef?

    func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            var out: [String] = []
            out.reserveCapacity(count)
            for case let s as String in arr {
                var p = s
                if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                out.append(p)
                if p.hasPrefix("/private/") { out.append(String(p.dropFirst(8))) }
            }
            watcher.onChange?(out)
        }
        stream = FSEventStreamCreate(
            nil, callback, &ctx, ["/"] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }
}
