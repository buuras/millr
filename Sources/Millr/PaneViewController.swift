import AppKit

struct TabState: Codable {
    /// Current folder of the tab.
    var root: String
    var selection: [String]
}

struct PaneState: Codable {
    var tabs: [TabState]
    var active: Int
}

final class BrowserTab {
    var folder: URL
    var selection: [URL]
    var back: [URL] = []
    var forward: [URL] = []

    init(folder: URL, selection: [URL] = []) {
        self.folder = folder.standardizedFileURL
        self.selection = selection
    }
}

/// One file pane: tab strip, navigation/controls bar, Miller columns, its own preview and a status line.
final class PaneViewController: NSViewController, ColumnsViewDelegate, NSSplitViewDelegate {
    weak var coordinator: MainWindowController?
    var index = 0

    let columnsView = ColumnsView()
    let preview = PreviewViewController()
    private let split = ThemedSplitView()
    /// Rounded card holding the columns and the preview.
    private let card = NSView()
    private var navButtons: [NSButton] = []
    private let tabBar = TabBarView()
    private let pathControl = NSPathControl()
    private let statusLabel = label("", size: 11, color: .secondaryLabelColor)
    private let activeBar = NSView()
    private var didInitialSplit = false

    private(set) var tabs: [BrowserTab] = []
    private(set) var tabIndex = 0
    var tab: BrowserTab { tabs[tabIndex] }
    private var suppressHistory = false
    private var lastFolderPath: String?

    var isActive = false { didSet { updateActiveLook() } }

    // MARK: - View

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        activeBar.wantsLayer = true
        activeBar.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] i in self?.activateTab(i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(i) }
        tabBar.onAdd = { [weak self] in self?.newTab(nil) }


        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let previewButton = symbolButton("sidebar.right", L("Preview pane (⌥⌘P)"), target: self, action: #selector(togglePreview))
        navButtons = [previewButton]
        let nav = NSStackView(views: [pathControl, previewButton])
        nav.orientation = .horizontal
        nav.spacing = 6
        nav.translatesAutoresizingMaskIntoConstraints = false

        columnsView.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(columnsView)
        split.addArrangedSubview(preview.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
        split.autosaveName = "OCPanePreview\(index)"
        preview.view.isHidden = !Prefs.shared.previewVisible

        v.wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(split)

        statusLabel.font = Fonts.rounded(11, .medium)

        [activeBar, tabBar, nav, card, statusLabel].forEach { v.addSubview($0) }
        NSLayoutConstraint.activate([
            activeBar.topAnchor.constraint(equalTo: v.topAnchor),
            activeBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            activeBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            activeBar.heightAnchor.constraint(equalToConstant: 0),

            tabBar.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            tabBar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            tabBar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            tabBar.heightAnchor.constraint(equalToConstant: 26),

            nav.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 2),
            nav.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            nav.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            nav.heightAnchor.constraint(equalToConstant: 26),

            card.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),

            split.topAnchor.constraint(equalTo: card.topAnchor),
            split.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -5),
        ])
        v.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        view = v
        applyTheme()
        updateControls()
    }

    /// Re-applies colors of the current theme to everything this pane draws.
    func applyTheme() {
        guard isViewLoaded else { return }
        let t = Theme.current
        view.layer?.backgroundColor = t.chrome.cgColor
        statusLabel.textColor = t.secondary
        for b in navButtons { b.contentTintColor = t.secondary }
        columnsView.applyTheme()
        preview.applyTheme()
        split.needsDisplay = true
        updateActiveLook()
        updateControls()
        reloadTabBar()
    }

    /// Called once the window has its final size: give the preview a sensible default width.
    func applyInitialSplit() {
        guard !didInitialSplit else { return }
        didInitialSplit = true
        let key = "NSSplitView Subview Frames OCPanePreview\(index)"
        let previewTooWide = preview.view.frame.width > split.bounds.width * 0.45
        if UserDefaults.standard.object(forKey: key) == nil || previewTooWide {
            split.setPosition(split.bounds.width - 320, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 320 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        splitView.bounds.width - 220
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === preview.view }

    func setPreviewVisible(_ visible: Bool) {
        guard isViewLoaded else { return }
        preview.view.isHidden = !visible
        split.adjustSubviews()
        if visible, preview.view.frame.width < 220 {
            split.setPosition(split.bounds.width - 320, ofDividerAt: 0)
        }
        if visible { preview.show(selection: selectedNodes, folder: currentFolderNode) }
    }

    private func updateActiveLook() {
        guard isViewLoaded else { return }
        let t = Theme.current
        card.layer?.borderColor = (isActive ? t.accent : t.separator).cgColor
        card.layer?.borderWidth = isActive ? 2 : 1
    }

    private func updateControls() {
        columnsView.refreshControls()
    }

    @objc private func togglePreview() { coordinator?.togglePreview(nil) }

    func focus() { columnsView.focus() }

    // MARK: - State

    func restore(_ state: PaneState?, defaultFolder: URL) {
        tabs = []
        if let state {
            tabs = state.tabs.compactMap { t in
                guard FileManager.default.fileExists(atPath: t.root) else { return nil }
                return BrowserTab(folder: URL(fileURLWithPath: t.root), selection: t.selection.map { URL(fileURLWithPath: $0) })
            }
        }
        if tabs.isEmpty { tabs = [BrowserTab(folder: defaultFolder)] }
        tabIndex = min(max(0, state?.active ?? 0), tabs.count - 1)
        activateTab(tabIndex)
    }

    func state() -> PaneState {
        PaneState(tabs: tabs.map { TabState(root: $0.folder.path, selection: $0.selection.map(\.path)) }, active: tabIndex)
    }

    // MARK: - Tabs

    func activateTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        tabIndex = i
        suppressHistory = true
        lastFolderPath = nil
        let existing = tab.selection.filter { FileManager.default.fileExists(atPath: $0.path) }
        columnsView.show(path: FileNode.chain(to: tab.folder), selection: existing)
        selectionChanged()
        suppressHistory = false
    }

    @objc func newTab(_ sender: Any?) { newTab(at: currentFolder) }

    func newTab(at url: URL) {
        tabs.append(BrowserTab(folder: url))
        activateTab(tabs.count - 1)
    }

    func closeTab(_ i: Int) {
        guard tabs.count > 1, tabs.indices.contains(i) else { return }
        tabs.remove(at: i)
        activateTab(min(i == tabIndex ? i : (i < tabIndex ? tabIndex - 1 : tabIndex), tabs.count - 1))
    }

    func closeCurrentTab() { closeTab(tabIndex) }

    private func reloadTabBar() {
        let titles: [(String, NSImage?)] = tabs.map { t in
            let n = FileNode.node(for: t.folder)
            return (n.name, n.icon)
        }
        tabBar.reload(titles: titles, selected: tabIndex)
    }

    // MARK: - Selection model

    var selectedNodes: [FileNode] { columnsView.selectedNodes }
    var selectedURLs: [URL] { selectedNodes.map(\.url) }
    var currentFolderNode: FileNode { columnsView.currentFolder ?? FileNode.node(for: tab.folder) }
    var currentFolder: URL { currentFolderNode.url }

    // MARK: - Navigation

    /// Show a folder's contents as the last (detailed) column.
    func open(folder url: URL) {
        columnsView.show(path: FileNode.chain(to: url), selection: [])
        selectionChanged()
        focus()
    }

    /// Show the item selected inside its parent folder.
    func reveal(_ url: URL) {
        let u = url.standardizedFileURL
        if u.path == "/" { open(folder: u); return }
        columnsView.show(path: FileNode.chain(to: u.deletingLastPathComponent()), selection: [u])
        selectionChanged()
        focus()
    }

    @objc func goUp() {
        let cur = currentFolder
        guard cur.path != "/", !VirtualFolders.isVirtual(cur) else { NSSound.beep(); return }
        // Leaving a browsed archive returns to the archive file itself.
        if let archive = Archives.origin(ofRoot: cur.path) { reveal(archive); return }
        reveal(cur)
    }

    @objc func goBack() {
        guard let prev = tab.back.popLast() else { NSSound.beep(); return }
        tab.forward.append(currentFolder)
        suppressHistory = true
        open(folder: prev)
        suppressHistory = false
    }

    @objc func goForward() {
        guard let next = tab.forward.popLast() else { NSSound.beep(); return }
        tab.back.append(currentFolder)
        suppressHistory = true
        open(folder: next)
        suppressHistory = false
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let u = sender.clickedPathItem?.url else { return }
        let path = u.standardizedFileURL.path
        if let i = columnsView.path.firstIndex(where: { $0.path == path }), i < columnsView.path.count - 1 {
            reveal(columnsView.path[i + 1].url)
        } else {
            open(folder: u)
        }
    }

    @objc func reloadPane() {
        for n in columnsView.path where n.isVirtual { SmartFolders.shared.rerun(path: n.path) }
        for n in columnsView.path { n.invalidate() }
        FolderSizer.shared.invalidate(columnsView.displayedFolderPaths)
        columnsView.reload(changed: nil)
    }

    var displayedFolderPaths: Set<String> { columnsView.displayedFolderPaths }

    func refreshIfShowing(_ paths: Set<String>) {
        guard isViewLoaded else { return }
        let hit = displayedFolderPaths.intersection(paths)
        if !hit.isEmpty { columnsView.reload(changed: hit) }
    }

    func reloadKeepingSelection() {
        columnsView.detailsEnabled = Prefs.shared.detailsView
        updateControls()
        columnsView.reload(changed: nil)
    }

    // MARK: - ColumnsViewDelegate

    func columnsSelectionChanged(_ view: ColumnsView) { selectionChanged() }

    func columnsCommand(_ view: ColumnsView, _ command: ColumnCommand) {
        switch command {
        case .up: goUp()
        case .back: goBack()
        case .forward: goForward()
        case .reload: reloadPane()
        case .newFolder: coordinator?.createFolder(in: currentFolder, pane: self)
        case .toggleDetails: Prefs.shared.detailsView.toggle()
        case .toggleHidden: Prefs.shared.showHidden.toggle()
        }
    }

    func columnsCanGo(_ view: ColumnsView) -> (back: Bool, forward: Bool) {
        tabs.indices.contains(tabIndex) ? (!tab.back.isEmpty, !tab.forward.isEmpty) : (false, false)
    }

    func columnsOpen(_ view: ColumnsView, nodes: [FileNode]) {
        coordinator?.openItems(nodes.map(\.url), in: self)
    }

    func columnsBuildMenu(_ view: ColumnsView, menu: NSMenu, targets: [FileNode], folder: FileNode) {
        coordinator?.buildContextMenu(menu, targets: targets, folder: folder, pane: self)
    }

    func columnsDrop(_ view: ColumnsView, urls: [URL], to folder: URL, move: Bool) {
        coordinator?.transfer(urls, to: folder, move: move)
    }

    func selectionChanged() {
        let folder = currentFolder
        if lastFolderPath != folder.path { History.shared.record(folder) }
        if let last = lastFolderPath, last != folder.path, !suppressHistory {
            tab.back.append(URL(fileURLWithPath: last))
            if tab.back.count > 200 { tab.back.removeFirst() }
            tab.forward.removeAll()
        }
        lastFolderPath = folder.path
        tab.folder = folder
        tab.selection = selectedURLs
        if currentFolderNode.isVirtual {
            let item = NSPathControlItem()
            item.title = currentFolderNode.name
            item.image = currentFolderNode.icon
            pathControl.pathItems = [item]
        } else {
            pathControl.url = folder
        }
        columnsView.refreshControls()
        updateStatus()
        reloadTabBar()
        if !preview.view.isHidden { preview.show(selection: selectedNodes, folder: currentFolderNode) }
        coordinator?.paneSelectionChanged(self)
    }

    private func updateStatus() {
        let folder = currentFolderNode
        let sel = selectedNodes
        var parts = [folder.isVirtual ? L("%d results · smart folder (live)", folder.children.count) : Fmt.items(folder.children.count)]
        if let c = Archives.container(of: folder.path) {
            parts.append(L("📦 Contents of %@ — read-only copy, changes are not written to the archive", c.archive.lastPathComponent))
        }
        if !sel.isEmpty {
            parts.append(L("%d selected", sel.count))
            let files = sel.filter { !$0.isContainer }
            if !files.isEmpty { parts.append(Fmt.size(files.reduce(0) { $0 + $1.size })) }
        }
        if let cloud = Cloud.providerName(for: folder.path) { parts.append("☁︎ \(cloud)") }
        if !folder.isVirtual, let v = try? folder.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = v.volumeAvailableCapacityForImportantUsage {
            parts.append(L("%@ free", Fmt.size(free)))
        }
        if let e = folder.loadError { parts.append("⚠︎ \(e)") }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
    }
}
