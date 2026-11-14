import AppKit
import Darwin

/// Debug: `Millr --stress <volume A> <volume B>` runs heavy scenarios against a generated
/// data set (see stress/gen.py) and prints timing, main-thread stall and memory lines.
/// A holds the data; B is a second volume for real (non-clone) cross-volume copies.
final class StressTest {
    private let wc: MainWindowController
    private let a: URL, b: URL
    private let fm = FileManager.default
    private var steps: [(String, (@escaping () -> Void) -> Void)] = []
    private var failures = 0
    private let watchdog = Watchdog()

    init(wc: MainWindowController, a: URL, b: URL) {
        self.wc = wc
        self.a = a
        self.b = b
    }

    // MARK: Helpers

    private func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS  \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    private func info(_ s: String) { print("INFO  \(s)") }

    private func step(_ name: String, _ f: @escaping (@escaping () -> Void) -> Void) { steps.append((name, f)) }

    private func wait(timeout: TimeInterval = 120, until cond: @escaping () -> Bool, then: @escaping () -> Void) {
        let start = Date()
        func poll() {
            if cond() || Date().timeIntervalSince(start) > timeout { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    /// Runs `f` on the main thread, forces a display pass and returns milliseconds.
    @discardableResult
    private func timed(_ f: () -> Void) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        f()
        wc.window?.displayIfNeeded()
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    private func ms(_ v: Double) -> String { String(format: "%.1f ms", v) }
    private func count(_ u: URL) -> Int { (try? fm.contentsOfDirectory(atPath: u.path).count) ?? -1 }
    private func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
    private var pane: PaneViewController { wc.activePane }
    private var lastColumn: ColumnView? { pane.columnsView.columns.last }

    /// Waits until no shown folder is still listing in the background; passes the elapsed ms.
    private func whenLoaded(_ then: @escaping (Double) -> Void) {
        let t0 = CFAbsoluteTimeGetCurrent()
        wait(timeout: 60, until: { !self.pane.columnsView.path.contains { $0.isLoading } }) {
            self.wc.window?.displayIfNeeded()
            then((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
    }

    private func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "-" }
        let s = v.sorted()
        let avg = v.reduce(0, +) / Double(v.count)
        return String(format: "ort %.1f · p95 %.1f · en çok %.1f ms (n=%d)", avg, s[Int(Double(s.count - 1) * 0.95)], s.last!, v.count)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func dirSize(_ u: URL) -> Int64 {
        var total: Int64 = 0
        let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    private func fileCount(_ u: URL) -> Int {
        var n = 0
        let e = fm.enumerator(atPath: u.path)
        while e?.nextObject() != nil { n += 1 }
        return n
    }

    // MARK: Scenarios

    func run() {
        let huge = a.appendingPathComponent("huge"), tree = a.appendingPathComponent("tree")
        let deep = a.appendingPathComponent("deep"), big = a.appendingPathComponent("big")
        let churn = a.appendingPathComponent("churn"), zip = a.appendingPathComponent("many.zip")
        let hugeCount = count(huge)
        info(String(format: "başlangıç belleği %.0f MB · huge=%d öğe", Self.footprintMB(), hugeCount))
        watchdog.start()

        step("dev klasörü aç (soğuk)") { next in
            self.watchdog.reset()
            let t = self.timed { self.pane.open(folder: huge) }
            self.check(self.lastColumn?.folder.isLoading == true, "50k klasör arka planda listeleniyor")
            self.whenLoaded { full in
                self.info("huge açılış (soğuk): ana iş parçacığı \(self.ms(t)) · içerik \(self.ms(t + full)) · \(self.watchdog.report())")
                self.check(self.lastColumn?.items.count == hugeCount, "kolon \(hugeCount) öğeyi gösteriyor")
                let t2 = self.timed { self.pane.open(folder: self.a) }
                let t3 = self.timed { self.pane.open(folder: huge) }
                self.info("huge'dan çık: \(self.ms(t2)) · yeniden aç (ılık): \(self.ms(t3))")
                self.watchdog.reset()
                let t4 = self.timed { self.pane.reloadPane() }
                self.check(self.lastColumn?.items.count == hugeCount, "yenilerken eski liste görünür kalıyor")
                self.whenLoaded { full in
                    self.info("huge yenile (⌘R): ana iş parçacığı \(self.ms(t4)) · içerik \(self.ms(t4 + full)) · \(self.watchdog.report())")
                    self.check(self.lastColumn?.items.count == hugeCount, "yenileme sonrası \(hugeCount) öğe")
                    next()
                }
            }
        }
        step("mikro: listeleme") { next in
            let node = FileNode.node(for: huge)
            var lst: [Double] = [], load: [Double] = [], srt: [Double] = []
            for _ in 0..<5 {
                lst.append(self.timed { _ = try? self.fm.contentsOfDirectory(at: huge, includingPropertiesForKeys: FileNode.baseKeys, options: .skipsHiddenFiles) })
                node.invalidate()
                load.append(self.timed { node.loadChildren() })
                let c = node.children
                srt.append(self.timed { _ = FileNode.sorted(c, for: huge.path) })
            }
            self.info("yalnız listeleme: \(self.stats(lst))")
            self.info("loadChildren: \(self.stats(load))")
            self.info("sıralama (ad): \(self.stats(srt))")
            next()
        }
        step("canlı filtre (50k)") { next in
            guard let c = self.lastColumn else { next(); return }
            var times: [Double] = []
            for s in ["ç", "ça", "çal", "çalı", "çalış", "çalışm", "çalışma", "çalışma 4", "çalışma 42"] {
                times.append(self.timed { self.pane.columnsView.setFilter(s, in: c) })
            }
            self.info("çalışma 42 → \(c.items.count) eşleşme")
            for s in ["x", "xy", "xyz"] { times.append(self.timed { self.pane.columnsView.setFilter(s, in: c) }) }
            let clear = self.timed { self.pane.columnsView.setFilter("", in: c) }
            self.info("filtre tuş başı: \(self.stats(times)) · temizle \(self.ms(clear))")
            self.check(c.items.count == hugeCount, "filtre temizlenince tüm öğeler geri geldi")
            next()
        }
        step("sıralama (50k)") { next in
            var parts: [String] = []
            for (k, name) in [(SortKey.size, "boyut"), (.modified, "tarih"), (.kind, "tür"), (.name, "ad")] {
                let t = self.timed { Prefs.shared.setSort(k, ascending: k == .name, for: huge.path) }
                parts.append("\(name) \(self.ms(t))")
            }
            self.info("sıralama: " + parts.joined(separator: " · "))
            next()
        }
        step("kaydırma (50k)") { next in
            guard let c = self.lastColumn, let table = c.subviewsDeep.compactMap({ $0 as? NSTableView }).first else { next(); return }
            var times: [Double] = []
            for i in 0..<40 {
                let row = i % 2 == 0 ? table.numberOfRows - 1 : Int.random(in: 0..<table.numberOfRows)
                times.append(self.timed { table.scrollRowToVisible(row); table.display() })
            }
            self.info("kaydırma+çizim: \(self.stats(times))")
            next()
        }
        step("klasörler arası hızlı geçiş") { next in
            let dirs = ((try? self.fm.contentsOfDirectory(at: tree, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            var subs: [URL] = []
            for d in dirs.prefix(40) { subs += ((try? self.fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []) }
            var times: [Double] = []
            for _ in 0..<300 {
                guard let u = subs.randomElement() else { break }
                times.append(self.timed { self.pane.open(folder: u) })
            }
            self.info("rastgele klasör açma (100 öğe, 4 seviye): \(self.stats(times))")
            next()
        }
        step("derin yol (60 seviye)") { next in
            var d = deep
            while let sub = (try? self.fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey]))?
                .first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) { d = sub }
            let t = self.timed { self.pane.open(folder: d) }
            self.info("\(self.pane.columnsView.columns.count) kolon açıldı: \(self.ms(t))")
            self.check(self.pane.currentFolder.path == d.path, "en derin klasör gösteriliyor")
            let t2 = self.timed { self.pane.open(folder: self.a) }
            self.info("derin yoldan köke dönüş: \(self.ms(t2))")
            next()
        }
        step("dosya sistemi fırtınası (10k oluştur/sil)") { next in
            self.pane.open(folder: churn)
            self.watchdog.reset()
            let total = 10_000
            DispatchQueue.global().async {
                for i in 0..<total {
                    self.fm.createFile(atPath: churn.appendingPathComponent("f\(i).txt").path, contents: nil)
                    if i % 500 == 499 { usleep(30_000) }
                }
            }
            let t0 = Date()
            self.wait(timeout: 30, until: { self.lastColumn?.items.count == total }) {
                let seen = self.lastColumn?.items.count ?? -1
                self.check(seen == total, String(format: "10k yeni dosya kolona yansıdı (%d görünüyor, %.1f sn)", seen, Date().timeIntervalSince(t0)))
                self.info("fırtına sırasında ana iş parçacığı: \(self.watchdog.report())")
                self.watchdog.reset()
                DispatchQueue.global().async {
                    for i in 0..<total { try? self.fm.removeItem(atPath: churn.appendingPathComponent("f\(i).txt").path) }
                }
                self.wait(timeout: 30, until: { self.lastColumn?.items.count == 0 }) {
                    self.check(self.lastColumn?.items.count == 0, "silinenler kolondan kalktı")
                    self.info("silme sırasında ana iş parçacığı: \(self.watchdog.report())")
                    next()
                }
            }
        }
        step("büyük kopyalama, diskler arası (2 GB) + duraklat") { next in
            let dst = self.b.appendingPathComponent("bigcopy")
            try? self.fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let totalBytes = self.dirSize(big)
            self.pane.open(folder: dst)
            self.watchdog.reset()
            let t0 = Date()
            self.wc.transfer([big], to: dst, move: false)
            guard let job = FileJobs.shared.jobs.last else { next(); return }
            self.wait(until: { job.snapshot.done > totalBytes / 3 || job.isFinished }) {
                job.pause()
                let p0 = job.snapshot.done
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let p1 = job.snapshot.done
                    self.check(job.state == .paused && p1 - p0 < 64 << 20, "duraklatınca ilerleme durdu (\(p1 - p0) bayt fark)")
                    job.resume()
                    self.wait(until: { job.isFinished }) {
                        let secs = job.snapshot.elapsed
                        let copied = self.dirSize(dst.appendingPathComponent("big"))
                        self.check(job.state == .done && copied == totalBytes, "2 GB kopya tamam ve boyut aynı")
                        self.info(String(format: "süre %.1f sn (duraklama hariç) · %.0f MB/sn · duvar saati %.1f sn",
                                         secs, Double(totalBytes) / 1_048_576 / secs, Date().timeIntervalSince(t0)))
                        self.info("kopyalama sırasında ana iş parçacığı: \(self.watchdog.report())")
                        next()
                    }
                }
            }
        }
        step("iptal, diskler arası") { next in
            let dst = self.b.appendingPathComponent("cancel")
            try? self.fm.createDirectory(at: dst, withIntermediateDirectories: true)
            self.wc.transfer([big], to: dst, move: false)
            guard let job = FileJobs.shared.jobs.last else { next(); return }
            self.wait(until: { job.snapshot.done > 200 << 20 || job.isFinished }) {
                job.cancel()
                self.wait(until: { job.isFinished }) {
                    self.check(job.state == .cancelled, "iş iptal edildi")
                    self.check(self.count(dst) == 0, "yarım kopya kalmadı (\(self.count(dst)) öğe)")
                    next()
                }
            }
        }
        step("aynı anda 3 iş (kuyruk 2)") { next in
            let d1 = self.b.appendingPathComponent("par1"), d2 = self.a.appendingPathComponent("par2"), d3 = self.b.appendingPathComponent("par3")
            for d in [d1, d2, d3] { try? self.fm.createDirectory(at: d, withIntermediateDirectories: true) }
            let set1 = (20..<30).map { tree.appendingPathComponent(String(format: "d%02d", $0)) }
            let set2 = (30..<40).map { tree.appendingPathComponent(String(format: "d%02d", $0)) }
            let before = FileJobs.shared.jobs.count
            let t0 = Date()
            self.watchdog.reset()
            self.wc.transfer(set1, to: d1, move: false)
            self.wc.transfer(set2, to: d2, move: false)
            self.wc.transfer([big.appendingPathComponent("b0.bin")], to: d3, move: false)
            let mine = Array(FileJobs.shared.jobs.suffix(FileJobs.shared.jobs.count - before))
            var maxRunning = 0
            self.wait(timeout: 300, until: {
                maxRunning = max(maxRunning, mine.filter(\.isWorking).count)
                return mine.allSatisfy(\.isFinished)
            }) {
                let n1 = self.fileCount(d1), n2 = self.fileCount(d2)
                self.check(mine.count == 3 && mine.allSatisfy { $0.state == .done }, "3 iş de bitti")
                self.check(n1 == n2 && n1 > 10_000, "kopyalanan dosya sayısı tutarlı (\(n1) / \(n2))")
                self.check(maxRunning <= 2, "aynı anda en çok 2 iş çalıştı (\(maxRunning))")
                self.info(String(format: "3 iş toplam %.1f sn · ana iş parçacığı: %@", Date().timeIntervalSince(t0), self.watchdog.report()))
                next()
            }
        }
        step("10k dosya taşı + geri al (aynı disk)") { next in
            let dst = self.a.appendingPathComponent("moved")
            try? self.fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let set = (40..<50).map { tree.appendingPathComponent(String(format: "d%02d", $0)) }
            let t0 = Date()
            self.wc.transfer(set, to: dst, move: true)
            self.wait(until: { !FileJobs.shared.hasActive }) {
                let t1 = Date().timeIntervalSince(t0)
                self.check(self.count(dst) == 10 && !self.exists(set[0]), String(format: "taşındı (%.2f sn)", t1))
                let t2 = Date()
                self.wc.undo.undo()
                self.wait(until: { self.exists(set[9]) && !FileJobs.shared.hasActive }) {
                    self.check(set.allSatisfy(self.exists) && self.count(dst) == 0,
                               String(format: "geri alındı (%.2f sn)", Date().timeIntervalSince(t2)))
                    next()
                }
            }
        }
        step("1000 dosya taşı + geri al (diskler arası)") { next in
            let src = tree.appendingPathComponent("d50")
            let n = self.fileCount(src)
            let t0 = Date()
            self.wc.transfer([src], to: self.b, move: true)
            self.wait(until: { !FileJobs.shared.hasActive }) {
                let moved = self.b.appendingPathComponent("d50")
                self.check(!self.exists(src) && self.fileCount(moved) == n,
                           String(format: "diskler arası taşındı, %d öğe (%.2f sn)", n, Date().timeIntervalSince(t0)))
                self.wc.undo.undo()
                self.wait(until: { self.exists(src) && !FileJobs.shared.hasActive }) {
                    self.check(self.fileCount(src) == n && !self.exists(moved), "geri alındı, kaynak tam")
                    next()
                }
            }
        }
        step("40 adım geri al / yinele zinciri") { next in
            let dst = self.a.appendingPathComponent("undo")
            try? self.fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let files = ((try? self.fm.contentsOfDirectory(at: huge, includingPropertiesForKeys: nil)) ?? []).prefix(40)
            var i = 0
            let t0 = Date()
            func copyNext() {
                guard i < files.count else { undoAll(); return }
                let f = files[files.startIndex + i]
                i += 1
                self.wc.transfer([f], to: dst, move: false)
                self.wait(until: { !FileJobs.shared.hasActive }, then: copyNext)
            }
            func undoAll() {
                self.check(self.count(dst) == files.count, "40 kopya")
                var k = 0
                func one() {
                    guard k < files.count, self.wc.undo.canUndo else { redoAll(k); return }
                    k += 1
                    self.wc.undo.undo()
                    self.wait(until: { !FileJobs.shared.hasActive }, then: one)
                }
                one()
            }
            func redoAll(_ undone: Int) {
                self.check(self.count(dst) == 0, "40 geri al → klasör boş (\(undone) adım)")
                var k = 0
                func one() {
                    guard k < files.count, self.wc.undo.canRedo else {
                        self.check(self.count(dst) == files.count, "40 yinele → \(self.count(dst)) dosya")
                        self.info(String(format: "zincir toplam %.1f sn", Date().timeIntervalSince(t0)))
                        next()
                        return
                    }
                    k += 1
                    self.wc.undo.redo()
                    self.wait(until: { !FileJobs.shared.hasActive }, then: one)
                }
                one()
            }
            copyNext()
        }
        step("hata yolları (düzeltmeler)") { next in
            let fa = self.a.appendingPathComponent("fix"), fb = self.b.appendingPathComponent("fix")
            try? self.fm.removeItem(at: fa); try? self.fm.removeItem(at: fb)
            try? self.fm.createDirectory(at: fa, withIntermediateDirectories: true)
            try? self.fm.createDirectory(at: fb, withIntermediateDirectories: true)
            func write(_ u: URL, _ s: String) { try? s.write(to: u, atomically: false, encoding: .utf8) }
            func leftovers(_ d: URL) -> [String] {
                ((try? self.fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix(".oc-part") }
            }
            let jobs = FileJobs.shared
            var queue: [(@escaping () -> Void) -> Void] = []

            // 1. Cross-volume move of a folder holding an unreadable file must fail and keep the source.
            queue.append { done in
                let src = fa.appendingPathComponent("korumalı")
                try? self.fm.createDirectory(at: src, withIntermediateDirectories: true)
                write(src.appendingPathComponent("açık.txt"), "a")
                let locked = src.appendingPathComponent("kilitli.txt")
                write(locked, "gizli")
                chmod(locked.path, 0)
                jobs.transfer([src], to: fb, move: true) { job in
                    chmod(locked.path, 0o644)
                    self.check(FileJobs.isFailure(job.state), "okunamayan dosyalı taşıma hata veriyor (\(job.state))")
                    self.check(self.exists(locked) && self.exists(src.appendingPathComponent("açık.txt")), "taşıma başarısız olunca kaynak yerinde")
                    self.check(!self.exists(fb.appendingPathComponent("korumalı")) && leftovers(fb).isEmpty, "hedefte yarım kopya kalmadı")
                    done()
                }
            }
            // 2. Replace, cancelled mid-copy: the existing item stays untouched.
            queue.append { done in
                let old = fb.appendingPathComponent("b0.bin")
                write(old, "eski")
                jobs.testConflictChoice = .replace
                jobs.transfer([big.appendingPathComponent("b0.bin")], to: fb, move: false) { job in
                    jobs.testConflictChoice = nil
                    self.check(job.state == .cancelled, "değiştir + iptal: iş iptal edildi")
                    self.check((try? String(contentsOf: old, encoding: .utf8)) == "eski", "değiştir iptal edilince eski dosya yerinde")
                    self.check(leftovers(fb).isEmpty, "iptal sonrası geçici kopya silindi")
                    done()
                }
                let job = jobs.jobs.last!
                self.wait(until: { job.snapshot.done > 50 << 20 || job.isFinished }) { job.cancel() }
            }
            // 3. Replace onto itself through a symlinked folder must not trash the source.
            queue.append { done in
                let f = fa.appendingPathComponent("kendisi.txt")
                write(f, "kaynak")
                let link = fa.appendingPathComponent("bağ")
                try? self.fm.createSymbolicLink(at: link, withDestinationURL: fa)
                jobs.testConflictChoice = .replace
                jobs.transfer([link.appendingPathComponent("kendisi.txt")], to: fa, move: false) { job in
                    jobs.testConflictChoice = nil
                    self.check((try? String(contentsOf: f, encoding: .utf8)) == "kaynak", "bağ üzerinden kendi üstüne değiştir: kaynak duruyor")
                    self.check(job.results.first.map { $0.lastPathComponent != "kendisi.txt" } ?? false, "kopya yeni ada gitti (\(job.results.first?.lastPathComponent ?? "-"))")
                    done()
                }
            }
            // 4. Two jobs copying the same name into one folder at once: two separate copies.
            queue.append { done in
                let src = fa.appendingPathComponent("ikiz.txt")
                write(src, String(repeating: "x", count: 1 << 20))
                let dst = fb.appendingPathComponent("ikizler")
                try? self.fm.createDirectory(at: dst, withIntermediateDirectories: true)
                jobs.testConflictChoice = .keepBoth
                var finished = 0
                for _ in 0..<2 {
                    jobs.transfer([src], to: dst, move: false) { _ in
                        finished += 1
                        guard finished == 2 else { return }
                        jobs.testConflictChoice = nil
                        let names = ((try? self.fm.contentsOfDirectory(atPath: dst.path)) ?? []).sorted()
                        let sizes = names.compactMap { (try? self.fm.attributesOfItem(atPath: dst.appendingPathComponent($0).path))?[.size] as? Int }
                        self.check(names.count == 2 && sizes.allSatisfy { $0 == 1 << 20 }, "aynı anda iki kopya: iki tam dosya \(names)")
                        done()
                    }
                }
            }
            // 5. Name with a trailing number keeps it.
            queue.append { done in
                let r = fa.appendingPathComponent("Rapor 2024.pdf")
                write(r, "r")
                let u = FileOps.uniqueURL(for: "Rapor 2024.pdf", in: fa).lastPathComponent
                self.check(u == "Rapor 2024 2.pdf", "sondaki sayı korunuyor (\(u))")
                done()
            }
            // 6. Undo of a case-only rename restores the exact old name.
            queue.append { done in
                let f = fa.appendingPathComponent("harf.txt")
                write(f, "h")
                guard let dest = try? FileOps.rename(f, to: "HARF.txt") else { self.check(false, "büyük harf ad değişikliği"); done(); return }
                self.wc.recordUndo([.moved(from: f, to: dest)], name: "test")
                self.wc.undo.undo()
                self.wait(until: { !jobs.hasActive }) {
                    let names = (try? self.fm.contentsOfDirectory(atPath: fa.path)) ?? []
                    self.check(names.contains("harf.txt") && !names.contains { $0.hasPrefix("harf 2") }, "büyük/küçük harf geri alma eski adı veriyor")
                    done()
                }
            }
            // 7. Archive whose extraction prints a warning per entry must not hang.
            queue.append { done in
                let zip = fa.appendingPathComponent("uyarılı.zip")
                let py = "import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\ni=zipfile.ZipInfo('ln');i.external_attr=0o120777<<16\nz.writestr(i,'/tmp')\n[z.writestr('ln/f%d'%n,'x') for n in range(3000)]\nz.close()"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = ["-I", "-c", py, zip.path]
                try? p.run(); p.waitUntilExit()
                let t0 = Date()
                Archives.browse(zip) { r in
                    let secs = Date().timeIntervalSince(t0)
                    if case .failure = r {} else { self.check(false, "uyarılı arşiv açılmamalıydı") }
                    self.check(secs < 20, String(format: "çok uyarılı arşiv takılmadı (%.1f sn)", secs))
                    done()
                }
            }
            // 8. Preview text read refuses symlinks and FIFOs.
            queue.append { done in
                let zero = fa.appendingPathComponent("sıfır.txt"), fifo = fa.appendingPathComponent("boru.txt")
                try? self.fm.createSymbolicLink(atPath: zero.path, withDestinationPath: "/dev/zero")
                mkfifo(fifo.path, 0o644)
                let t0 = Date()
                let a = InfoBuilder.readRegularFile(zero, limit: 5_000_000), b = InfoBuilder.readRegularFile(fifo, limit: 5_000_000)
                self.check(a == nil && b == nil && Date().timeIntervalSince(t0) < 1, "önizleme /dev/zero bağını ve FIFO'yu okumuyor")
                done()
            }
            // 9. Compressing names that start with "-".
            queue.append { done in
                let d1 = fa.appendingPathComponent("-tire.txt"), d2 = fa.appendingPathComponent("düz.txt")
                write(d1, "1"); write(d2, "2")
                FileOps.compress([d1, d2], in: fa) { urls, err in
                    self.check(err == nil && urls.count == 1, "'-' ile başlayan adlar sıkıştırılıyor \(err.map { "\($0)" } ?? "")")
                    done()
                }
            }
            func run() {
                guard !queue.isEmpty else { next(); return }
                let f = queue.removeFirst()
                f { DispatchQueue.main.async(execute: run) }
            }
            run()
        }
        step("20k girişli arşiv") { next in
            let t0 = Date()
            Archives.browse(zip) { r in
                guard case .success(let dir) = r else { self.check(false, "arşiv açılamadı: \(r)"); next(); return }
                let secs = Date().timeIntervalSince(t0)
                let n = self.fileCount(dir)
                self.check(n >= 20_000, String(format: "arşiv açıldı: %d öğe, %.1f sn", n, secs))
                let t = self.timed { self.pane.open(folder: dir) }
                let t2 = Date()
                Archives.browse(zip) { _ in
                    self.info("arşiv kolonu: \(self.ms(t)) · ikinci açılış (önbellek): \(self.ms(Date().timeIntervalSince(t2) * 1000))")
                    next()
                }
            }
        }
        step("komut paleti (50k klasörde)") { next in
            self.pane.open(folder: huge)
            self.whenLoaded { _ in
                let open = self.timed { self.wc.showCommandPalette(nil) }
                var times: [Double] = []
                for s in ["d", "do", "dos", "dosy", "dosya", "dosya 1", "dosya 12", "yeni kl", "~/Doc", "/Applications/"] {
                    times.append(self.timed { self.wc.debugPaletteText(s) })
                }
                self.info("palet açılış \(self.ms(open)) · tuş başı \(self.stats(times))")
                self.wc.showCommandPalette(nil)
                next()
            }
        }
        step("önbellek sınırı (1000 klasör gez)") { next in
            let dirs = ((try? self.fm.contentsOfDirectory(at: tree, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            var leaves: [URL] = []
            for d in dirs { leaves += ((try? self.fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path } }
            let before = Self.footprintMB()
            var times: [Double] = [], peak = 0
            for u in leaves {
                times.append(self.timed { self.pane.open(folder: u) })
                peak = max(peak, FileNode.cachedChildCount)
            }
            self.info(String(format: "%d klasör açıldı: %@ · önbellekte en çok %d düğüm (sınır %d) · bellek %.0f → %.0f MB",
                             leaves.count, self.stats(times), peak, FileNode.cacheBudget, before, Self.footprintMB()))
            self.check(peak <= FileNode.cacheBudget + 1000, "önbellek sınırı aşılmadı")
            self.check(!FileNode.node(for: leaves[0]).childrenLoaded, "ilk gezilen klasörün önbelleği boşaltıldı")
            self.pane.open(folder: leaves[0])
            self.check(self.lastColumn?.items.count == 100, "boşaltılan klasör yeniden açılınca 100 öğe")
            next()
        }
        step("bellek sızıntısı döngüsü") { next in
            // Each round in its own run loop pass, like real use (autorelease pools drain between events).
            var marks: [Double] = [], reloads: [Double] = []
            var round = 0
            func one() {
                self.pane.open(folder: huge)
                self.whenLoaded { _ in
                    let t = self.timed { self.pane.reloadPane() }
                    self.whenLoaded { full in reloads.append(t + full); close() }
                }
            }
            func close() {
                self.pane.open(folder: self.a)
                round += 1
                if [3, 30, 60, 90].contains(round) { marks.append(Self.footprintMB()) }
                if round < 90 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: one); return }
                self.info(String(format: "90 tur huge aç/yenile/kapat: tur 3/30/60/90 → %.0f / %.0f / %.0f / %.0f MB", marks[0], marks[1], marks[2], marks[3]))
                self.info("⌘R (50k): \(self.stats(reloads))")
                self.check(marks[3] - marks[1] < 40, "30. turdan sonra bellek artmıyor (plato)")
                next()
            }
            one()
        }
        if let o = CommandLine.arguments.firstIndex(of: "--only"), o + 1 < CommandLine.arguments.count {
            let keys = CommandLine.arguments[o + 1].split(separator: ",").map { String($0).lowercased() }
            steps = steps.filter { s in keys.contains { s.0.lowercased().contains($0) } }
        }
        var i = 0
        func advance() {
            guard i < steps.count else {
                watchdog.stop()
                print(String(format: "INFO  son bellek %.0f MB · tüm test boyunca: %@", Self.footprintMB(), watchdog.report(total: true)))
                print(failures == 0 ? "STRESS OK" : "STRESS \(failures) HATA")
                print("STRESS DONE pid=\(getpid())")
                fflush(stdout)
                if !CommandLine.arguments.contains("--hold") { NSApp.terminate(nil) }
                return
            }
            let (name, f) = steps[i]
            i += 1
            print(String(format: "--- %@  [%.0f MB]", name, Self.footprintMB()))
            fflush(stdout)
            watchdog.reset()
            f {
                print("      ana iş parçacığı: \(self.watchdog.report())")
                fflush(stdout)
                DispatchQueue.main.async(execute: advance)
            }
        }
        advance()
    }
}

/// Measures main-thread responsiveness: a background thread pings the main queue every 16 ms
/// and records how long each ping waited. Synchronous test steps show up as stalls too.
final class Watchdog {
    private let lock = NSLock()
    private var running = false
    private var lat: [Double] = []
    private var all: [Double] = []

    func start() {
        running = true
        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                let t0 = CFAbsoluteTimeGetCurrent()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let d = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    self.lock.lock(); self.lat.append(d); self.all.append(d); self.lock.unlock()
                    sem.signal()
                }
                sem.wait()
                usleep(16_000)
            }
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }
    func reset() { lock.lock(); lat.removeAll(keepingCapacity: true); lock.unlock() }

    func report(total: Bool = false) -> String {
        lock.lock(); let v = total ? all : lat; lock.unlock()
        guard !v.isEmpty else { return "-" }
        let over100 = v.filter { $0 > 100 }.count, over500 = v.filter { $0 > 500 }.count
        let stalled = v.filter { $0 > 100 }.reduce(0, +) / 1000
        return String(format: "en uzun donma %.0f ms · >100ms: %d · >500ms: %d · toplam donma %.1f sn", v.max()!, over100, over500, stalled)
    }
}

private extension NSView {
    var subviewsDeep: [NSView] { subviews + subviews.flatMap(\.subviewsDeep) }
}
