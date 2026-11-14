import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            main.addItem(top)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let backspace = "\u{8}"
        let W = MainWindowController.self

        submenu("Millr", [
            item(L("About Millr"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(L("Hide Millr"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Quit Millr"), #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu(L("File"), [
            item(L("New Tab"), #selector(W.newTab(_:)), "t"),
            item(L("Close Tab"), #selector(W.closeTab(_:)), "w"),
            item(L("Next Tab"), #selector(W.nextTab(_:)), "\t", .control),
            item(L("Previous Tab"), #selector(W.previousTab(_:)), "\t", [.control, .shift]),
            .separator(),
            item(L("New Folder"), #selector(W.newFolder(_:)), "n", [.command, .shift]),
            item(L("New Text File"), #selector(W.newTextFile(_:)), "n", [.command, .option]),
            .separator(),
            item(L("Open"), #selector(W.openSelection(_:)), down),
            item(L("Rename (F2)"), #selector(W.renameSelection(_:))),
            item(L("Duplicate"), #selector(W.duplicateSelection(_:)), "d"),
            item(L("Compress (.zip)"), #selector(W.compressSelection(_:))),
            .separator(),
            item(L("Copy to Other Pane (F5)"), #selector(W.copyToOtherPane(_:)), "5", [.command, .shift]),
            item(L("Move to Other Pane (F6)"), #selector(W.moveToOtherPane(_:)), "6", [.command, .shift]),
            .separator(),
            item(L("Show in Finder"), #selector(W.revealInFinder(_:)), "r", [.command, .shift]),
            item(L("Open in Terminal"), #selector(W.openTerminalHere(_:)), "t", [.command, .option]),
            item(L("Copy Path"), #selector(W.copyPath(_:)), "c", [.command, .option]),
            item(L("Add to First Group"), #selector(W.addToFavorites(_:)), "t", [.command, .control]),
            item(L("Add to Shelf"), #selector(W.addToShelf(_:)), "d", [.command, .shift]),
            .separator(),
            item(L("Move to Trash"), #selector(W.moveToTrash(_:)), backspace),
        ])

        submenu(L("Edit"), [
            item(L("Undo"), Selector(("undo:")), "z"),
            item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Move Item Here"), #selector(W.moveHere(_:)), "v", [.command, .option]),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
        ])

        let sortItems = SortKey.allCases.map { k in item(k.title, #selector(W.sortBy(_:)), tag: k.rawValue) }
        let sortTop = NSMenuItem(title: L("Sort"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        sortItems.forEach { sortMenu.addItem($0) }
        sortTop.submenu = sortMenu

        submenu(L("View"), [
            item(L("Sidebar"), #selector(W.toggleSidebarPanel(_:)), "s", [.command, .option]),
            item(L("Preview Pane"), #selector(W.togglePreview(_:)), "p", [.command, .option]),
            item(L("Dual Pane"), #selector(W.toggleDualPane(_:)), "d", [.command, .option]),
            item(L("Stacked Layout (side by side when off)"), #selector(W.toggleLayout(_:)), "l", [.command, .option]),
            item(L("Swap Panes"), #selector(W.swapPanes(_:)), "u", [.command, .option]),
            item(L("Same Folder in Other Pane"), #selector(W.sameFolderInOther(_:)), "=", [.command, .option]),
            .separator(),
            {
                let top = NSMenuItem(title: L("Theme"), action: nil, keyEquivalent: "")
                let m = NSMenu()
                for (i, t) in Theme.all.enumerated() { m.addItem(item(t.name, #selector(W.setTheme(_:)), tag: i)) }
                top.submenu = m
                return top
            }(),
            {
                let top = NSMenuItem(title: L("Language"), action: nil, keyEquivalent: "")
                let m = NSMenu()
                for (i, o) in AppLanguage.options.enumerated() { m.addItem(item(o.title, #selector(W.setLanguage(_:)), tag: i)) }
                top.submenu = m
                return top
            }(),
            item(L("Show Hidden Files"), #selector(W.toggleHidden(_:)), ".", [.command, .shift]),
            sortTop,
            .separator(),
            item(L("Quick Look"), #selector(W.toggleQuickLook(_:)), "y"),
            item(L("Reload"), #selector(W.reload(_:)), "r"),
            .separator(),
            item(L("Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        func place(_ title: String, _ path: String, _ key: String, _ mods: NSEvent.ModifierFlags = [.command, .shift]) -> NSMenuItem {
            let i = item(title, #selector(W.goToPlace(_:)), key, mods)
            i.representedObject = path
            return i
        }
        submenu(L("Go"), [
            item(L("Back"), #selector(W.goBack(_:)), "["),
            item(L("Forward"), #selector(W.goForward(_:)), "]"),
            item(L("Enclosing Folder"), #selector(W.goUp(_:)), up),
            item(L("Switch to Other Pane (Tab)"), #selector(W.focusSwitch(_:))),
            .separator(),
            place(L("Home"), "~", "h"),
            place(L("Desktop"), "~/Desktop", "d"),
            place(L("Documents"), "~/Documents", "o"),
            place(L("Downloads"), "~/Downloads", "l", [.command, .option]),
            place(L("Applications"), "/Applications", "a"),
            place(L("Computer (/)"), "/", "c"),
            .separator(),
            item(L("Go to Folder…"), #selector(W.goToFolder(_:)), "g", [.command, .shift]),
            item(L("Command Palette…"), #selector(W.showCommandPalette(_:)), "k"),
            recentItem(),
            .separator(),
            item(L("New Smart Folder…"), #selector(W.newSmartFolder(_:)), "n", [.command, .control]),
        ])

        submenu(L("Window"), [
            item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("Zoom"), #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }

    private static let recentDelegate = RecentMenuDelegate()

    /// "Son Klasörler ▸" filled from the visit history each time it opens.
    private static func recentItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Recent Folders"), action: nil, keyEquivalent: "")
        let m = NSMenu(title: L("Recent Folders"))
        m.delegate = recentDelegate
        item.submenu = m
        return item
    }
}

private final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = History.shared.recent(limit: 20)
        if recent.isEmpty { menu.addItem(NSMenuItem(title: L("No history"), action: nil, keyEquivalent: "")) }
        for u in recent {
            let i = NSMenuItem(title: FileManager.default.displayName(atPath: u.path),
                               action: #selector(MainWindowController.openRecent(_:)), keyEquivalent: "")
            i.representedObject = u
            i.toolTip = u.path
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            i.image = icon
            menu.addItem(i)
        }
    }
}
