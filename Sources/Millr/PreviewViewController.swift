import AppKit
import Quartz
import ImageIO
import UniformTypeIdentifiers

/// Right column: Quick Look preview on top, detailed file information below.
final class PreviewViewController: NSViewController, NSSplitViewDelegate {
    private let header = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private var ql: QLPreviewView!
    private let multiIcon = NSImageView()
    private let infoView = NSTextView()
    private let split = NSSplitView()
    private var pending: DispatchWorkItem?
    private var sizeJob: SizeJob?
    private var didSetDivider = false

    private var current: [FileNode] = []
    private var currentFolder: FileNode?
    private var sections: [(String, [(String, String)])] = []

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        ql = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), style: .normal)
        ql.autostarts = false
        ql.shouldCloseWithWindow = false

        multiIcon.imageScaling = .scaleProportionallyUpOrDown
        multiIcon.isHidden = true
        multiIcon.translatesAutoresizingMaskIntoConstraints = false

        let top = NSView()
        ql.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(ql)
        top.addSubview(multiIcon)
        NSLayoutConstraint.activate([
            ql.topAnchor.constraint(equalTo: top.topAnchor),
            ql.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            ql.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            ql.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            multiIcon.centerXAnchor.constraint(equalTo: top.centerXAnchor),
            multiIcon.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            multiIcon.widthAnchor.constraint(equalToConstant: 128),
            multiIcon.heightAnchor.constraint(equalToConstant: 128),
        ])

        infoView.isEditable = false
        infoView.isSelectable = true
        infoView.drawsBackground = false
        infoView.textContainerInset = NSSize(width: 10, height: 8)
        infoView.isVerticallyResizable = true
        infoView.autoresizingMask = [.width]
        infoView.textContainer?.widthTracksTextView = true
        let infoScroll = NSScrollView()
        infoScroll.drawsBackground = false
        infoScroll.hasVerticalScroller = true
        infoScroll.autohidesScrollers = true
        infoScroll.documentView = infoView

        split.isVertical = false
        split.wantsLayer = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(top)
        split.addArrangedSubview(infoScroll)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        split.autosaveName = "PreviewSplit"

        v.addSubview(header)
        v.addSubview(split)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetDivider, split.bounds.height > 100 {
            didSetDivider = true
            if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames PreviewSplit") == nil {
                split.setPosition(split.bounds.height * 0.45, ofDividerAt: 0)
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 80 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 80
    }

    // MARK: - Update

    func applyTheme() {
        guard isViewLoaded else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.current.preview.cgColor
        header.textColor = Theme.current.secondary
        header.font = Fonts.rounded(11.5, .semibold)
        renderText()
    }

    func show(selection: [FileNode], folder: FileNode) {
        guard isViewLoaded else { return }
        let count = folder.children.count
        header.stringValue = "\(count) öğe  ·  \(selection.count) seçili"
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render(selection: selection, folder: folder) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func render(selection: [FileNode], folder: FileNode) {
        sizeJob?.cancel()
        sizeJob = nil
        current = selection
        currentFolder = folder

        if selection.count > 1 {
            ql.previewItem = nil
            ql.isHidden = true
            multiIcon.isHidden = false
            multiIcon.image = NSWorkspace.shared.icon(forFiles: selection.map(\.path))
            sections = InfoBuilder.multi(selection)
            let dirs = selection.filter(\.isDirectory)
            if !dirs.isEmpty { startSize(dirs.map(\.url), base: selection.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }) }
        } else if selection.isEmpty && folder.isVirtual {
            ql.previewItem = nil
            ql.isHidden = true
            multiIcon.isHidden = false
            multiIcon.image = folder.icon
            var rows: InfoBuilder.Rows = [("Ad", folder.name), ("Sonuç", "\(folder.children.count) öğe")]
            if let id = SmartFolders.id(fromPath: folder.path), let f = SmartFolders.shared.folder(id: id) {
                rows.append(("Sorgu", f.query))
                rows.append(("Nerede", f.scopes.joined(separator: ", ")))
            }
            sections = [("Akıllı Klasör", rows)]
        } else {
            let node = selection.first ?? folder
            ql.isHidden = false
            multiIcon.isHidden = true
            if (ql.previewItem as? NSURL)?.path != node.path {
                ql.previewItem = node.url as NSURL
            }
            sections = InfoBuilder.single(node)
            if node.isDirectory || node.isPackage { startSize([node.url], base: 0) }
        }
        renderText()
    }

    private func startSize(_ urls: [URL], base: Int64) {
        let job = SizeJob(urls: urls) { [weak self] size, files, dirs, done in
            guard let self else { return }
            let text = (done ? "" : "≥ ") + "\(Fmt.size(base + size))  (\(files.formatted()) dosya, \(dirs.formatted()) klasör)"
            self.setValue(text, forLabel: "Toplam boyut")
        }
        sizeJob = job
        setValue("hesaplanıyor…", forLabel: "Toplam boyut")
        job.start()
    }

    private func setValue(_ value: String, forLabel labelText: String) {
        for (si, s) in sections.enumerated() {
            if let ri = s.1.firstIndex(where: { $0.0 == labelText }) {
                sections[si].1[ri].1 = value
                renderText()
                return
            }
        }
        if !sections.isEmpty {
            sections[0].1.insert((labelText, value), at: min(4, sections[0].1.count))
            renderText()
        }
    }

    private func renderText() {
        let out = NSMutableAttributedString()
        let labelWidth: CGFloat = 104
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth)]
        para.headIndent = labelWidth
        para.paragraphSpacing = 3
        para.lineBreakMode = .byCharWrapping
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.current.secondary, .paragraphStyle: para,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.current.text, .paragraphStyle: para,
        ]
        let headPara = NSMutableParagraphStyle()
        headPara.paragraphSpacingBefore = 8
        headPara.paragraphSpacing = 4
        let headAttrs: [NSAttributedString.Key: Any] = [
            .font: Fonts.rounded(11, .bold), .foregroundColor: Theme.current.accent,
            .paragraphStyle: headPara,
        ]
        for (i, s) in sections.enumerated() where !s.1.isEmpty {
            if !s.0.isEmpty || i > 0 {
                out.append(NSAttributedString(string: s.0.uppercased(with: Locale(identifier: "tr_TR")) + "\n", attributes: headAttrs))
            }
            for (k, v) in s.1 {
                out.append(NSAttributedString(string: k + "\t", attributes: labelAttrs))
                out.append(NSAttributedString(string: v + "\n", attributes: valueAttrs))
            }
        }
        infoView.textStorage?.setAttributedString(out)
    }
}

/// Recursive folder size, computed in the background with periodic progress.
final class SizeJob {
    private let urls: [URL]
    private let update: (Int64, Int, Int, Bool) -> Void
    private var cancelled = false
    private static var cache: [String: (Int64, Int, Int, Date)] = [:]

    init(urls: [URL], update: @escaping (Int64, Int, Int, Bool) -> Void) {
        self.urls = urls
        self.update = update
    }

    func cancel() { cancelled = true }

    func start() {
        let key = urls.map(\.path).joined(separator: "|")
        if let c = Self.cache[key], Date().timeIntervalSince(c.3) < 60 {
            update(c.0, c.1, c.2, true)
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var size: Int64 = 0, files = 0, dirs = 0
            var lastReport = Date()
            let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
            outer: for root in urls {
                guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { continue }
                for case let u as URL in e {
                    if cancelled { return }
                    guard let v = try? u.resourceValues(forKeys: keys) else { continue }
                    if v.isDirectory == true && v.isSymbolicLink != true { dirs += 1 } else {
                        files += 1
                        size += Int64(v.fileSize ?? 0)
                    }
                    if files % 2000 == 0, Date().timeIntervalSince(lastReport) > 0.4 {
                        lastReport = Date()
                        let s = size, f = files, d = dirs
                        DispatchQueue.main.async { if !self.cancelled { self.update(s, f, d, false) } }
                    }
                }
            }
            let s = size, f = files, d = dirs
            DispatchQueue.main.async {
                Self.cache[key] = (s, f, d, Date())
                if !self.cancelled { self.update(s, f, d, true) }
            }
        }
    }
}

/// Collects everything we know about a file: file system, Spotlight metadata, image/PDF properties.
enum InfoBuilder {
    /// Reads at most `limit` bytes of a regular file. Symlinks (e.g. to /dev/zero), FIFOs and devices
    /// are refused: following or blocking on them would hang or exhaust memory.
    static func readRegularFile(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit else { return nil }
        return try? h.read(upToCount: limit)
    }

    typealias Rows = [(String, String)]

    static func multi(_ nodes: [FileNode]) -> [(String, Rows)] {
        let files = nodes.filter { !$0.isDirectory }
        let dirs = nodes.filter(\.isDirectory)
        var rows: Rows = [
            ("Seçili", "\(nodes.count) öğe (\(files.count) dosya, \(dirs.count) klasör)"),
            ("Dosya boyutu", Fmt.size(files.reduce(0) { $0 + $1.size })),
        ]
        let kinds = Dictionary(grouping: nodes, by: \.kind).map { "\($0.key) (\($0.value.count))" }.sorted()
        rows.append(("Türler", kinds.joined(separator: ", ")))
        let dates = nodes.compactMap(\.modified)
        if let mn = dates.min(), let mx = dates.max() {
            rows.append(("Değiştirilme", "\(Fmt.date(mn)) → \(Fmt.date(mx))"))
        }
        if let parent = nodes.first?.parentURL.path { rows.append(("Konum", parent)) }
        return [("Seçim", rows)]
    }

    static func single(_ node: FileNode) -> [(String, Rows)] {
        let url = node.url
        let fm = FileManager.default
        var general: Rows = []
        general.append(("Ad", node.name))
        general.append(("Tür", node.kind.isEmpty ? (node.isDirectory ? "Klasör" : "Dosya") : node.kind))
        let ext = url.pathExtension
        if !ext.isEmpty && !node.isDirectory { general.append(("Uzantı", ".\(ext)")) }
        general.append(("Konum", node.parentURL.path))
        if let provider = Cloud.providerName(for: node.path) {
            general.append(("Bulut", "\(provider)  ·  \(Cloud.title(node.cloud))"))
        }
        if let c = Archives.container(of: node.path) {
            general.append(("Arşiv", c.archive.path))
        }
        if node.isDirectory {
            general.append(("İçerik", "\(node.children.count) öğe"))
            general.append(("Toplam boyut", "hesaplanıyor…"))
        } else if node.isPackage {
            general.append(("Toplam boyut", "hesaplanıyor…"))
        } else {
            general.append(("Boyut", "\(Fmt.size(node.size))  (\(node.size.formatted()) bayt)"))
        }

        var dates: Rows = []
        dates.append(("Oluşturulma", Fmt.longDate(node.created)))
        dates.append(("Değiştirilme", Fmt.longDate(node.modified)))
        dates.append(("Yaş", "\(Fmt.age(node.modified))  ·  \(Fmt.relative(node.modified))"))

        let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL)
        func attr(_ key: String) -> Any? {
            guard let md else { return nil }
            return MDItemCopyAttribute(md, key as CFString)
        }
        if let d = attr("kMDItemLastUsedDate") as? Date { dates.append(("Son açılma", Fmt.longDate(d))) }
        if let d = attr("kMDItemDateAdded") as? Date { dates.append(("Eklenme", Fmt.longDate(d))) }
        if let n = attr("kMDItemUseCount") as? NSNumber { dates.append(("Açılma sayısı", n.stringValue)) }

        var media: Rows = []
        var doc: Rows = []
        var app: Rows = []
        var source: Rows = []

        func str(_ v: Any?) -> String? {
            switch v {
            case let s as String: return s.isEmpty ? nil : s
            case let a as [String]: return a.isEmpty ? nil : a.joined(separator: ", ")
            case let n as NSNumber: return n.stringValue
            case let d as Date: return Fmt.longDate(d)
            default: return nil
            }
        }
        func addMD(_ rows: inout Rows, _ labelText: String, _ key: String, _ transform: ((Any) -> String?)? = nil) {
            guard let v = attr(key) else { return }
            if let s = transform.map({ $0(v) }) ?? str(v) { rows.append((labelText, s)) }
        }

        // Media
        if let w = attr("kMDItemPixelWidth") as? NSNumber, let h = attr("kMDItemPixelHeight") as? NSNumber {
            let mp = w.doubleValue * h.doubleValue / 1_000_000
            media.append(("Çözünürlük", "\(w) × \(h)" + (mp >= 0.5 ? String(format: "  (%.1f MP)", mp) : "")))
        }
        addMD(&media, "Süre", "kMDItemDurationSeconds") { ($0 as? NSNumber).map { Fmt.duration($0.doubleValue) } }
        addMD(&media, "Codec", "kMDItemCodecs")
        addMD(&media, "Bit hızı", "kMDItemTotalBitRate") { ($0 as? NSNumber).map { "\(Int($0.doubleValue / 1000)) kbps" } }
        addMD(&media, "Video bit hızı", "kMDItemVideoBitRate") { ($0 as? NSNumber).map { "\(Int($0.doubleValue / 1000)) kbps" } }
        addMD(&media, "Ses örnekleme", "kMDItemAudioSampleRate") { ($0 as? NSNumber).map { "\($0.intValue) Hz" } }
        addMD(&media, "Ses kanalı", "kMDItemAudioChannelCount")
        addMD(&media, "Renk uzayı", "kMDItemColorSpace")
        addMD(&media, "Renk profili", "kMDItemProfileName")
        addMD(&media, "Bit derinliği", "kMDItemBitsPerSample")
        addMD(&media, "DPI", "kMDItemResolutionWidthDPI") { ($0 as? NSNumber).map { "\($0.intValue)" } }
        addMD(&media, "Kamera", "kMDItemAcquisitionModel")
        addMD(&media, "Üretici", "kMDItemAcquisitionMake")
        addMD(&media, "Lens", "kMDItemLensModel")
        addMD(&media, "Diyafram", "kMDItemFNumber") { ($0 as? NSNumber).map { "f/\($0)" } }
        addMD(&media, "Pozlama", "kMDItemExposureTimeSeconds") {
            guard let n = $0 as? NSNumber else { return nil }
            return n.doubleValue < 1 && n.doubleValue > 0 ? "1/\(Int((1 / n.doubleValue).rounded())) sn" : "\(n) sn"
        }
        addMD(&media, "ISO", "kMDItemISOSpeed")
        addMD(&media, "Odak uzaklığı", "kMDItemFocalLength") { ($0 as? NSNumber).map { "\($0) mm" } }
        if let lat = attr("kMDItemLatitude") as? NSNumber, let lon = attr("kMDItemLongitude") as? NSNumber {
            media.append(("Konum (GPS)", String(format: "%.5f, %.5f", lat.doubleValue, lon.doubleValue)))
        }
        addMD(&media, "Albüm", "kMDItemAlbum")
        addMD(&media, "Sanatçı", "kMDItemAuthors")
        addMD(&media, "Besteci", "kMDItemComposer")
        addMD(&media, "Tür (müzik)", "kMDItemMusicalGenre")
        addMD(&media, "Yıl", "kMDItemRecordingYear")

        // Image fallback (non-indexed volumes)
        if media.isEmpty, !node.isDirectory, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(src) > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                media.append(("Çözünürlük", "\(w) × \(h)"))
            }
            if let m = props[kCGImagePropertyColorModel] as? String { media.append(("Renk modeli", m)) }
            if let d = props[kCGImagePropertyDepth] as? Int { media.append(("Bit derinliği", "\(d)")) }
            if let dpi = props[kCGImagePropertyDPIWidth] as? Double { media.append(("DPI", "\(Int(dpi))")) }
            if let p = props[kCGImagePropertyProfileName] as? String { media.append(("Renk profili", p)) }
        }

        // Documents
        addMD(&doc, "Başlık", "kMDItemTitle")
        if media.first(where: { $0.0 == "Sanatçı" }) == nil { addMD(&doc, "Yazar", "kMDItemAuthors") }
        addMD(&doc, "Sayfa", "kMDItemNumberOfPages")
        if let w = attr("kMDItemPageWidth") as? NSNumber, let h = attr("kMDItemPageHeight") as? NSNumber {
            doc.append(("Sayfa boyutu", String(format: "%.0f × %.0f mm", w.doubleValue / 72 * 25.4, h.doubleValue / 72 * 25.4)))
        }
        addMD(&doc, "Oluşturan", "kMDItemCreator")
        addMD(&doc, "Kodlayan", "kMDItemEncodingApplications")
        addMD(&doc, "Konu", "kMDItemSubject")
        addMD(&doc, "Açıklama", "kMDItemDescription")
        addMD(&doc, "Anahtar kelime", "kMDItemKeywords")
        addMD(&doc, "Dil", "kMDItemLanguages")
        addMD(&doc, "Telif", "kMDItemCopyright")
        addMD(&doc, "Kelime sayısı", "kMDItemNumberOfWords")
        if ext.lowercased() == "pdf", doc.first(where: { $0.0 == "Sayfa" }) == nil, let pdf = PDFDocument(url: url) {
            doc.append(("Sayfa", "\(pdf.pageCount)"))
            if let a = pdf.documentAttributes {
                if let t = a[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty { doc.append(("Başlık", t)) }
                if let t = a[PDFDocumentAttribute.authorAttribute] as? String, !t.isEmpty { doc.append(("Yazar", t)) }
                if let t = a[PDFDocumentAttribute.creatorAttribute] as? String, !t.isEmpty { doc.append(("Oluşturan", t)) }
            }
        }
        if !node.isDirectory && !node.isPackage && !node.isSymlink && node.size < 5_000_000,
           let type = UTType(filenameExtension: ext), type.conforms(to: .text),
           let data = Self.readRegularFile(url, limit: 5_000_000), let s = String(data: data, encoding: .utf8) {
            var lines = 0
            s.enumerateLines { _, _ in lines += 1 }
            doc.append(("Satır", lines.formatted()))
            doc.append(("Karakter", s.count.formatted()))
            doc.append(("Kodlama", "UTF-8"))
        }

        // Applications / bundles
        addMD(&app, "Bundle ID", "kMDItemCFBundleIdentifier")
        addMD(&app, "Sürüm", "kMDItemVersion")
        addMD(&app, "Mimari", "kMDItemExecutableArchitectures")
        if node.isPackage, let b = Bundle(url: url) {
            if app.first(where: { $0.0 == "Bundle ID" }) == nil, let id = b.bundleIdentifier { app.append(("Bundle ID", id)) }
            if let v = b.infoDictionary?["CFBundleShortVersionString"] as? String, app.first(where: { $0.0 == "Sürüm" }) == nil {
                app.append(("Sürüm", v))
            }
            if let m = b.infoDictionary?["LSMinimumSystemVersion"] as? String { app.append(("Min. macOS", m)) }
        }

        // Source
        addMD(&source, "İndirildiği yer", "kMDItemWhereFroms") { v in
            (v as? [String]).map { $0.filter { !$0.isEmpty }.joined(separator: "\n") }
        }
        addMD(&source, "İçerik türü", "kMDItemContentType")
        if let v = try? url.resourceValues(forKeys: [.tagNamesKey]), let tags = v.tagNames, !tags.isEmpty {
            source.append(("Etiketler", tags.joined(separator: ", ")))
        }
        addMD(&source, "Finder yorumu", "kMDItemFinderComment")

        // System
        var system: Rows = []
        if let a = try? fm.attributesOfItem(atPath: url.path) {
            if let p = a[.posixPermissions] as? NSNumber {
                system.append(("İzinler", Fmt.permissions(p.intValue, isDir: node.isDirectory)))
            }
            let owner = a[.ownerAccountName] as? String ?? "?"
            let group = a[.groupOwnerAccountName] as? String ?? "?"
            system.append(("Sahip", "\(owner) : \(group)"))
            if (a[.immutable] as? NSNumber)?.boolValue == true { system.append(("Kilitli", "Evet")) }
        }
        if node.isSymlink, let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            system.append(("Bağlantı hedefi", dest))
        }
        if node.isHiddenFile { system.append(("Gizli", "Evet")) }
        system.append(("Yol", url.path))
        let vkeys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                          .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey, .volumeURLKey]
        if let v = try? url.resourceValues(forKeys: vkeys) {
            var volRows: Rows = []
            if let n = v.volumeLocalizedName { volRows.append(("Disk", n)) }
            if let t = v.volumeTotalCapacity, let f = v.volumeAvailableCapacityForImportantUsage {
                let used = Double(Int64(t) - f) / Double(max(1, t)) * 100
                volRows.append(("Boş alan", "\(Fmt.size(f)) / \(Fmt.size(Int64(t)))  (%\(Int(used)) dolu)"))
            }
            if let fs = v.volumeLocalizedFormatDescription { volRows.append(("Dosya sistemi", fs)) }
            system += volRows
        }

        return [
            ("", general), ("Tarihler", dates), ("Medya", media), ("Belge", doc),
            ("Uygulama", app), ("Kaynak", source), ("Sistem", system),
        ]
    }
}
