import AppKit

enum ColumnCommand {
    case up, back, forward, newFolder, reload, toggleDetails, toggleHidden
}

protocol ColumnsViewDelegate: AnyObject {
    func columnsCommand(_ view: ColumnsView, _ command: ColumnCommand)
    func columnsCanGo(_ view: ColumnsView) -> (back: Bool, forward: Bool)
    func columnsSelectionChanged(_ view: ColumnsView)
    func columnsOpen(_ view: ColumnsView, nodes: [FileNode])
    func columnsBuildMenu(_ view: ColumnsView, menu: NSMenu, targets: [FileNode], folder: FileNode)
    func columnsDrop(_ view: ColumnsView, urls: [URL], to folder: URL, move: Bool)
}

/// Miller columns from the volume root down to the current folder.
/// The last columns are full width (the very last one is a detailed list);
/// earlier ones collapse to thin strips that only show the folder name and
/// expand while the mouse rests on them.
final class ColumnsView: NSView {
    weak var delegate: ColumnsViewDelegate?
    private(set) var path: [FileNode] = []
    private(set) var focusedColumn = 0
    private(set) var columns: [ColumnView] = []
    private let scroll = NSScrollView()
    private let content = FlippedView()
    fileprivate(set) var programmatic = false
    private var hoverExpanded: Int?
    private var hoverTimer: Timer?

    var detailsEnabled = Prefs.shared.detailsView
    static let fullColumnCount = 4

    /// Every live columns view; their folders are kept out of the children cache eviction.
    private static let live: NSHashTable<ColumnsView> = {
        FileNode.inUse = { ColumnsView.live.allObjects.flatMap(\.path) }
        return .weakObjects()
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = content
        addSubview(scroll)
        Self.live.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(sizesUpdated(_:)), name: .folderSizesUpdated, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutColumns()
    }

    func applyTheme() {
        columns.forEach { $0.applyTheme() }
    }

    // MARK: - Type to filter

    /// OneCommander-style live filter: typing in the focused column filters it.
    /// Returns true when the key was consumed.
    func handleFilterKey(_ e: NSEvent) -> Bool {
        guard columns.indices.contains(focusedColumn) else { return false }
        let col = columns[focusedColumn]
        guard window?.firstResponder === col.table else { return false }
        if !e.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        switch e.keyCode {
        case 53: // Esc
            guard !col.filter.isEmpty else { return false }
            setFilter("", in: col)
            return true
        case 51: // Backspace
            guard !col.filter.isEmpty else { return false }
            setFilter(String(col.filter.dropLast()), in: col)
            return true
        case 36, 76, 48, 123, 124, 125, 126, 115, 116, 119, 121:
            return false
        default:
            guard let ch = e.characters, !ch.isEmpty,
                  ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
            else { return false }
            if ch == " " && col.filter.isEmpty { return false }
            setFilter(col.filter + ch, in: col)
            return true
        }
    }

    func setFilter(_ text: String, in c: ColumnView) {
        programmatic = true
        if c.index < columns.count - 1 {
            removeColumns(from: c.index + 1)
            path = Array(path[0...c.index])
        }
        c.setFilter(text)
        programmatic = false
        focusedColumn = c.index
        hoverExpanded = nil
        layoutColumns()
        delegate?.columnsSelectionChanged(self)
    }

    var activeFilter: String { columns.indices.contains(focusedColumn) ? columns[focusedColumn].filter : "" }

    /// Refreshes the control states (history, toggles, sort) of the active column.
    func refreshControls() {
        columns.last?.updateControls()
    }

    @objc private func sizesUpdated(_ n: Notification) {
        guard let paths = n.userInfo?["paths"] as? Set<String> else { return }
        columns.forEach { $0.sizesUpdated(paths) }
    }

    // MARK: - Model

    var currentFolder: FileNode? { path.last }

    var selectedNodes: [FileNode] {
        columns.indices.contains(focusedColumn) ? columns[focusedColumn].selectedNodes : []
    }

    var focusedTable: NSTableView? {
        columns.indices.contains(focusedColumn) ? columns[focusedColumn].table : nil
    }

    /// Show `newPath` (folders, root first) and select `selection` inside its last folder.
    func show(path newPath: [FileNode], selection: [URL]) {
        programmatic = true
        var keep = 0
        while keep < min(columns.count, newPath.count), columns[keep].folder === newPath[keep] { keep += 1 }
        removeColumns(from: keep)
        for i in keep..<newPath.count { addColumn(newPath[i]) }
        path = newPath
        for i in 0..<max(0, columns.count - 1) { columns[i].select(paths: [path[i + 1].path]) }
        columns.last?.select(paths: selection.map { $0.standardizedFileURL.path })
        focusedColumn = max(0, columns.count - 1)
        hoverExpanded = nil
        programmatic = false
        layoutColumns()
        scrollToEnd()
    }

    private func addColumn(_ folder: FileNode) {
        let c = ColumnView(folder: folder, index: columns.count, owner: self)
        columns.append(c)
        content.addSubview(c)
    }

    private func removeColumns(from i: Int) {
        guard i < columns.count else { return }
        for c in columns[i...] { c.removeFromSuperview() }
        columns.removeSubrange(i...)
    }

    /// Re-read folders that changed on disk, keeping the selection.
    func reload(changed: Set<String>?) {
        programmatic = true
        var cut: Int?
        for (i, c) in columns.enumerated() where changed == nil || changed!.contains(c.folder.path) {
            c.reloadItems()
            if i + 1 < path.count, !c.folder.isLoading, !c.items.contains(where: { $0 === path[i + 1] }) {
                cut = cut.map { min($0, i) } ?? i
            }
        }
        if let cut {
            removeColumns(from: cut + 1)
            path = Array(path[0...cut])
            focusedColumn = min(focusedColumn, cut)
        }
        programmatic = false
        layoutColumns()
        delegate?.columnsSelectionChanged(self)
    }

    var displayedFolderPaths: Set<String> { Set(path.map(\.path)) }

    // MARK: - Column callbacks

    // While the mouse button is down (click or drag start) the column layout must not
    // change: rebuilding columns under an active drag session leaves macOS stuck in
    // drag mode. Folder opening is applied on mouse-up, and skipped if a drag began.
    fileprivate var mouseTracking = false
    fileprivate var dragStarted = false
    private weak var pendingColumn: ColumnView?

    fileprivate func mouseTrackingEnded(_ c: ColumnView) {
        mouseTracking = false
        let pending = pendingColumn
        pendingColumn = nil
        if dragStarted { dragStarted = false; return }
        if let pending, pending === c { applySelection(pending) }
    }

    fileprivate func columnSelectionChanged(_ c: ColumnView) {
        guard !programmatic else { return }
        focusedColumn = c.index
        if mouseTracking {
            pendingColumn = c
            delegate?.columnsSelectionChanged(self)
            return
        }
        applySelection(c)
    }

    private func applySelection(_ c: ColumnView) {
        let i = c.index
        guard columns.indices.contains(i), columns[i] === c else { return }
        focusedColumn = i
        do {
            let sel = c.selectedNodes
            removeColumns(from: i + 1)
            path = Array(path[0...i])
            if sel.count == 1, sel[0].isDirectory {
                path.append(sel[0])
                addColumn(sel[0])
            }
            if hoverExpanded != nil && hoverExpanded! >= columns.count - Self.fullColumnCount { hoverExpanded = nil }
            layoutColumns()
            scrollToEnd()
        }
        delegate?.columnsSelectionChanged(self)
    }

    fileprivate func columnFocused(_ c: ColumnView) {
        guard focusedColumn != c.index else { return }
        focusedColumn = c.index
        delegate?.columnsSelectionChanged(self)
    }

    fileprivate func columnDoubleClicked(_ c: ColumnView) {
        let sel = c.selectedNodes
        guard !sel.isEmpty else { return }
        delegate?.columnsOpen(self, nodes: sel)
    }

    /// ← : move focus to the parent column.
    fileprivate func moveLeft(from c: ColumnView) {
        guard c.index > 0 else { return }
        focus(column: c.index - 1)
        delegate?.columnsSelectionChanged(self)
    }

    /// → : go into the selected folder.
    fileprivate func moveRight(from c: ColumnView) {
        let sel = c.selectedNodes
        guard sel.count == 1, sel[0].isDirectory else { return }
        if c.index == columns.count - 1 {
            programmatic = true
            path.append(sel[0])
            addColumn(sel[0])
            programmatic = false
            layoutColumns()
            scrollToEnd()
        }
        let next = c.index + 1
        if columns[next].items.isEmpty {
            focus(column: next)
        } else {
            if columns[next].table.selectedRowIndexes.isEmpty {
                programmatic = true
                columns[next].table.selectRowIndexes([0], byExtendingSelection: false)
                programmatic = false
            }
            focus(column: next)
        }
        delegate?.columnsSelectionChanged(self)
    }

    func focus(column i: Int) {
        guard columns.indices.contains(i) else { return }
        focusedColumn = i
        window?.makeFirstResponder(columns[i].table)
        columns[i].table.scrollRowToVisible(columns[i].table.selectedRow)
    }

    func focus() { focus(column: focusedColumn) }

    // MARK: - Hover expansion of collapsed strips

    fileprivate func hoverBegan(_ c: ColumnView) {
        hoverTimer?.invalidate()
        guard c.collapsed, NSEvent.pressedMouseButtons == 0 else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self, weak c] _ in
            guard let self, let c else { return }
            self.hoverExpanded = c.index
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.layoutColumns(animated: true)
            }
        }
    }

    fileprivate func hoverEnded(_ c: ColumnView) {
        hoverTimer?.invalidate()
        guard hoverExpanded == c.index else { return }
        if window?.firstResponder === c.table { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoverExpanded = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.layoutColumns(animated: true)
            }
        }
    }

    fileprivate func stripClicked(_ c: ColumnView) {
        hoverTimer?.invalidate()
        hoverExpanded = c.index
        layoutColumns()
        focus(column: c.index)
        delegate?.columnsSelectionChanged(self)
    }

    // MARK: - Layout

    func layoutColumns(animated: Bool = false) {
        let W = scroll.contentSize.width, H = scroll.contentSize.height
        guard W > 0, !columns.isEmpty else { return }
        let n = columns.count
        let detailW: CGFloat = 1.8
        // Active folder + its 3 parents always show their contents; older ancestors
        // become thin vertical strips.
        let fullStart = max(0, n - Self.fullColumnCount)

        var widths = [CGFloat](repeating: 0, count: n)
        var weights = [CGFloat](repeating: 0, count: n)
        var stripTotal: CGFloat = 0
        for (i, c) in columns.enumerated() {
            let collapsed = i < fullStart && hoverExpanded != i
            c.setCollapsed(collapsed)
            c.isDetailed = detailsEnabled && i == n - 1
            c.isLast = i == n - 1
            if collapsed {
                widths[i] = ColumnView.stripWidth
                stripTotal += widths[i]
            } else {
                weights[i] = c.isDetailed ? detailW : 1
            }
        }
        let totalWeight = weights.reduce(0, +)
        let avail = max(0, W - stripTotal)
        for i in 0..<n where weights[i] > 0 {
            widths[i] = floor(avail * weights[i] / totalWeight)
        }
        // Narrow pane: keep the detailed list readable, share the rest among parents.
        let detailMin: CGFloat = 320
        if detailsEnabled, n > 0, widths[n - 1] < detailMin {
            let others = (0..<(n - 1)).filter { weights[$0] > 0 }
            let rest = max(0, avail - detailMin)
            widths[n - 1] = others.isEmpty ? avail : detailMin
            for i in others { widths[i] = max(100, floor(rest / CGFloat(others.count))) }
        }
        var x: CGFloat = 0
        for (i, c) in columns.enumerated() {
            let f = NSRect(x: x, y: 0, width: widths[i], height: H)
            if animated { c.animator().frame = f } else { c.frame = f }
            x += widths[i]
        }
        content.frame = NSRect(x: 0, y: 0, width: max(W, x), height: H)
        if !animated { scrollToEnd() }
    }

    func scrollToEnd() {
        let W = scroll.contentSize.width
        let x = max(0, content.frame.width - W)
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Drag helpers

    private let dropBadge = DropBadgeView()

    fileprivate func showDropBadge(_ op: NSDragOperation, target: FileNode, at windowPoint: NSPoint) {
        guard op != [] else { hideDropBadge(); return }
        if dropBadge.superview == nil { addSubview(dropBadge) }
        dropBadge.configure(move: op != .copy, target: target.name)
        let p = convert(windowPoint, from: nil)
        let s = dropBadge.fittingSize
        var x = p.x + 16, y = p.y + 14
        if x + s.width > bounds.maxX - 4 { x = p.x - s.width - 10 }
        if y + s.height > bounds.maxY - 4 { y = p.y - s.height - 10 }
        dropBadge.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
        dropBadge.isHidden = false
    }

    fileprivate func hideDropBadge() { dropBadge.isHidden = true }

    static func wantsMove() -> Bool {
        let m = NSEvent.modifierFlags
        return m.contains(.shift) || m.contains(.command)
    }

    static func operation(_ info: NSDraggingInfo, move: Bool) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if move {
            if mask.contains(.move) { return .move }
            if mask.contains(.generic) { return .generic }
            return []
        }
        return mask.contains(.copy) ? .copy : []
    }

    static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

// MARK: - Column

final class FileTableView: NSTableView {
    weak var column: ColumnView?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let column { column.owner?.columnFocused(column) }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        column?.owner?.mouseTracking = true
        column?.owner?.dragStarted = false
        super.mouseDown(with: dragAwareEvent(event))
        if let column { column.owner?.mouseTrackingEnded(column) }
    }

    /// Shift/Cmd held before the press means "move" in our drag model, but NSTableView
    /// treats it as selection extension and never starts a drag. If the press lands on a
    /// selected row and the mouse starts moving, hand the table an unmodified event so it
    /// drags the selection; the modifier is still read live via `ColumnsView.wantsMove`.
    private func dragAwareEvent(_ e: NSEvent) -> NSEvent {
        let mods = e.modifierFlags.intersection([.shift, .command])
        guard !mods.isEmpty, e.clickCount == 1 else { return e }
        let row = self.row(at: convert(e.locationInWindow, from: nil))
        guard row >= 0, selectedRowIndexes.contains(row),
              let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: false),
              next.type == .leftMouseDragged else { return e }
        return NSEvent.mouseEvent(with: .leftMouseDown, location: e.locationInWindow,
                                  modifierFlags: e.modifierFlags.subtracting([.shift, .command]),
                                  timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                  eventNumber: e.eventNumber, clickCount: 1, pressure: e.pressure) ?? e
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods.isEmpty, let column, let owner = column.owner {
            switch event.keyCode {
            case 123: owner.moveLeft(from: column); return
            case 124: owner.moveRight(from: column); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        column?.owner?.hideDropBadge()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        column?.owner?.hideDropBadge()
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        Theme.current.column.setFill()
        clipRect.fill()
    }
}

final class ColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var owner: ColumnsView?
    let folder: FileNode
    let index: Int
    private(set) var items: [FileNode] = []
    let table = FileTableView()
    private let tableScroll = NSScrollView()
    private let titleLabel = label("", size: 13, weight: .semibold)
    private let countLabel = label("", size: 10.5, color: .tertiaryLabelColor)
    private let header = DetailHeaderView()
    private let strip = StripView()
    private(set) var collapsed = false
    private var tracking: NSTrackingArea?

    var isDetailed = false {
        didSet {
            guard oldValue != isDetailed else { return }
            table.rowHeight = 24
            needsLayout = true
            table.reloadData()
            restoreSelection()
        }
    }
    private var savedSelection: Set<String> = []
    private(set) var filter = ""
    private var filterTokens: [String] = []
    private var allItems: [FileNode] = []
    private let filterPill = FilterPillView()

    /// The last (active) column carries the folder controls, like OneCommander.
    var isLast = false {
        didSet {
            guard oldValue != isLast else { return }
            if isLast { buildControls() }
            controlsRight?.isHidden = !isLast
            controlsLeft?.isHidden = !isLast
            needsLayout = true
            updateControls()
        }
    }
    private var controlsRight: NSStackView?
    private var controlsLeft: NSStackView?
    private var backBtn: NSButton?
    private var forwardBtn: NSButton?
    private var detailsBtn: NSButton?
    private var hiddenBtn: NSButton?
    private var sortBtn: NSPopUpButton?

    init(folder: FileNode, index: Int, owner: ColumnsView) {
        self.folder = folder
        self.index = index
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        countLabel.translatesAutoresizingMaskIntoConstraints = true
        countLabel.alignment = .right
        header.translatesAutoresizingMaskIntoConstraints = true
        header.isHidden = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.style = .plain
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.column = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.every, forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = true
        tableScroll.scrollerStyle = .overlay

        strip.isHidden = true
        strip.onClick = { [weak self] in
            guard let self else { return }
            self.owner?.stripClicked(self)
        }
        let path = folder.path
        header.onSort = { key in Prefs.shared.toggleSort(key, for: path) }
        header.sortState = { Prefs.shared.sort(for: path) }
        NotificationCenter.default.addObserver(self, selector: #selector(sortChanged(_:)), name: .folderSortChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(childrenLoaded), name: .folderChildrenLoaded, object: folder)

        filterPill.isHidden = true
        filterPill.onClear = { [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.setFilter("", in: self)
            owner.focus(column: self.index)
        }
        [tableScroll, titleLabel, countLabel, header, strip, filterPill].forEach { addSubview($0) }
        applyTheme()
        reloadItems()
    }

    func applyTheme() {
        let t = Theme.current
        titleLabel.font = Fonts.rounded(13.5, .semibold)
        titleLabel.textColor = t.text
        countLabel.font = Fonts.rounded(10.5, .medium)
        countLabel.textColor = t.tertiary
        table.backgroundColor = t.column
        tableScroll.backgroundColor = t.column
        needsDisplay = true
        header.needsDisplay = true
        strip.needsDisplay = true
        table.enumerateAvailableRowViews { rv, _ in
            rv.needsDisplay = true
            for v in rv.subviews { v.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let stripWidth: CGFloat = 24

    @objc private func childrenLoaded() {
        owner?.reload(changed: [folder.path])
    }

    @objc private func sortChanged(_ n: Notification) {
        guard (n.object as? String) == folder.path else { return }
        folder.resort()
        let p = owner?.programmatic ?? false
        owner?.programmatic = true
        reloadItems()
        owner?.programmatic = p
        header.needsDisplay = true
        updateControls()
    }

    private func buildControls() {
        guard controlsRight == nil else { return }
        func btn(_ sym: String, _ tip: String, _ cmd: ColumnCommand) -> NSButton {
            let b = ClosureButton(symbol: sym, tip: tip) { [weak self] in
                guard let self, let owner = self.owner else { return }
                owner.delegate?.columnsCommand(owner, cmd)
            }
            return b
        }
        let up = btn("arrow.up", L("Enclosing folder (⌘↑)"), .up)
        backBtn = btn("arrow.left", L("Back (⌘[)"), .back)
        forwardBtn = btn("arrow.right", L("Forward (⌘])"), .forward)
        let newFolder = btn("folder.badge.plus", L("New folder (F7)"), .newFolder)
        let left = NSStackView(views: [up, backBtn!, forwardBtn!, newFolder])
        left.spacing = 2
        left.translatesAutoresizingMaskIntoConstraints = true

        let sort = NSPopUpButton(frame: .zero, pullsDown: true)
        sort.isBordered = false
        sort.toolTip = L("Sorting for this folder")
        (sort.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        sort.widthAnchor.constraint(equalToConstant: 28).isActive = true
        sortBtn = sort
        detailsBtn = btn("list.bullet.rectangle", L("Details view"), .toggleDetails)
        hiddenBtn = btn("eye.slash", L("Hidden files (⌘⇧.)"), .toggleHidden)
        let reload = btn("arrow.clockwise", L("Reload (⌘R)"), .reload)
        let right = NSStackView(views: [sort, detailsBtn!, hiddenBtn!, reload])
        right.spacing = 2
        right.translatesAutoresizingMaskIntoConstraints = true
        controlsLeft = left
        controlsRight = right
        addSubview(left)
        addSubview(right)
    }

    func updateControls() {
        guard isLast, let owner else { return }
        let t = Theme.current
        let p = Prefs.shared
        let can = owner.delegate?.columnsCanGo(owner) ?? (back: false, forward: false)
        backBtn?.isEnabled = can.back
        forwardBtn?.isEnabled = can.forward
        for case let b as NSButton in (controlsLeft?.arrangedSubviews ?? []) + (controlsRight?.arrangedSubviews ?? []) {
            b.contentTintColor = t.secondary
        }
        detailsBtn?.contentTintColor = p.detailsView ? t.accent : t.secondary
        hiddenBtn?.image = NSImage(systemSymbolName: p.showHidden ? "eye" : "eye.slash", accessibilityDescription: nil)
        hiddenBtn?.contentTintColor = p.showHidden ? t.accent : t.secondary
        if let sortBtn {
            let path = folder.path
            let cur = p.sort(for: path)
            let m = NSMenu()
            let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            title.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: L("Sort"))
            m.addItem(title)
            for k in SortKey.allCases {
                let i = ClosureMenuItem(k.title) { Prefs.shared.setSort(k, ascending: cur.ascending, for: path) }
                i.state = cur.key == k ? .on : .off
                m.addItem(i)
            }
            m.addItem(.separator())
            let asc = ClosureMenuItem(L("Ascending")) { Prefs.shared.setSort(cur.key, ascending: true, for: path) }
            asc.state = cur.ascending ? .on : .off
            let desc = ClosureMenuItem(L("Descending")) { Prefs.shared.setSort(cur.key, ascending: false, for: path) }
            desc.state = cur.ascending ? .off : .on
            m.addItem(asc)
            m.addItem(desc)
            sortBtn.menu = m
            sortBtn.contentTintColor = cur.key == .name && cur.ascending ? t.secondary : t.accent
        }
    }

    func setCollapsed(_ c: Bool) {
        guard c != collapsed || strip.title != folder.name else { return }
        collapsed = c
        strip.title = folder.name
        strip.isHidden = !c
        tableScroll.isHidden = c
        titleLabel.isHidden = c
        countLabel.isHidden = c
        header.isHidden = c || !isLast
        controlsLeft?.isHidden = c || !isLast
        controlsRight?.isHidden = c || !isLast
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        strip.frame = bounds
        let titleH: CGFloat = 32
        var rightEdge = w - 10
        if isLast, let r = controlsRight {
            let s = r.fittingSize
            r.frame = NSRect(x: w - s.width - 8, y: 5, width: s.width, height: 22)
            rightEdge = r.frame.minX - 6
        }
        countLabel.frame = NSRect(x: rightEdge - 66, y: 11, width: 66, height: 14)
        titleLabel.frame = NSRect(x: 12, y: 8, width: max(0, rightEdge - 80), height: 18)
        var y = titleH
        if isLast && !collapsed {
            var inset: CGFloat = 0
            if let l = controlsLeft {
                let s = l.fittingSize
                l.frame = NSRect(x: 6, y: y + 1, width: s.width, height: 22)
                inset = l.frame.maxX + 8
            }
            header.leadingInset = inset
            header.frame = NSRect(x: 0, y: y, width: w, height: 24)
            header.isHidden = false
            header.showsLabels = isDetailed
            header.needsDisplay = true
            y += 24
        } else {
            header.isHidden = true
        }
        tableScroll.frame = NSRect(x: 0, y: y, width: w - 1, height: max(0, h - y))
        if !filterPill.isHidden {
            let pw = min(w - 20, max(180, filterPill.idealWidth))
            filterPill.frame = NSRect(x: (w - pw) / 2, y: h - 42, width: pw, height: 32)
        }
        table.sizeLastColumnToFit()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.column.setFill()
        bounds.fill()
        Theme.current.separator.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { owner?.hoverBegan(self) }
    override func mouseExited(with event: NSEvent) { owner?.hoverEnded(self) }

    // MARK: Data

    var selectedNodes: [FileNode] {
        table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    func reloadItems() {
        folder.loadChildrenAsync()
        // While a listing runs the table is empty; keep the selection that was asked for.
        let sel = allItems.isEmpty ? savedSelection : Set(selectedNodes.map(\.path))
        allItems = folder.children
        applyFilter()
        select(paths: Array(sel))
        titleLabel.stringValue = folder.name
        countLabel.toolTip = folder.loadError
    }

    private func applyFilter() {
        let folded = filterTokens.map(FileNode.fold)
        items = folded.isEmpty ? allItems : allItems.filter { n in
            let f = n.foldedName
            return folded.allSatisfy { f.range(of: $0, options: .literal) != nil }
        }
        table.reloadData()
        if folder.isLoading {
            countLabel.stringValue = allItems.isEmpty ? L("loading…") : L("%@ · refreshing…", Fmt.items(allItems.count))
        } else if folder.loadError != nil {
            countLabel.stringValue = L("no access")
        } else {
            countLabel.stringValue = filter.isEmpty ? Fmt.items(items.count) : "\(items.count)/\(allItems.count)"
        }
        filterPill.update(text: filter, matches: items.count, total: allItems.count)
        filterPill.isHidden = filter.isEmpty
        needsLayout = true
    }

    /// Filters the list; keeps the selection if still visible, else selects the first match.
    func setFilter(_ text: String) {
        let previous = Set(selectedNodes.map(\.path))
        filter = text
        filterTokens = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        applyFilter()
        let keep = items.indices.filter { previous.contains(items[$0].path) }
        if !keep.isEmpty {
            table.selectRowIndexes(IndexSet(keep), byExtendingSelection: false)
            table.scrollRowToVisible(keep[0])
        } else if !items.isEmpty && !filter.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        } else {
            table.deselectAll(nil)
        }
        savedSelection = Set(selectedNodes.map(\.path))
    }

    /// Case- and diacritic-insensitive; tries the neutral and the Turkish locale (i/İ, ı/I).
    static func matchRange(of token: String, in name: String, from start: String.Index? = nil) -> Range<String.Index>? {
        let range = (start ?? name.startIndex)..<name.endIndex
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return name.range(of: token, options: opts, range: range, locale: nil)
            ?? name.range(of: token, options: opts, range: range, locale: Locale(identifier: "tr_TR"))
    }

    func select(paths: [String]) {
        let set = Set(paths)
        let idx = IndexSet(items.indices.filter { set.contains(items[$0].path) })
        table.selectRowIndexes(idx, byExtendingSelection: false)
        if let f = idx.first { table.scrollRowToVisible(f) }
        savedSelection = set
    }

    private func restoreSelection() {
        let p = owner?.programmatic ?? false
        owner?.programmatic = true
        select(paths: Array(savedSelection))
        owner?.programmatic = p
    }

    func sizesUpdated(_ paths: Set<String>) {
        guard !collapsed else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for r in visible.location..<(visible.location + visible.length) where items.indices.contains(r) {
            if paths.contains(items[r].path) { table.view(atColumn: 0, row: r, makeIfNecessary: false)?.needsDisplay = true }
        }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        owner?.columnDoubleClicked(self)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? FileRowView) ?? {
            let v = FileRowView()
            v.identifier = id
            return v
        }()
        v.node = items.indices.contains(row) ? items[row] : nil
        v.detailed = isDetailed
        v.filterTokens = filterTokens
        v.needsDisplay = true
        return v
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items.indices.contains(row) ? items[row].name : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        savedSelection = Set(selectedNodes.map(\.path))
        owner?.columnSelectionChanged(self)
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        owner?.dragStarted = true
        return items.indices.contains(row) ? items[row].url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.dragStarted = false
        owner?.hideDropBadge()
        // Dropped outside the app (Finder, Desktop, another app) as a move: source is gone.
        if operation.contains(.move) || operation.contains(.delete) {
            folder.invalidate()
            owner?.reload(changed: [folder.path])
        }
    }

    private func dropTarget(row: Int, op: NSTableView.DropOperation) -> FileNode {
        if op == .on, items.indices.contains(row), items[row].isDirectory { return items[row] }
        return folder
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        let target = dropTarget(row: row, op: op)
        if target === folder { tableView.setDropRow(-1, dropOperation: .on) }
        let urls = ColumnsView.urls(info)
        var op: NSDragOperation = []
        if !target.isVirtual, !urls.isEmpty, !FileOps.isInvalidTarget(target.url, for: urls),
           !urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == target.path }) {
            op = ColumnsView.operation(info, move: ColumnsView.wantsMove())
        }
        owner?.showDropBadge(op, target: target, at: info.draggingLocation)
        return op
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = row < 0 ? folder : dropTarget(row: row, op: dropOperation)
        let urls = ColumnsView.urls(info)
        guard !urls.isEmpty, let owner else { return false }
        owner.hideDropBadge()
        owner.delegate?.columnsDrop(owner, urls: urls, to: target.url, move: ColumnsView.wantsMove())
        return true
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let owner else { return }
        let row = table.clickedRow
        var targets: [FileNode] = []
        if row >= 0, items.indices.contains(row) {
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            targets = selectedNodes
        }
        owner.columnFocused(self)
        owner.delegate?.columnsBuildMenu(owner, menu: menu, targets: targets, folder: folder)
    }
}

// MARK: - Row drawing

/// Shared geometry for the detailed list so header and rows line up.
struct DetailLayout {
    var name: NSRect.ClosedRange
    var ext: NSRect.ClosedRange?
    var age: NSRect.ClosedRange?
    var date: NSRect.ClosedRange?
    var size: NSRect.ClosedRange

    init(width w: CGFloat) {
        var right = w - 14
        size = (right - 74)...right
        right -= 80
        if w > 470 { date = (right - 74)...right; right -= 80 } else { date = nil }
        if w > 300 { age = (right - 36)...right; right -= 42 } else { age = nil }
        if w > 400 { ext = (right - 46)...right; right -= 50 } else { ext = nil }
        name = 32...max(33, right - 4)
    }
}

extension NSRect {
    typealias ClosedRange = Swift.ClosedRange<CGFloat>
}

final class FileRowView: NSTableCellView {
    var node: FileNode?
    var detailed = false
    var filterTokens: [String] = []

    static let nameFont = NSFont.systemFont(ofSize: 13)
    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let badgeFont = Fonts.rounded(10.5, .bold)
    private static let chevron: NSImage? = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let node else { return }
        let f = bounds
        let emph = backgroundStyle == .emphasized
        let t = Theme.current
        let text: NSColor = emph ? t.selectionText : t.text
        let secondary: NSColor = emph ? t.selectionText.withAlphaComponent(0.85) : t.secondary
        let alpha: CGFloat = node.isHiddenFile ? 0.5 : 1

        node.icon.draw(in: NSRect(x: 11, y: f.midY - 8, width: 16, height: 16),
                       from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)

        let small: [NSAttributedString.Key: Any] = [.font: Self.smallFont, .foregroundColor: secondary]
        var nameRight: CGFloat

        if detailed {
            let layout = DetailLayout(width: f.width)
            drawRight(node.sizeText, in: layout.size, attrs: small)
            if let d = layout.date { drawRight(Fmt.shortDateFormatter.string(from: node.modified ?? .distantPast), in: d, attrs: small) }
            if let a = layout.age, let (s, color) = Fmt.ageBadge(node.modified) { drawBadge(s, color: color, in: a, emph: emph) }
            if let e = layout.ext {
                let t = node.isDirectory ? "[DIR]" : (node.url.pathExtension.isEmpty ? "" : node.url.pathExtension.lowercased())
                drawLeft(t, in: e, attrs: small)
            }
            nameRight = layout.name.upperBound
        } else {
            var right = f.maxX - 12
            if node.isDirectory, let img = Self.chevron {
                let tinted = img.withSymbolConfiguration(.init(paletteColors: [emph ? t.selectionText : t.tertiary])) ?? img
                let s = tinted.size
                tinted.draw(in: NSRect(x: right - s.width, y: f.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                right -= s.width + 6
            }
            if f.width > 190 {
                let s = node.sizeText as NSString
                let sz = s.size(withAttributes: small)
                s.draw(at: NSPoint(x: right - sz.width, y: f.midY - sz.height / 2), withAttributes: small)
                right -= sz.width + 8
            }
            nameRight = right
        }

        let colors = NSWorkspace.shared.fileLabelColors
        if node.labelNumber > 0 && node.labelNumber < colors.count {
            let r = NSRect(x: nameRight - 9, y: f.midY - 4.5, width: 9, height: 9)
            colors[node.labelNumber].setFill()
            let p = NSBezierPath(ovalIn: r)
            p.fill()
            if emph { NSColor.white.setStroke(); p.stroke() }
            nameRight -= 14
        }

        if let img = Self.cloudImage(node.cloud, emph: emph) {
            let sz = img.size
            img.draw(in: NSRect(x: nameRight - sz.width, y: f.midY - sz.height / 2, width: sz.width, height: sz.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            nameRight -= sz.width + 6
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.nameFont, .foregroundColor: text.withAlphaComponent(alpha), .paragraphStyle: para,
        ]
        let h = ceil(Self.nameFont.ascender - Self.nameFont.descender) + 1
        let r = NSRect(x: 33, y: f.midY - h / 2, width: max(0, nameRight - 35), height: h)
        let str = NSMutableAttributedString(string: node.name, attributes: attrs)
        for token in filterTokens {
            var from = node.name.startIndex
            while let m = ColumnView.matchRange(of: token, in: node.name, from: from) {
                str.addAttribute(.backgroundColor, value: (emph ? NSColor.white : t.accent).withAlphaComponent(emph ? 0.3 : 0.28),
                                 range: NSRange(m, in: node.name))
                from = m.upperBound
                if from >= node.name.endIndex { break }
            }
        }
        str.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static var cloudCache: [String: NSImage] = [:]

    /// Tinted cloud-state badge (cached per state/theme/emphasis).
    static func cloudImage(_ state: Cloud.State, emph: Bool) -> NSImage? {
        guard let sym = Cloud.symbol(state) else { return nil }
        let key = "\(sym)|\(emph)|\(Theme.current.id)"
        if let i = cloudCache[key] { return i }
        let t = Theme.current
        let color: NSColor
        switch state {
        case _ where emph: color = t.selectionText
        case .conflict: color = .systemRed
        case .downloading, .uploading: color = t.accent
        default: color = t.secondary
        }
        let img = NSImage(systemSymbolName: sym, accessibilityDescription: Cloud.title(state))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(.init(paletteColors: [color])))
        cloudCache[key] = img
        return img
    }

    private func drawRight(_ s: String, in r: NSRect.ClosedRange, attrs: [NSAttributedString.Key: Any]) {
        let ns = s as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: NSPoint(x: r.upperBound - sz.width, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }

    private func drawLeft(_ s: String, in r: NSRect.ClosedRange, attrs: [NSAttributedString.Key: Any]) {
        let ns = s as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(with: NSRect(x: r.lowerBound, y: bounds.midY - sz.height / 2, width: r.upperBound - r.lowerBound, height: sz.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    private func drawBadge(_ s: String, color: NSColor, in r: NSRect.ClosedRange, emph: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: emph ? NSColor.white : color]
        let ns = s as NSString
        let sz = ns.size(withAttributes: attrs)
        let bw = max(sz.width + 10, 28)
        let box = NSRect(x: r.upperBound - bw, y: bounds.midY - 8, width: bw, height: 16)
        (emph ? NSColor.white.withAlphaComponent(0.22) : color.withAlphaComponent(Theme.current.isDark ? 0.24 : 0.16)).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        ns.draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2), withAttributes: attrs)
    }
}

/// Clickable column titles of the detailed list (sorts on click).
final class DetailHeaderView: NSView {
    var onSort: ((SortKey) -> Void)?
    var sortState: () -> (key: SortKey, ascending: Bool) = { (.name, true) }
    /// Room on the left for the navigation buttons.
    var leadingInset: CGFloat = 0
    var showsLabels = true
    override var isFlipped: Bool { true }

    private func parts() -> [(String, NSRect.ClosedRange, SortKey, Bool)] {
        let layout = DetailLayout(width: bounds.width)
        guard showsLabels else { return [] }
        let nameStart = max(layout.name.lowerBound, leadingInset)
        var p: [(String, NSRect.ClosedRange, SortKey, Bool)] = [(L("Name"), nameStart...max(nameStart + 1, layout.name.upperBound), .name, false)]
        if let e = layout.ext { p.append((L("Kind"), e, .kind, false)) }
        if let a = layout.age { p.append((L("Age"), a, .modified, true)) }
        if let d = layout.date { p.append((L("Date"), d, .modified, true)) }
        p.append((L("Size"), layout.size, .size, true))
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme.current
        theme.column.setFill()
        bounds.fill()
        theme.separator.setFill()
        NSRect(x: 10, y: bounds.maxY - 1, width: bounds.width - 20, height: 1).fill()
        let state = sortState()
        for (title, r, key, right) in parts() {
            let active = state.key == key && !(title == L("Age"))
            let t = title + (active ? (state.ascending ? " ▲" : " ▼") : "")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Fonts.rounded(10.5, active ? .bold : .medium),
                .foregroundColor: active ? theme.accent : theme.tertiary,
            ]
            let ns = t as NSString
            let sz = ns.size(withAttributes: attrs)
            let x = right ? r.upperBound - sz.width : r.lowerBound
            ns.draw(at: NSPoint(x: x, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        for (_, r, key, _) in parts() where r.contains(x) {
            onSort?(key)
            return
        }
    }
}

/// Thin strip shown for collapsed (ancestor) columns: the folder name written vertically.
final class StripView: NSView {
    static let font = Fonts.rounded(11.5, .semibold)
    var title = "" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme.current
        theme.strip.setFill()
        bounds.fill()
        theme.separator.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: theme.secondary, .paragraphStyle: para]
        let h = ceil(Self.font.ascender - Self.font.descender)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // flipped view: rotating -90° makes the text run bottom → top (book spine)
        ctx.translateBy(x: bounds.midX - h / 2, y: bounds.maxY - 10)
        ctx.rotate(by: -.pi / 2)
        (title as NSString).draw(with: NSRect(x: 0, y: 0, width: max(0, bounds.height - 20), height: h),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Floating label next to the cursor while dragging: "+ Kopyala" or "→ Taşı" and the target folder.
final class DropBadgeView: NSView {
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        text.font = .systemFont(ofSize: 12, weight: .semibold)
        text.textColor = .white
        icon.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        icon.contentTintColor = .white
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(move: Bool, target: String) {
        icon.image = NSImage(systemSymbolName: move ? "arrow.right.circle.fill" : "plus.circle.fill", accessibilityDescription: nil)
        text.stringValue = (move ? L("Move → ") : L("Copy → ")) + target
        layer?.backgroundColor = (move ? NSColor.systemOrange : NSColor.systemGreen).cgColor
    }
}

/// Small borderless symbol button running a closure.
final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = tip
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Floating search pill at the bottom of a filtered column: text, match count, clear button.
final class FilterPillView: NSView {
    var onClear: (() -> Void)?
    private var text = ""
    private var matches = 0
    private var total = 0
    private static let font = Fonts.rounded(13, .semibold)
    private static let countFont = Fonts.rounded(11.5, .medium)

    override var isFlipped: Bool { true }

    func update(text: String, matches: Int, total: Int) {
        self.text = text
        self.matches = matches
        self.total = total
        needsDisplay = true
    }

    var idealWidth: CGFloat {
        let tw = (text as NSString).size(withAttributes: [.font: Self.font]).width
        let cw = ("\(matches)/\(total)" as NSString).size(withAttributes: [.font: Self.countFont]).width
        return 34 + tw + 14 + cw + 34
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Theme.current
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
        sh.shadowBlurRadius = 6
        sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.set()
        (matches == 0 ? t.ageMinute : t.accent).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        let white = NSColor.white
        if let mag = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [white]))) {
            mag.draw(in: NSRect(x: 12, y: (bounds.height - mag.size.height) / 2, width: mag.size.width, height: mag.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let count = "\(matches)/\(total)" as NSString
        let cAttrs: [NSAttributedString.Key: Any] = [.font: Self.countFont, .foregroundColor: white.withAlphaComponent(0.8)]
        let cs = count.size(withAttributes: cAttrs)
        let closeX = bounds.maxX - 26
        count.draw(at: NSPoint(x: closeX - 8 - cs.width, y: (bounds.height - cs.height) / 2), withAttributes: cAttrs)

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingHead
        let tAttrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: white, .paragraphStyle: para]
        let th = ceil(Self.font.ascender - Self.font.descender)
        (text as NSString).draw(with: NSRect(x: 32, y: (bounds.height - th) / 2, width: max(0, closeX - 16 - cs.width - 32), height: th),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: tAttrs)

        if let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Clear filter"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [white.withAlphaComponent(0.85)]))) {
            x.draw(in: NSRect(x: closeX, y: (bounds.height - x.size.height) / 2, width: x.size.width, height: x.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x > bounds.maxX - 34 { onClear?() }
    }
}
