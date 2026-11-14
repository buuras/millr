import AppKit
import Quartz

/// Owns the window, the two panes, sidebar and preview; performs all file commands.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let sidebar = SidebarViewController()
    let panes = [PaneViewController(), PaneViewController()]
    private let mainSplit = NSSplitViewController()
    private let paneSplit = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var bottomItem: NSSplitViewItem!

    private(set) var activeIndex = 0
    var activePane: PaneViewController { panes[activeIndex] }
    var otherPane: PaneViewController { panes[1 - activeIndex] }

    private let rootVC = NSViewController()
    let jobsView = JobsView()
    /// File-operation undo stack (⌘Z / ⇧⌘Z through the window).
    let undo: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        u.levelsOfUndo = 50
        return u
    }()

    private lazy var palette = CommandPalette(controller: self)
    private var monitors: [Any] = []
    private var cutURLs: [URL] = []
    private var cutChangeCount = -1

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Millr"
        w.minSize = NSSize(width: 900, height: 520)
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self
        setupSplits()
        // Root view: the split layout plus a floating progress overlay (bottom-right).
        let root = NSView()
        rootVC.view = root
        rootVC.addChild(mainSplit)
        mainSplit.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainSplit.view)
        root.addSubview(jobsView)
        NSLayoutConstraint.activate([
            mainSplit.view.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplit.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            mainSplit.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            jobsView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            jobsView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -30),
        ])
        w.contentViewController = rootVC
        let tb = NSToolbar(identifier: "OCMainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unifiedCompact
        w.titleVisibility = .hidden
        if !w.setFrameUsingName("MainWindow") {
            w.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
            w.center()
        }
        w.setFrameAutosaveName("MainWindow")
        installMonitors()
        FileWatcher.shared.onChange = { [weak self] paths in self?.handleFSChanges(paths) }
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(forName: .virtualFolderUpdated, object: nil, queue: .main) { [weak self] n in
            if let p = n.userInfo?["path"] as? String { self?.refresh(paths: [p]) }
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func setupSplits() {
        mainSplit.splitView = ThemedSplitView()
        paneSplit.splitView = ThemedSplitView()
        mainSplit.splitView.isVertical = true
        mainSplit.splitView.dividerStyle = .thin
        for (i, p) in panes.enumerated() {
            p.coordinator = self
            p.index = i
        }
        paneSplit.splitView.isVertical = !Prefs.shared.overUnder
        paneSplit.splitView.dividerStyle = .thick
        let top = NSSplitViewItem(viewController: panes[0])
        top.minimumThickness = 150
        bottomItem = NSSplitViewItem(viewController: panes[1])
        bottomItem.minimumThickness = 150
        bottomItem.canCollapse = true
        paneSplit.addSplitViewItem(top)
        paneSplit.addSplitViewItem(bottomItem)
        bottomItem.isCollapsed = !Prefs.shared.dualPane

        sidebar.onOpen = { [weak self] u in self?.activePane.open(folder: u) }
        sidebar.onReveal = { [weak self] u in self?.activePane.reveal(u) }
        sidebar.currentFolder = { [weak self] in self?.activePane.currentFolder }
        sidebar.onOpenInOtherPane = { [weak self] u in self?.openInOtherPane(u) }
        sidebar.onOpenInNewTab = { [weak self] u in self?.activePane.newTab(at: u) }
        sidebar.onNewSmartFolder = { [weak self] in self?.newSmartFolder(nil) }
        sidebar.loadViewIfNeeded()
        sidebar.shelf.onReveal = { [weak self] u in self?.activePane.reveal(u) }
        sidebar.shelf.onTransfer = { [weak self] urls, move in
            guard let self else { return }
            self.transfer(urls, to: self.activePane.currentFolder, move: move) { _ in Shelf.shared.prune() }
        }

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        let center = NSSplitViewItem(viewController: paneSplit)
        center.minimumThickness = 400
        sidebarItem.holdingPriority = .defaultLow + 20
        mainSplit.addSplitViewItem(sidebarItem)
        mainSplit.addSplitViewItem(center)
        mainSplit.splitView.autosaveName = "OCMainSplit"
        paneSplit.splitView.autosaveName = "OCPaneSplit"
    }

    /// Called once the window is on screen.
    func didShow() {
        let states = loadStates()
        let home = FileManager.default.homeDirectoryForCurrentUser
        panes[0].restore(states.first, defaultFolder: home)
        panes[1].restore(states.count > 1 ? states[1] : nil, defaultFolder: home.appendingPathComponent("Downloads"))
        let firstLaunch = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames OCMainSplit") == nil
        if firstLaunch { mainSplit.splitView.setPosition(220, ofDividerAt: 0) }
        window?.layoutIfNeeded()
        panes.forEach { $0.applyInitialSplit() }
        setActive(0)
    }

    // MARK: - State

    private func loadStates() -> [PaneState] {
        guard let data = UserDefaults.standard.data(forKey: "paneStates"),
              let s = try? JSONDecoder().decode([PaneState].self, from: data) else { return [] }
        return s
    }

    func saveState() {
        if let data = try? JSONEncoder().encode(panes.map { $0.state() }) {
            UserDefaults.standard.set(data, forKey: "paneStates")
        }
    }

    // MARK: - Panes

    func setActive(_ i: Int) {
        activeIndex = i
        for (j, p) in panes.enumerated() { p.isActive = j == i }
        paneSelectionChanged(activePane)
    }

    func paneSelectionChanged(_ pane: PaneViewController) {
        guard pane === activePane else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    @objc func switchPane(_ sender: Any?) {
        if bottomItem.isCollapsed { return }
        setActive(1 - activeIndex)
        activePane.focus()
    }

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            for (i, p) in self.panes.enumerated() where p.isViewLoaded && i != self.activeIndex {
                let pt = p.view.convert(e.locationInWindow, from: nil)
                if p.view.bounds.contains(pt) && !p.view.isHiddenOrHasHiddenAncestor { self.setActive(i) }
            }
            return e
        } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if self.window?.firstResponder is NSText { return e }
            if self.activePane.columnsView.handleFilterKey(e) { return nil }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
            switch e.keyCode {
            case 48 where mods.isEmpty || mods == .shift: self.switchPane(nil); return nil       // Tab
            case 49 where mods.isEmpty: self.toggleQuickLook(nil); return nil                      // Space
            case 36 where mods.isEmpty, 76 where mods.isEmpty: self.openSelection(nil); return nil // Return
            case 120 where mods.isEmpty: self.renameSelection(nil); return nil                     // F2
            case 96 where mods.isEmpty: self.copyToOtherPane(nil); return nil                      // F5
            case 97 where mods.isEmpty: self.moveToOtherPane(nil); return nil                      // F6
            case 98 where mods.isEmpty: self.newFolder(nil); return nil                            // F7
            case 100 where mods.isEmpty: self.moveToTrash(nil); return nil                         // F8
            case 51 where mods.isEmpty && self.activePane.selectedNodes.isEmpty: self.activePane.goUp(); return nil
            default: return e
            }
        } as Any)
    }

    // MARK: - File system changes

    /// Big folders that changed on disk, reloaded together at most once per `bigFolderDelay`
    /// (re-reading 50k items takes ~0.5 s; a busy Downloads folder would otherwise stutter).
    private var pendingBig = Set<String>()
    private static let bigFolder = 5000, bigFolderDelay: TimeInterval = 1.5

    private func handleFSChanges(_ paths: [String]) {
        var changed = Set<String>()
        var big = Set<String>()
        for p in paths {
            // A folder still listing must be invalidated too, or its listing misses this change.
            guard let n = FileNode.existing(path: p), n.childrenLoaded || n.isLoading else { continue }
            if n.children.count >= Self.bigFolder { big.insert(p) } else { changed.insert(p) }
        }
        FolderSizer.shared.invalidate(Set(paths))
        refresh(paths: changed)
        guard !big.isEmpty else { return }
        let idle = pendingBig.isEmpty
        pendingBig.formUnion(big)
        if idle {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bigFolderDelay) { [weak self] in
                guard let self else { return }
                let p = self.pendingBig
                self.pendingBig = []
                self.refresh(paths: p)
            }
        }
    }

    func refresh(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for p in paths { FileNode.existing(path: p)?.invalidate() }
        FolderSizer.shared.invalidate(paths)
        for pane in panes { pane.refreshIfShowing(paths) }
    }

    func refresh(dirs: [URL]) {
        refresh(paths: Set(dirs.map { $0.standardizedFileURL.path }))
    }

    @objc private func themeChanged() { applyTheme() }

    func applyTheme() {
        let t = Theme.current
        window?.appearance = t.appearance
        window?.backgroundColor = t.chrome
        window?.titlebarAppearsTransparent = true
        mainSplit.splitView.needsDisplay = true
        paneSplit.splitView.needsDisplay = true
        panes.forEach { $0.applyTheme() }
        if sidebar.isViewLoaded { sidebar.reload() }
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard Theme.all.indices.contains(sender.tag) else { return }
        Prefs.shared.themeID = Theme.all[sender.tag].id
    }

    @objc private func prefsChanged() {
        FileNode.invalidateAll()
        for p in panes where p.isViewLoaded { p.reloadKeepingSelection() }
    }

    // MARK: - Commands (shared by menus, context menu, keys)

    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    /// Opens a folder (real or virtual) in the active or the other pane.
    func go(to url: URL, otherPane alt: Bool) {
        if alt { openInOtherPane(url) } else { activePane.open(folder: url) }
    }

    func browseArchive(_ url: URL, in pane: PaneViewController) {
        Archives.browse(url) { [weak self, weak pane] r in
            switch r {
            case .success(let dir): pane?.open(folder: dir)
            case .failure(let e): if (e as? CocoaError)?.code != .userCancelled { self?.showError(e) }
            }
        }
    }

    func openItems(_ urls: [URL], in pane: PaneViewController) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            let n = FileNode.node(for: urls[0])
            if n.isDirectory { pane.open(folder: n.url); return }
            if Archives.canBrowse(n.url) { browseArchive(n.url, in: pane); return }
        }
        for u in urls where !FileNode.node(for: u).isDirectory { NSWorkspace.shared.open(u) }
    }

    func transfer(_ urls: [URL], to dir: URL, move: Bool, then: (([URL]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        if FileOps.isInvalidTarget(dir, for: urls) { NSSound.beep(); return }
        if VirtualFolders.isVirtual(dir) { NSSound.beep(); return }
        let sources = Set(urls.map { $0.deletingLastPathComponent() })
        FileJobs.shared.transfer(urls, to: dir, move: move) { [weak self] job in
            guard let self else { return }
            self.refresh(dirs: Array(sources) + [dir])
            if move { Shelf.shared.prune() }
            self.recordUndo(job.ops, name: move ? "Taşıma" : "Kopyalama")
            then?(job.results)
        }
    }

    // MARK: - Undo

    /// Registers `ops` as one undo step. Undo reverts them (created items go to the Trash,
    /// moved items go back); the reverting registers the inverse, which becomes redo.
    func recordUndo(_ ops: [UndoOp], name: String) {
        guard !ops.isEmpty else { return }
        register(name: name) { $0.revert(ops, name: name) }
    }

    private func register(name: String, _ action: @escaping (MainWindowController) -> Void) {
        let open = !undo.isUndoing && !undo.isRedoing
        if open { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self, handler: action)
        undo.setActionName(name)
        if open { undo.endUndoGrouping() }
    }

    /// Filled when a revert job finishes: what really moved (names may differ, items may fail).
    private final class OpsBox { var ops: [UndoOp] = [] }

    private func revert(_ ops: [UndoOp], name: String) {
        let done = OpsBox()
        var dirs = Set<URL>()
        // Created items first (they may occupy a place a replaced item returns to).
        for case .created(let u) in ops.reversed() {
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &trashed)
                if let t = trashed as URL? { done.ops.append(.moved(from: u, to: t)) }
                dirs.insert(u.deletingLastPathComponent())
            } catch {
                showError(error)
            }
        }
        var pairs: [(from: URL, to: URL)] = []
        for case .moved(let from, let to) in ops.reversed() {
            pairs.append((from: to, to: from))
            dirs.insert(from.deletingLastPathComponent())
            dirs.insert(to.deletingLastPathComponent())
        }
        // The inverse (redo) must be registered now, inside the undo; it reads the box, which the
        // job fills with the moves that actually happened.
        register(name: name) { $0.revert(done.ops, name: name) }
        refresh(dirs: Array(dirs))
        guard !pairs.isEmpty else { return }
        FileJobs.shared.movePairs(pairs, title: "Geri alınıyor: \(name)") { [weak self] job in
            done.ops += job.ops
            self?.refresh(dirs: Array(dirs))
            Shelf.shared.prune()
            if case .failed(let m) = job.state { self?.showError(NSError(domain: "OCJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: m])) }
            if let first = job.results.first { self?.activePane.reveal(first) }
        }
    }

    func openInOtherPane(_ url: URL) {
        if bottomItem.isCollapsed { toggleDualPane(nil) }
        otherPane.open(folder: url)
    }

    func rename(_ node: FileNode, in pane: PaneViewController) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Yeniden adlandır"
        alert.informativeText = node.name
        let field = NSTextField(string: node.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Adlandır")
        alert.addButton(withTitle: "Vazgeç")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != node.name, !newName.contains("/") else { return }
            do {
                let dest = try FileOps.rename(node.url, to: newName)
                self.recordUndo([.moved(from: node.url, to: dest)], name: "Yeniden Adlandırma")
                self.refresh(dirs: [node.parentURL])
                pane.reveal(dest)
            } catch { self.showError(error) }
        }
        DispatchQueue.main.async {
            let base = (node.name as NSString).deletingPathExtension
            let len = node.isDirectory || base.isEmpty ? (node.name as NSString).length : (base as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: len)
        }
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let dirs = Set(urls.map { $0.deletingLastPathComponent() })
        NSWorkspace.shared.recycle(urls) { [weak self] map, err in
            DispatchQueue.main.async {
                if let err { self?.showError(err) }
                self?.recordUndo(map.map { .moved(from: $0.key, to: $0.value) }, name: "Çöp Sepetine Taşıma")
                self?.refresh(dirs: Array(dirs))
                Shelf.shared.prune()
            }
        }
    }

    func createFolder(in dir: URL, pane: PaneViewController) {
        do {
            if VirtualFolders.isVirtual(dir) { NSSound.beep(); return }
            let u = try FileOps.newFolder(in: dir)
            recordUndo([.created(u)], name: "Yeni Klasör")
            refresh(dirs: [dir])
            pane.reveal(u)
            rename(FileNode.node(for: u), in: pane)
        } catch { showError(error) }
    }

    func createFile(in dir: URL, pane: PaneViewController) {
        do {
            if VirtualFolders.isVirtual(dir) { NSSound.beep(); return }
            let u = try FileOps.newFile(in: dir)
            recordUndo([.created(u)], name: "Yeni Dosya")
            refresh(dirs: [dir])
            pane.reveal(u)
            rename(FileNode.node(for: u), in: pane)
        } catch { showError(error) }
    }

    func copyToPasteboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        cutURLs = cut ? urls : []
        cutChangeCount = pb.changeCount
    }

    func paste(into dir: URL, forceMove: Bool, pane: PaneViewController) {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { NSSound.beep(); return }
        let isCut = pb.changeCount == cutChangeCount && !cutURLs.isEmpty
        transfer(urls, to: dir, move: forceMove || isCut) { [weak self, weak pane] result in
            if isCut { self?.cutURLs = []; self?.cutChangeCount = -1 }
            if !result.isEmpty { pane?.reveal(result[0]) }
        }
    }

    func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func openTerminal(_ dir: URL) {
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Context menu

    func buildContextMenu(_ menu: NSMenu, targets: [FileNode], folder: FileNode, pane: PaneViewController) {
        let urls = targets.map(\.url)
        let single = targets.count == 1 ? targets[0] : nil

        if !targets.isEmpty {
            menu.addItem(ClosureMenuItem("Aç", symbol: "arrow.up.forward.app") { [weak self] in self?.openItems(urls, in: pane) })
            if let single, !single.isDirectory || single.isPackage {
                let openWith = NSMenuItem(title: "Birlikte Aç", action: nil, keyEquivalent: "")
                openWith.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
                let sub = NSMenu()
                let def = NSWorkspace.shared.urlForApplication(toOpen: single.url)
                var apps = NSWorkspace.shared.urlsForApplications(toOpen: single.url)
                if let def { apps.removeAll { $0 == def }; apps.insert(def, at: 0) }
                for (i, a) in apps.prefix(25).enumerated() {
                    let name = FileManager.default.displayName(atPath: a.path) + (i == 0 && def != nil ? " (varsayılan)" : "")
                    let item = ClosureMenuItem(name) {
                        NSWorkspace.shared.open(urls, withApplicationAt: a, configuration: NSWorkspace.OpenConfiguration())
                    }
                    let icon = NSWorkspace.shared.icon(forFile: a.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    sub.addItem(item)
                    if i == 0 && def != nil { sub.addItem(.separator()) }
                }
                openWith.submenu = sub
                menu.addItem(openWith)
            }
            if let single, single.isDirectory {
                menu.addItem(ClosureMenuItem("Yeni Sekmede Aç", symbol: "plus.square.on.square") { pane.newTab(at: single.url) })
                menu.addItem(ClosureMenuItem("Diğer Panelde Aç", symbol: "rectangle.split.1x2") { [weak self] in self?.openInOtherPane(single.url) })
            }
            menu.addItem(ClosureMenuItem("Hızlı Bakış", symbol: "eye") { [weak self] in self?.toggleQuickLook(nil) })
            menu.addItem(ClosureMenuItem("Finder'da Göster", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
            if folder.isVirtual, let single {
                menu.addItem(ClosureMenuItem("Bulunduğu Klasöre Git", symbol: "arrow.turn.up.right") { pane.reveal(single.url) })
            }
            if let single, !single.isDirectory, Archives.canBrowse(single.url) {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Arşivin İçine Gir", symbol: "archivebox") { [weak self] in
                    self?.browseArchive(single.url, in: pane)
                })
                if !Archives.imageExts.contains(single.url.pathExtension.lowercased()) {
                    menu.addItem(ClosureMenuItem("Buraya Çıkar", symbol: "arrow.down.doc") { [weak self] in
                        Archives.extractHere(single.url) { r in
                            switch r {
                            case .success(let d):
                                self?.recordUndo([.created(d)], name: "Arşiv Çıkarma")
                                self?.refresh(dirs: [d.deletingLastPathComponent()])
                                pane.reveal(d)
                            case .failure(let e): self?.showError(e)
                            }
                        }
                    })
                }
            }
            let cloudTargets = targets.filter { $0.cloud != .none }
            if !cloudTargets.isEmpty {
                let cu = cloudTargets.map(\.url)
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Şimdi İndir", symbol: "icloud.and.arrow.down") { [weak self] in
                    Cloud.download(cu) { self?.refresh(dirs: [folder.url]) }
                })
                menu.addItem(ClosureMenuItem("Yerden Kazan (Yalnızca Bulutta Tut)", symbol: "icloud") { [weak self] in
                    Cloud.evict(cu) { e in
                        if let e { self?.showError(e) }
                        self?.refresh(dirs: [folder.url])
                    }
                })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Kes", key: "x", symbol: "scissors") { [weak self] in self?.copyToPasteboard(urls, cut: true) })
            menu.addItem(ClosureMenuItem("Kopyala", key: "c", symbol: "doc.on.doc") { [weak self] in self?.copyToPasteboard(urls, cut: false) })
        }
        let canPaste = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let pasteTarget = single?.isDirectory == true ? single!.url : folder.url
        if targets.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("Yapıştır", key: "v", symbol: "clipboard", enabled: canPaste) { [weak self] in
            self?.paste(into: pasteTarget, forceMove: false, pane: pane)
        })
        if canPaste {
            menu.addItem(ClosureMenuItem("Öğeyi Buraya Taşı", key: "v", mods: [.command, .option]) { [weak self] in
                self?.paste(into: pasteTarget, forceMove: true, pane: pane)
            })
        }

        if !targets.isEmpty {
            let otherDir = otherPane === pane ? activePane.currentFolder : otherPane.currentFolder
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Diğer Panele Kopyala  (F5)", symbol: "doc.on.doc.fill") { [weak self] in
                self?.transfer(urls, to: otherDir, move: false)
            })
            menu.addItem(ClosureMenuItem("Diğer Panele Taşı  (F6)", symbol: "arrow.right.doc.on.clipboard") { [weak self] in
                self?.transfer(urls, to: otherDir, move: true)
            })
            if let single {
                menu.addItem(ClosureMenuItem("Yeniden Adlandır  (F2)", symbol: "pencil") { [weak self] in self?.rename(single, in: pane) })
            }
            menu.addItem(ClosureMenuItem("Çoğalt", key: "d", symbol: "plus.square.on.square") { [weak self] in
                FileOps.duplicate(urls) { r, e in
                    if let e { self?.showError(e) }
                    self?.recordUndo(r.map { .created($0) }, name: "Çoğaltma")
                    self?.refresh(dirs: [folder.url])
                    if let f = r.first { pane.reveal(f) }
                }
            })
            menu.addItem(ClosureMenuItem("Sıkıştır (.zip)", symbol: "archivebox") { [weak self] in
                FileOps.compress(urls, in: folder.url) { r, e in
                    if let e { self?.showError(e) }
                    self?.recordUndo(r.map { .created($0) }, name: "Sıkıştırma")
                    self?.refresh(dirs: [folder.url])
                    if let f = r.first { pane.reveal(f) }
                }
            })
        }

        menu.addItem(.separator())
        let newDir = single?.isDirectory == true ? single!.url : folder.url
        menu.addItem(ClosureMenuItem("Yeni Klasör  (F7)", symbol: "folder.badge.plus") { [weak self] in self?.createFolder(in: newDir, pane: pane) })
        menu.addItem(ClosureMenuItem("Yeni Metin Dosyası", symbol: "doc.badge.plus") { [weak self] in self?.createFile(in: newDir, pane: pane) })

        if !targets.isEmpty {
            menu.addItem(.separator())
            menu.addItem(tagMenuItem(urls: urls, folder: folder.url))
            menu.addItem(ClosureMenuItem("Yolu Kopyala", key: "c", mods: [.command, .option], symbol: "link") { [weak self] in self?.copyPaths(urls) })
            menu.addItem(SidebarViewController.addToGroupMenu(urls: urls, window: window))
            menu.addItem(ClosureMenuItem("Rafa Ekle", key: "d", mods: [.command, .shift], symbol: "tray.and.arrow.down") {
                Shelf.shared.add(urls)
            })
        }
        if folder.isVirtual {
            menu.addItem(.separator())
            if SmartFolders.shared.isTemporary(path: folder.path) {
                menu.addItem(ClosureMenuItem("Akıllı Klasör Olarak Kaydet…", symbol: "gearshape.2") { [weak self] in
                    SmartFolders.shared.saveTemporary(path: folder.path, window: self?.window)
                })
            }
            menu.addItem(ClosureMenuItem("Sonuçları Yenile", symbol: "arrow.clockwise") { SmartFolders.shared.rerun(path: folder.path) })
            return
        }
        let termDir = single?.isDirectory == true ? single!.url : folder.url
        menu.addItem(ClosureMenuItem("Terminalde Aç", symbol: "terminal") { [weak self] in self?.openTerminal(termDir) })

        if !targets.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Çöp Sepetine Taşı  (F8)", key: "\u{8}", symbol: "trash") { [weak self] in self?.trash(urls) })
        }
    }

    private func tagMenuItem(urls: [URL], folder: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Renk Etiketi", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let sub = NSMenu()
        let names = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        // Finder order: red, orange, yellow, green, blue, purple, gray
        for n in [6, 7, 5, 2, 4, 3, 1] where n < names.count {
            let mi = ClosureMenuItem(names[n]) { [weak self] in
                FileOps.setLabel(urls, n)
                self?.refresh(dirs: [folder])
            }
            mi.image = Self.dot(colors[n])
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem("Etiketi Kaldır") { [weak self] in
            FileOps.setLabel(urls, 0)
            self?.refresh(dirs: [folder])
        })
        item.submenu = sub
        return item
    }

    private static func dot(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: - Menu actions (responder chain)

    private var pane: PaneViewController { activePane }

    @objc func newTab(_ sender: Any?) { pane.newTab(nil) }
    @objc func closeTab(_ sender: Any?) {
        if pane.tabs.count > 1 { pane.closeCurrentTab() } else { window?.performClose(nil) }
    }
    @objc func nextTab(_ sender: Any?) { pane.activateTab((pane.tabIndex + 1) % pane.tabs.count) }
    @objc func previousTab(_ sender: Any?) { pane.activateTab((pane.tabIndex - 1 + pane.tabs.count) % pane.tabs.count) }

    @objc func openSelection(_ sender: Any?) { openItems(pane.selectedURLs, in: pane) }
    @objc func renameSelection(_ sender: Any?) {
        guard let n = pane.selectedNodes.first, pane.selectedNodes.count == 1 else { NSSound.beep(); return }
        rename(n, in: pane)
    }
    @objc func moveToTrash(_ sender: Any?) { trash(pane.selectedURLs) }
    @objc func newFolder(_ sender: Any?) { createFolder(in: pane.currentFolder, pane: pane) }
    @objc func newTextFile(_ sender: Any?) { createFile(in: pane.currentFolder, pane: pane) }
    @objc func duplicateSelection(_ sender: Any?) {
        let urls = pane.selectedURLs
        let p = pane
        FileOps.duplicate(urls) { [weak self] r, e in
            if let e { self?.showError(e) }
            self?.recordUndo(r.map { .created($0) }, name: "Çoğaltma")
            self?.refresh(dirs: urls.map { $0.deletingLastPathComponent() })
            if let f = r.first { p.reveal(f) }
        }
    }
    @objc func compressSelection(_ sender: Any?) {
        let urls = pane.selectedURLs
        guard let dir = urls.first?.deletingLastPathComponent() else { return }
        let p = pane
        FileOps.compress(urls, in: dir) { [weak self] r, e in
            if let e { self?.showError(e) }
            self?.recordUndo(r.map { .created($0) }, name: "Sıkıştırma")
            self?.refresh(dirs: [dir])
            if let f = r.first { p.reveal(f) }
        }
    }
    @objc func copyToOtherPane(_ sender: Any?) {
        if bottomItem.isCollapsed { NSSound.beep(); return }
        transfer(pane.selectedURLs, to: otherPane.currentFolder, move: false)
    }
    @objc func moveToOtherPane(_ sender: Any?) {
        if bottomItem.isCollapsed { NSSound.beep(); return }
        transfer(pane.selectedURLs, to: otherPane.currentFolder, move: true)
    }
    @objc func copyPath(_ sender: Any?) { copyPaths(pane.selectedURLs.isEmpty ? [pane.currentFolder] : pane.selectedURLs) }
    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(pane.selectedURLs.isEmpty ? [pane.currentFolder] : pane.selectedURLs)
    }
    @objc func openTerminalHere(_ sender: Any?) { openTerminal(pane.currentFolder) }
    @objc func addToFavorites(_ sender: Any?) {
        let urls = pane.selectedURLs.isEmpty ? [pane.currentFolder] : pane.selectedURLs
        if let g = Prefs.shared.groups.first { Prefs.shared.add(urls, toGroup: g.id) } else { Prefs.shared.createGroup("Favoriler", with: urls) }
    }

    @objc func showCommandPalette(_ sender: Any?) { palette.toggle() }
    func debugPaletteText(_ s: String) { palette.debugSetText(s) }

    @objc func newSmartFolder(_ sender: Any?) {
        let cur = pane.currentFolder
        SmartFolders.shared.promptCreate(window: window, current: VirtualFolders.isVirtual(cur) ? nil : cur) { [weak self] f in
            self?.activePane.open(folder: SmartFolders.shared.url(for: f))
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        pane.open(folder: u)
    }

    @objc func addToShelf(_ sender: Any?) {
        if !pane.selectedURLs.isEmpty { Shelf.shared.add(pane.selectedURLs) } else { NSSound.beep() }
    }

    @objc func cut(_ sender: Any?) { copyToPasteboard(pane.selectedURLs, cut: true) }
    @objc func copy(_ sender: Any?) { copyToPasteboard(pane.selectedURLs, cut: false) }
    @objc func paste(_ sender: Any?) { paste(into: pane.currentFolder, forceMove: false, pane: pane) }
    @objc func moveHere(_ sender: Any?) { paste(into: pane.currentFolder, forceMove: true, pane: pane) }

    @objc func toggleHidden(_ sender: Any?) { Prefs.shared.showHidden.toggle() }
    @objc func sortBy(_ sender: NSMenuItem) {
        if let k = SortKey(rawValue: sender.tag) { Prefs.shared.toggleSort(k, for: pane.currentFolder.path) }
    }
    @objc func reload(_ sender: Any?) { pane.reloadPane() }

    @objc func toggleDualPane(_ sender: Any?) {
        let collapse = !bottomItem.isCollapsed
        bottomItem.animator().isCollapsed = collapse
        Prefs.shared.dualPane = !collapse
        if collapse && activeIndex == 1 { setActive(0) }
    }
    @objc func toggleLayout(_ sender: Any?) {
        Prefs.shared.overUnder.toggle()
        paneSplit.splitView.isVertical = !Prefs.shared.overUnder
        paneSplit.splitView.adjustSubviews()
        let sv = paneSplit.splitView
        let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
        sv.setPosition(total / 2, ofDividerAt: 0)
    }
    @objc func togglePreview(_ sender: Any?) {
        Prefs.shared.previewVisible.toggle()
        panes.forEach { $0.setPreviewVisible(Prefs.shared.previewVisible) }
    }
    @objc func toggleSidebarPanel(_ sender: Any?) { mainSplit.toggleSidebar(sender) }
    @objc func swapPanes(_ sender: Any?) {
        let a = panes[0].state(), b = panes[1].state()
        let home = FileManager.default.homeDirectoryForCurrentUser
        panes[0].restore(b, defaultFolder: home)
        panes[1].restore(a, defaultFolder: home)
    }
    @objc func sameFolderInOther(_ sender: Any?) {
        if bottomItem.isCollapsed { toggleDualPane(nil) }
        otherPane.open(folder: pane.currentFolder)
        pane.focus()
    }

    @objc func goBack(_ sender: Any?) { pane.goBack() }
    @objc func goForward(_ sender: Any?) { pane.goForward() }
    @objc func goUp(_ sender: Any?) { pane.goUp() }
    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        pane.open(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    @objc func goToFolder(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Klasöre Git"
        let field = NSTextField(string: pane.currentFolder.path)
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Git")
        alert.addButton(withTitle: "Vazgeç")
        alert.window.initialFirstResponder = field
        let p = pane
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let path = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { NSSound.beep(); return }
            let u = URL(fileURLWithPath: path)
            if isDir.boolValue { p.open(folder: u) } else { p.reveal(u) }
        }
    }
    @objc func focusSwitch(_ sender: Any?) { switchPane(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSel = !pane.selectedNodes.isEmpty
        switch item.action {
        case #selector(toggleHidden(_:)): item.state = Prefs.shared.showHidden ? .on : .off
        case #selector(toggleDualPane(_:)): item.state = bottomItem.isCollapsed ? .off : .on
        case #selector(togglePreview(_:)): item.state = Prefs.shared.previewVisible ? .on : .off
        case #selector(toggleSidebarPanel(_:)): item.state = sidebarItem.isCollapsed ? .off : .on
        case #selector(toggleLayout(_:)): item.state = Prefs.shared.overUnder ? .on : .off
        case #selector(setTheme(_:)):
            item.state = Theme.all.indices.contains(item.tag) && Theme.all[item.tag].id == Theme.current.id ? .on : .off
        case #selector(sortBy(_:)):
            item.state = Prefs.shared.sort(for: pane.currentFolder.path).key.rawValue == item.tag ? .on : .off
        case #selector(renameSelection(_:)): return pane.selectedNodes.count == 1
        case #selector(moveToTrash(_:)), #selector(cut(_:)), #selector(copy(_:)), #selector(duplicateSelection(_:)),
             #selector(compressSelection(_:)), #selector(openSelection(_:)):
            return hasSel
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)): return hasSel && !bottomItem.isCollapsed
        case #selector(paste(_:)), #selector(moveHere(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        case #selector(goBack(_:)): return !pane.tab.back.isEmpty
        case #selector(goForward(_:)): return !pane.tab.forward.isEmpty
        case #selector(closeTab(_:)), #selector(nextTab(_:)), #selector(previousTab(_:)): return true
        default: break
        }
        return true
    }

    // MARK: - Toolbar

    private static let dualID = NSToolbarItem.Identifier("dual")
    private static let layoutID = NSToolbarItem.Identifier("layout")
    private static let previewID = NSToolbarItem.Identifier("preview")
    private static let themeID = NSToolbarItem.Identifier("theme")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.themeID, Self.dualID, Self.layoutID, Self.previewID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.themeID {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Tema")
            item.label = "Tema"
            item.toolTip = "Tema"
            item.showsIndicator = false
            let m = NSMenu()
            for (i, t) in Theme.all.enumerated() {
                let mi = NSMenuItem(title: t.name, action: #selector(setTheme(_:)), keyEquivalent: "")
                mi.tag = i
                mi.target = self
                m.addItem(mi)
            }
            item.menu = m
            return item
        }
        let specs: [NSToolbarItem.Identifier: (String, String, Selector)] = [
            Self.dualID: ("rectangle.split.1x2", "Tek / çift panel (⌥⌘D)", #selector(toggleDualPane(_:))),
            Self.layoutID: ("rectangle.split.2x1", "Üst-alt / yan yana (⌥⌘L)", #selector(toggleLayout(_:))),
            Self.previewID: ("sidebar.right", "Önizleme panelleri (⌥⌘P)", #selector(togglePreview(_:))),
        ]
        guard let (symbol, tip, action) = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.label = tip
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    // MARK: - Quick Look panel

    @objc func toggleQuickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        max(1, pane.selectedURLs.count)
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = pane.selectedURLs
        return (urls.indices.contains(index) ? urls[index] : pane.currentFolder) as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // let arrow keys move the selection in the browser while the panel is open
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
            pane.focus()
            window?.firstResponder?.keyDown(with: event)
            return true
        }
        return false
    }
}
