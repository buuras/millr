import AppKit
import Darwin

extension Notification.Name {
    static let jobsChanged = Notification.Name("OCJobsChanged")
}

/// One undoable step recorded by a finished job.
enum UndoOp {
    /// An item now at `to` used to be at `from`.
    case moved(from: URL, to: URL)
    /// A new item was created at this location.
    case created(URL)
}

/// A long-running file operation with progress, pause/resume and cancel.
/// Progress fields are written by the worker thread and read by the UI timer under `lock`.
final class FileJob {
    enum Kind { case copy, move, extract, other }
    enum State: Equatable { case running, paused, done, failed(String), cancelled }

    let kind: Kind
    let title: String
    let created = Date()

    private let lock = NSLock()
    private let pauseCond = NSCondition()
    private var _paused = false
    private var _cancelled = false

    private var _state: State = .running
    private var _total: Int64 = 0
    private var _base: Int64 = 0      // bytes of finished top-level items
    private var _item: Int64 = 0      // finished files inside the current item
    private var _current: Int64 = 0   // progress inside the current file
    private var _files = 0
    private var _doneFiles = 0
    private var _name = ""
    private var pausedTime: TimeInterval = 0
    private var pauseStart: Date?

    /// Filled by the worker; read on completion.
    var ops: [UndoOp] = []
    var results: [URL] = []
    var indeterminate = false
    var onCancel: (() -> Void)?

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    var state: State {
        get { locked { _state } }
        set { locked { _state = newValue } }
    }
    var isFinished: Bool {
        switch state { case .running, .paused: return false; default: return true }
    }
    /// True while the worker thread runs (the state turns final a moment later, on the main thread).
    private var _working = false
    var isWorking: Bool {
        get { locked { _working } }
        set { locked { _working = newValue } }
    }
    var isCancelled: Bool { pauseCond.lock(); defer { pauseCond.unlock() }; return _cancelled }

    struct Snapshot {
        var done: Int64, total: Int64, files: Int, doneFiles: Int, name: String, elapsed: TimeInterval
    }

    var snapshot: Snapshot {
        locked {
            let paused = pausedTime + (pauseStart.map { Date().timeIntervalSince($0) } ?? 0)
            return Snapshot(done: min(_total, _base + _item + _current), total: _total, files: _files,
                            doneFiles: _doneFiles, name: _name, elapsed: Date().timeIntervalSince(created) - paused)
        }
    }

    func setTotals(bytes: Int64, files: Int) { locked { _total = bytes; _files = files } }
    func beginItem(_ name: String) { locked { _name = name; _item = 0; _current = 0 } }
    func finishItem(size: Int64) { locked { _base += size; _item = 0; _current = 0 } }
    func fileStarted(_ name: String) { locked { _name = name; _current = 0 } }
    func fileFinished(size: Int64) { locked { _item += size; _current = 0; _doneFiles += 1 } }
    func fileProgress(_ bytes: Int64) { locked { _current = bytes } }

    func pause() {
        pauseCond.lock(); _paused = true; pauseCond.unlock()
        locked { if _state == .running { _state = .paused; pauseStart = Date() } }
        NotificationCenter.default.post(name: .jobsChanged, object: nil)
    }

    func resume() {
        pauseCond.lock(); _paused = false; pauseCond.broadcast(); pauseCond.unlock()
        locked {
            if _state == .paused { _state = .running }
            if let s = pauseStart { pausedTime += Date().timeIntervalSince(s); pauseStart = nil }
        }
        NotificationCenter.default.post(name: .jobsChanged, object: nil)
    }

    func cancel() {
        pauseCond.lock(); _cancelled = true; _paused = false; pauseCond.broadcast(); pauseCond.unlock()
        onCancel?()
    }

    /// Blocks while paused. Returns false once the job is cancelled.
    func checkpoint() -> Bool {
        pauseCond.lock()
        while _paused && !_cancelled { pauseCond.wait() }
        let ok = !_cancelled
        pauseCond.unlock()
        return ok
    }
}

enum ConflictChoice { case replace, skip, keepBoth, cancel }

/// Runs copy/move jobs in the background and asks the user about name conflicts.
final class FileJobs {
    static let shared = FileJobs()
    private(set) var jobs: [FileJob] = []
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    private let fm = FileManager.default

    private func add(_ job: FileJob) {
        jobs.append(job)
        NotificationCenter.default.post(name: .jobsChanged, object: nil)
    }

    func dismiss(_ job: FileJob) {
        jobs.removeAll { $0 === job }
        NotificationCenter.default.post(name: .jobsChanged, object: nil)
    }

    static func isFailure(_ s: FileJob.State) -> Bool { if case .failed = s { return true }; return false }

    var hasActive: Bool { jobs.contains { !$0.isFinished } }

    /// Generic background job. `work` throws to fail; it should poll `job.checkpoint()`.
    @discardableResult
    func run(_ job: FileJob, work: @escaping (FileJob) throws -> Void, completion: @escaping (FileJob) -> Void) -> FileJob {
        add(job)
        queue.addOperation {
            var final: FileJob.State = .done
            job.isWorking = true
            defer { job.isWorking = false }
            do {
                try work(job)
                if job.isCancelled { final = .cancelled }
            } catch {
                final = job.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                job.state = final
                NotificationCenter.default.post(name: .jobsChanged, object: nil)
                completion(job)
            }
        }
        return job
    }

    // MARK: Copy / move

    func transfer(_ urls: [URL], to dir: URL, move: Bool, completion: @escaping (FileJob) -> Void) {
        let n = urls.count
        let what = n == 1 ? urls[0].lastPathComponent : Fmt.items(n)
        let job = FileJob(kind: move ? .move : .copy,
                          title: L(move ? "Moving %@ → %@" : "Copying %@ → %@", what, dir.lastPathComponent))
        run(job, work: { [weak self] job in
            guard let self else { return }
            try self.performTransfer(urls, to: dir, move: move, job: job)
        }, completion: completion)
    }

    /// Moves every item to an exact location (used by undo/redo).
    func movePairs(_ pairs: [(from: URL, to: URL)], title: String, completion: @escaping (FileJob) -> Void) {
        let job = FileJob(kind: .move, title: title)
        run(job, work: { [weak self] job in
            guard let self else { return }
            job.setTotals(bytes: 0, files: pairs.count)
            var failures: [String] = []
            for p in pairs {
                guard job.checkpoint() else { return }
                job.beginItem(p.from.lastPathComponent)
                guard FileOps.exists(p.from) else {
                    failures.append(L("“%@” not found", p.from.lastPathComponent))
                    continue
                }
                do {
                    try? self.fm.createDirectory(at: p.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let dest: URL
                    if FileOps.sameVolume(p.from, p.to.deletingLastPathComponent()) {
                        if FileOps.exists(p.to) && FileOps.sameItem(p.from, p.to) {
                            // Case-only rename (a.txt <-> A.txt) on a case-insensitive volume: same file.
                            try FileOps.renamePlain(p.from, p.to)
                            dest = p.to
                        } else {
                            dest = try FileOps.place(p.to) { try FileOps.renameExcl(p.from, $0) }
                        }
                        job.ops.append(.moved(from: p.from, to: dest))
                    } else {
                        dest = try self.copyIntoPlace(p.from, preferred: p.to, job: job)
                        guard !job.isCancelled else { try? self.fm.removeItem(at: dest); return }
                        do {
                            try self.fm.removeItem(at: p.from)
                        } catch {
                            job.ops.append(.created(dest))
                            throw error
                        }
                        job.ops.append(.moved(from: p.from, to: dest))
                    }
                    job.results.append(dest)
                    job.fileFinished(size: 0)
                } catch {
                    if job.isCancelled { return }
                    failures.append("“\(p.from.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                throw NSError(domain: "OCJobs", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    L("%d items could not be undone. ", failures.count) + failures.prefix(3).joined(separator: "; ")])
            }
        }, completion: completion)
    }

    private func itemSize(_ u: URL) -> (bytes: Int64, files: Int) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let v = try? u.resourceValues(forKeys: keys) else { return (0, 1) }
        if v.isDirectory != true || v.isSymbolicLink == true { return (Int64(v.fileSize ?? 0), 1) }
        var bytes: Int64 = 0, files = 0
        if let e = fm.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil) {
            for case let f as URL in e {
                guard let fv = try? f.resourceValues(forKeys: keys), fv.isDirectory != true else { continue }
                bytes += Int64(fv.fileSize ?? 0)
                files += 1
            }
        }
        return (bytes, max(files, 1))
    }

    private func performTransfer(_ urls: [URL], to dir: URL, move: Bool, job: FileJob) throws {
        // Same-volume moves are renames: no size scan needed.
        let renames = move ? urls.map { FileOps.sameVolume($0, dir) } : urls.map { _ in false }
        var sizes: [Int64] = []
        var total: Int64 = 0, files = 0
        for (i, u) in urls.enumerated() {
            guard job.checkpoint() else { return }
            if renames[i] { sizes.append(0); files += 1; continue }
            let s = itemSize(u)
            sizes.append(s.bytes); total += s.bytes; files += s.files
        }
        job.setTotals(bytes: total, files: files)

        var applyAll: ConflictChoice?
        for (i, src) in urls.enumerated() {
            guard job.checkpoint() else { return }
            let srcDir = src.deletingLastPathComponent()
            let intoOwnFolder = srcDir.standardizedFileURL.path == dir.standardizedFileURL.path || FileOps.sameItem(srcDir, dir)
            if move && intoOwnFolder { continue }
            job.beginItem(src.lastPathComponent)

            var dest = dir.appendingPathComponent(src.lastPathComponent)
            var replacing: URL?
            if FileOps.exists(dest) {
                let choice: ConflictChoice
                if intoOwnFolder || FileOps.sameItem(src, dest) || FileOps.contains(dest, src) {
                    // Copying into its own folder, or the "existing" item is the source (or holds it):
                    // replacing would throw the source away.
                    choice = .keepBoth
                } else if let a = applyAll {
                    choice = a
                } else {
                    let (c, all) = askConflict(name: src.lastPathComponent, into: dir, remaining: urls.count - i)
                    if all { applyAll = c }
                    choice = c
                }
                switch choice {
                case .cancel: job.cancel(); return
                case .skip: job.finishItem(size: sizes[i]); continue
                case .keepBoth: dest = FileOps.uniqueURL(for: src.lastPathComponent, in: dir)
                case .replace: replacing = dest
                }
            }

            if move && renames[i] {
                if let old = replacing {
                    let trashed = try trash(old, job: job)
                    do { try FileOps.renameExcl(src, dest) } catch {
                        try? fm.moveItem(at: trashed, to: old)      // put the replaced item back
                        job.ops.removeLast()
                        throw error
                    }
                } else {
                    dest = try FileOps.place(dest) { try FileOps.renameExcl(src, $0) }
                }
                job.fileFinished(size: 0)
            } else {
                // The copy lands under a temporary name first; the existing item is replaced only
                // after the copy is complete, and a failed copy never touches anything else.
                if let old = replacing {
                    let tmp = try copyToTemp(src, in: dir, job: job)
                    guard !job.isCancelled else { try? fm.removeItem(at: tmp); return }
                    let trashed: URL
                    do { trashed = try trash(old, job: job) } catch { try? fm.removeItem(at: tmp); throw error }
                    do { try FileOps.renameExcl(tmp, dest) } catch {
                        try? fm.moveItem(at: trashed, to: old)
                        job.ops.removeLast()
                        try? fm.removeItem(at: tmp)
                        throw error
                    }
                } else {
                    dest = try copyIntoPlace(src, preferred: dest, job: job)
                    guard !job.isCancelled else { try? fm.removeItem(at: dest); return }
                }
                if move {
                    do { try fm.removeItem(at: src) } catch {
                        job.ops.append(.created(dest))   // the copy stays undoable
                        throw error
                    }
                }
            }
            job.ops.append(move ? .moved(from: src, to: dest) : .created(dest))
            job.results.append(dest)
            job.finishItem(size: sizes[i])
        }
    }

    /// Moves `u` to the Trash and records it; returns where it went.
    private func trash(_ u: URL, job: FileJob) throws -> URL {
        var trashed: NSURL?
        try fm.trashItem(at: u, resultingItemURL: &trashed)
        guard let t = trashed as URL? else { throw CocoaError(.fileWriteUnknown) }
        job.ops.append(.moved(from: u, to: t))
        return t
    }

    /// Copies `src` to a hidden temporary name inside `dir`. On failure the partial copy is removed.
    private func copyToTemp(_ src: URL, in dir: URL, job: FileJob) throws -> URL {
        let tmp = dir.appendingPathComponent(".oc-part-\(UUID().uuidString.prefix(8))-\(src.lastPathComponent)")
        do {
            try copyItem(src, to: tmp, job: job)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return tmp
    }

    /// Copies `src` and gives it `preferred`'s name, or the next free "name N" if that is taken by
    /// then (another job or app). Never overwrites.
    private func copyIntoPlace(_ src: URL, preferred: URL, job: FileJob) throws -> URL {
        let tmp = try copyToTemp(src, in: preferred.deletingLastPathComponent(), job: job)
        if job.isCancelled { try? fm.removeItem(at: tmp); throw CocoaError(.userCancelled) }
        do {
            return try FileOps.place(preferred) { try FileOps.renameExcl(tmp, $0) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: copyfile with progress

    // <copyfile.h> flags (composite macros are not imported into Swift).
    private static let COPY_ALL: UInt32 = 0xF               // ACL | STAT | XATTR | DATA
    private static let COPY_RECURSIVE: UInt32 = 1 << 15
    private static let COPY_NOFOLLOW_SRC: UInt32 = 1 << 18
    private static let COPY_CLONE: UInt32 = 1 << 24

    private final class CopyContext {
        let job: FileJob
        var failedPath: String?
        var failedErrno: Int32 = 0
        init(_ job: FileJob) { self.job = job }
    }

    private static let callback: copyfile_callback_t = { what, stage, state, src, _, ctx in
        guard let ctx else { return Int32(COPYFILE_QUIT) }
        let c = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
        let job = c.job
        // CONTINUE on an error makes copyfile skip the item and still report success; a move
        // would then delete a source that was never copied. Stop the whole copy instead.
        if stage == Int32(COPYFILE_ERR) {
            c.failedErrno = errno
            c.failedPath = src.map { String(cString: $0) }
            return Int32(COPYFILE_QUIT)
        }
        guard job.checkpoint() else { return Int32(COPYFILE_QUIT) }
        switch (what, stage) {
        case (Int32(COPYFILE_RECURSE_FILE), Int32(COPYFILE_START)):
            if let src { job.fileStarted((String(cString: src) as NSString).lastPathComponent) }
        case (Int32(COPYFILE_RECURSE_FILE), Int32(COPYFILE_FINISH)):
            var st = stat()
            let size: Int64 = (src.map { lstat($0, &st) == 0 } ?? false) ? Int64(st.st_size) : 0
            job.fileFinished(size: size)
        case (Int32(COPYFILE_COPY_DATA), Int32(COPYFILE_PROGRESS)):
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 { job.fileProgress(Int64(copied)) }
        default: break
        }
        return Int32(COPYFILE_CONTINUE)
    }

    func copyItem(_ src: URL, to dst: URL, job: FileJob) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let ctx = CopyContext(job)
        let unmanaged = Unmanaged.passRetained(ctx)
        defer { unmanaged.release() }
        // Both values are stored as-is (the function pointer itself, not a pointer to it).
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(Self.callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
        let flags = Self.COPY_ALL | Self.COPY_RECURSIVE | Self.COPY_NOFOLLOW_SRC | Self.COPY_CLONE
        let r = copyfile(src.path, dst.path, state, copyfile_flags_t(flags))
        let code = errno
        if r != 0 || ctx.failedPath != nil {
            if job.isCancelled && ctx.failedPath == nil { throw CocoaError(.userCancelled) }
            let path = ctx.failedPath ?? src.path
            let posix = ctx.failedPath != nil ? ctx.failedErrno : code
            let reason = String(cString: strerror(posix == 0 ? EIO : posix))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(posix == 0 ? EIO : posix), userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: L("Could not copy “%@”: %@", (path as NSString).lastPathComponent, reason),
            ])
        }
    }

    // MARK: Conflicts

    /// Debug: answers conflict dialogs without showing them (stress test).
    var testConflictChoice: ConflictChoice?

    private func askConflict(name: String, into dir: URL, remaining: Int) -> (ConflictChoice, Bool) {
        if let c = testConflictChoice { return (c, true) }
        var result: (ConflictChoice, Bool) = (.cancel, false)
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("“%@” already exists", name)
            alert.informativeText = L("An item with the same name already exists in “%@”. The replaced item is moved to the Trash.", dir.lastPathComponent)
            alert.addButton(withTitle: L("Replace"))
            alert.addButton(withTitle: L("Keep Both"))
            alert.addButton(withTitle: L("Skip"))
            alert.addButton(withTitle: L("Cancel"))
            if remaining > 1 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = L("Apply to all remaining conflicts")
            }
            let r = alert.runModal()
            let all = alert.suppressionButton?.state == .on
            switch r {
            case .alertFirstButtonReturn: result = (.replace, all)
            case .alertSecondButtonReturn: result = (.keepBoth, all)
            case .alertThirdButtonReturn: result = (.skip, all)
            default: result = (.cancel, false)
            }
        }
        return result
    }
}

// MARK: - Progress overlay

/// Card stack shown at the bottom-right of the window while jobs run.
final class JobsView: NSView {
    private let stack = NSStackView()
    private var rows: [ObjectIdentifier: JobRowView] = [:]
    private var timer: Timer?
    private var leaving = Set<ObjectIdentifier>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .jobsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themed), name: .themeChanged, object: nil)
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Let clicks through outside the cards.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self || v === stack ? nil : v
    }

    @objc private func themed() { rows.values.forEach { $0.applyTheme() } }

    @objc private func sync() {
        let jobs = FileJobs.shared.jobs
        let ids = Set(jobs.map { ObjectIdentifier($0) })
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
            leaving.remove(id)
        }
        for job in jobs where rows[ObjectIdentifier(job)] == nil {
            let r = JobRowView(job: job)
            rows[ObjectIdentifier(job)] = r
            stack.addArrangedSubview(r)
            if job.state == .running, job.kind != .other {
                // Quick jobs never flash a card: show only if still running after 0.4 s.
                r.isHidden = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak r] in
                    guard let r else { return }
                    r.isHidden = r.job.isFinished && !FileJobs.isFailure(r.job.state)
                }
            }
        }
        rows.values.forEach { $0.update() }
        // Finished jobs leave after a short delay; failures stay until dismissed.
        for job in jobs where job.isFinished && !FileJobs.isFailure(job.state) && !leaving.contains(ObjectIdentifier(job)) {
            leaving.insert(ObjectIdentifier(job))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { FileJobs.shared.dismiss(job) }
        }
        isHidden = jobs.isEmpty
        if FileJobs.shared.hasActive {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    self?.rows.values.forEach { $0.update() }
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

final class JobRowView: NSView {
    let job: FileJob
    private let icon = NSImageView()
    private let title = label("", size: 12, weight: .semibold)
    private let detail = label("", size: 11)
    private let bar = NSProgressIndicator()
    private lazy var pauseBtn = symbolButton("pause.circle.fill", L("Pause / resume"), target: self, action: #selector(togglePause))
    private lazy var cancelBtn = symbolButton("xmark.circle.fill", L("Cancel"), target: self, action: #selector(cancel))

    init(job: FileJob) {
        self.job = job
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -3)

        let symbol: String
        switch job.kind {
        case .copy: symbol = "doc.on.doc"
        case .move: symbol = "arrow.right.doc.on.clipboard"
        case .extract: symbol = "archivebox"
        case .other: symbol = "gearshape"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = job.title
        title.font = Fonts.rounded(12, .semibold)
        detail.font = FileRowView.smallFont
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = job.indeterminate
        bar.translatesAutoresizingMaskIntoConstraints = false
        if job.indeterminate { bar.startAnimation(nil) }
        pauseBtn.isHidden = job.indeterminate

        [icon, title, detail, bar, pauseBtn, cancelBtn].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 360),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: pauseBtn.leadingAnchor, constant: -6),
            cancelBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cancelBtn.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            pauseBtn.trailingAnchor.constraint(equalTo: cancelBtn.leadingAnchor, constant: -2),
            pauseBtn.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyTheme()
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        let t = Theme.current
        layer?.backgroundColor = t.preview.cgColor
        layer?.borderColor = t.separator.cgColor
        title.textColor = t.text
        detail.textColor = t.secondary
        icon.contentTintColor = t.accent
        pauseBtn.contentTintColor = t.secondary
        cancelBtn.contentTintColor = t.secondary
    }

    func update() {
        let s = job.snapshot
        let t = Theme.current
        switch job.state {
        case .running, .paused:
            let paused = job.state == .paused
            pauseBtn.image = NSImage(systemSymbolName: paused ? "play.circle.fill" : "pause.circle.fill", accessibilityDescription: nil)
            if job.indeterminate {
                detail.stringValue = s.name.isEmpty ? L("Working…") : s.name
                return
            }
            let frac = s.total > 0 ? Double(s.done) / Double(s.total) : (s.files > 0 ? Double(s.doneFiles) / Double(s.files) : 0)
            bar.doubleValue = frac
            var parts = ["\(Fmt.size(s.done)) / \(Fmt.size(s.total))"]
            if paused {
                parts.append(L("paused"))
            } else if s.elapsed > 0.5, s.done > 0 {
                let speed = Double(s.done) / s.elapsed
                parts.append(L("%@/s", Fmt.size(Int64(speed))))
                if speed > 0, s.total > s.done { parts.append(L("~%@ left", Fmt.duration(Double(s.total - s.done) / speed))) }
            }
            if s.files > 1 { parts.append(L("%d/%d files", s.doneFiles, s.files)) }
            detail.stringValue = parts.joined(separator: "  ·  ")
            detail.toolTip = s.name
        case .done:
            finish("checkmark.circle.fill", L("Done"), t.ageDay)
        case .cancelled:
            finish("xmark.circle", L("Cancelled"), t.secondary)
        case .failed(let msg):
            finish("exclamationmark.triangle.fill", msg, NSColor.systemRed)
            cancelBtn.isHidden = false
            cancelBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close"))
        }
    }

    private func finish(_ symbol: String, _ text: String, _ color: NSColor) {
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = job.state == .done ? 1 : bar.doubleValue
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        detail.stringValue = text
        detail.textColor = color
        pauseBtn.isHidden = true
        cancelBtn.isHidden = true
    }

    @objc private func togglePause() { job.state == .paused ? job.resume() : job.pause() }

    @objc private func cancel() {
        if job.isFinished { FileJobs.shared.dismiss(job) } else { job.cancel() }
    }
}
