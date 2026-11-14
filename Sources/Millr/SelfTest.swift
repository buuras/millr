import AppKit

/// Debug: `Millr --selftest <empty dir>` drives real app code paths
/// (jobs, undo/redo, rename, archives, smart folders, palette scoring) and prints PASS/FAIL lines.
final class SelfTest {
    private let wc: MainWindowController
    private let root: URL
    private var steps: [(String, (@escaping () -> Void) -> Void)] = []
    private var failures = 0
    private let fm = FileManager.default

    init(wc: MainWindowController, root: URL) {
        self.wc = wc
        self.root = root
    }

    private func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS  \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    private func step(_ name: String, _ f: @escaping (@escaping () -> Void) -> Void) { steps.append((name, f)) }

    /// Polls until `cond` holds (or times out), then continues.
    private func wait(timeout: TimeInterval = 20, until cond: @escaping () -> Bool, then: @escaping () -> Void) {
        let start = Date()
        func poll() {
            if cond() || Date().timeIntervalSince(start) > timeout { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    private func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
    private func count(_ u: URL) -> Int { (try? fm.contentsOfDirectory(atPath: u.path).count) ?? -1 }

    func run() {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        fm.createFile(atPath: src.appendingPathComponent("a.txt").path, contents: Data("merhaba".utf8))
        var big = Data(count: 64 << 20)
        big.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        fm.createFile(atPath: src.appendingPathComponent("big.bin").path, contents: big)
        for i in 0..<300 {
            fm.createFile(atPath: src.appendingPathComponent("sub/f\(i).txt").path, contents: Data(repeating: 65, count: 1000 + i))
        }
        let items = ["a.txt", "big.bin", "sub"].map { src.appendingPathComponent($0) }

        step("kopyalama işi") { next in
            let t0 = Date()
            self.wc.transfer(items, to: dst, move: false)
            self.wait(until: { self.count(dst) == 3 && !FileJobs.shared.hasActive }) {
                let bigCopy = (try? Data(contentsOf: dst.appendingPathComponent("big.bin"))) == big
                self.check(self.count(dst) == 3 && self.count(dst.appendingPathComponent("sub")) == 300 && bigCopy,
                           String(format: "copy: 3 öğe, 300 alt dosya, 64 MB içerik aynı (%.2f sn)", Date().timeIntervalSince(t0)))
                next()
            }
        }
        step("geri al: kopyalama") { next in
            self.check(self.wc.undo.canUndo && self.wc.undo.undoActionName == L("Copying"), "undo adı = \(L("Copying"))")
            self.wc.undo.undo()
            self.wait(until: { self.count(dst) == 0 }) {
                self.check(self.count(dst) == 0, "undo copy: kopyalar Çöp'e gitti")
                next()
            }
        }
        step("yinele: kopyalama") { next in
            self.check(self.wc.undo.canRedo, "redo mümkün")
            self.wc.undo.redo()
            self.wait(until: { self.count(dst) == 3 && !FileJobs.shared.hasActive }) {
                self.check(self.count(dst) == 3, "redo: kopyalar Çöp'ten geri geldi")
                next()
            }
        }
        step("taşıma + geri al") { next in
            let a = dst.appendingPathComponent("a.txt")
            let moved = src.appendingPathComponent("sub/a.txt")
            self.wc.transfer([a], to: src.appendingPathComponent("sub"), move: true)
            self.wait(until: { self.exists(moved) && !FileJobs.shared.hasActive }) {
                self.check(self.exists(moved) && !self.exists(a), "move: a.txt alt klasöre taşındı")
                self.wc.undo.undo()
                self.wait(until: { self.exists(a) && !FileJobs.shared.hasActive }) {
                    self.check(self.exists(a) && !self.exists(moved), "undo move: a.txt eski yerinde")
                    next()
                }
            }
        }
        step("aynı klasöre kopyala → ikisini de tut") { next in
            let a = dst.appendingPathComponent("a.txt")
            self.wc.transfer([a], to: dst, move: false)
            self.wait(until: { self.count(dst) == 4 && !FileJobs.shared.hasActive }) {
                self.check(self.exists(dst.appendingPathComponent("a 2.txt")), "çakışmasız: a 2.txt oluştu")
                next()
            }
        }
        step("iptal") { next in
            let target = self.root.appendingPathComponent("cancel")
            try? self.fm.createDirectory(at: target, withIntermediateDirectories: true)
            self.wc.transfer([src.appendingPathComponent("big.bin")], to: target, move: false)
            DispatchQueue.main.async { FileJobs.shared.jobs.last?.cancel() }
            self.wait(until: { !FileJobs.shared.hasActive }) {
                let state = FileJobs.shared.jobs.last?.state
                self.check(state == .cancelled || state == .done, "iptal: iş durdu (durum: \(String(describing: state)))")
                self.check(state != .cancelled || self.count(target) == 0, "iptal: yarım kopya kalmadı")
                next()
            }
        }
        step("arşiv") { next in
            let zip = self.root.appendingPathComponent("t.zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", src.appendingPathComponent("sub").path, zip.path]
            try? p.run(); p.waitUntilExit()
            Archives.browse(zip) { r in
                if case .success(let dir) = r {
                    self.check(self.count(dir.appendingPathComponent("sub")) == 300, "zip içine gir: 300 dosya görünüyor")
                    self.check(Archives.origin(ofRoot: dir.path) == zip, "arşiv kökünden yukarı = zip dosyası")
                } else { self.check(false, "zip açılamadı: \(r)") }
                next()
            }
        }
        step("akıllı klasör") { next in
            let url = SmartFolders.shared.url(for: SmartFolders.defaults[0])
            let node = FileNode.node(for: url)
            self.check(node.isVirtual && VirtualFolders.isVirtual(url), "sanal klasör düğümü")
            self.wc.activePane.open(folder: url)
            self.wait(timeout: 8, until: { !node.children.isEmpty }) {
                print("INFO  '\(node.name)' sonuç: \(node.children.count)")
                self.check(self.wc.activePane.currentFolderNode === node, "panel sanal klasörü gösteriyor")
                next()
            }
        }
        step("palet puanlama") { next in
            let q = Array("dwn")
            self.check(CommandPalette.score(q, "Downloads") != nil && CommandPalette.score(q, "Desktop") == nil, "bulanık eşleşme")
            self.check(CommandPalette.score(Array("belge"), "Belgeler") != nil, "Türkçe eşleşme")
            next()
        }
        step("bulut") { next in
            for p in Cloud.providers() { print("INFO  bulut: \(p.name) → \(p.url.path)") }
            next()
        }

        var i = 0
        func advance() {
            guard i < steps.count else {
                print(failures == 0 ? "SELFTEST OK" : "SELFTEST \(failures) HATA")
                try? fm.removeItem(at: root)
                NSApp.terminate(nil)
                return
            }
            let (name, f) = steps[i]
            i += 1
            print("--- \(name)")
            f(advance)
        }
        advance()
    }
}
