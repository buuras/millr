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

        submenu("OC Commander", [
            item("OC Commander Hakkında", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("OC Commander'ı Gizle", #selector(NSApplication.hide(_:)), "h"),
            item("Diğerlerini Gizle", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Tümünü Göster", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("OC Commander'dan Çık", #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu("Dosya", [
            item("Yeni Sekme", #selector(W.newTab(_:)), "t"),
            item("Sekmeyi Kapat", #selector(W.closeTab(_:)), "w"),
            item("Sonraki Sekme", #selector(W.nextTab(_:)), "\t", .control),
            item("Önceki Sekme", #selector(W.previousTab(_:)), "\t", [.control, .shift]),
            .separator(),
            item("Yeni Klasör", #selector(W.newFolder(_:)), "n", [.command, .shift]),
            item("Yeni Metin Dosyası", #selector(W.newTextFile(_:)), "n", [.command, .option]),
            .separator(),
            item("Aç", #selector(W.openSelection(_:)), down),
            item("Yeniden Adlandır (F2)", #selector(W.renameSelection(_:))),
            item("Çoğalt", #selector(W.duplicateSelection(_:)), "d"),
            item("Sıkıştır (.zip)", #selector(W.compressSelection(_:))),
            .separator(),
            item("Diğer Panele Kopyala (F5)", #selector(W.copyToOtherPane(_:)), "5", [.command, .shift]),
            item("Diğer Panele Taşı (F6)", #selector(W.moveToOtherPane(_:)), "6", [.command, .shift]),
            .separator(),
            item("Finder'da Göster", #selector(W.revealInFinder(_:)), "r", [.command, .shift]),
            item("Terminalde Aç", #selector(W.openTerminalHere(_:)), "t", [.command, .option]),
            item("Yolu Kopyala", #selector(W.copyPath(_:)), "c", [.command, .option]),
            item("İlk Gruba Ekle", #selector(W.addToFavorites(_:)), "t", [.command, .control]),
            item("Rafa Ekle", #selector(W.addToShelf(_:)), "d", [.command, .shift]),
            .separator(),
            item("Çöp Sepetine Taşı", #selector(W.moveToTrash(_:)), backspace),
        ])

        submenu("Düzen", [
            item("Geri Al", Selector(("undo:")), "z"),
            item("Yinele", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Kes", #selector(NSText.cut(_:)), "x"),
            item("Kopyala", #selector(NSText.copy(_:)), "c"),
            item("Yapıştır", #selector(NSText.paste(_:)), "v"),
            item("Öğeyi Buraya Taşı", #selector(W.moveHere(_:)), "v", [.command, .option]),
            item("Tümünü Seç", #selector(NSText.selectAll(_:)), "a"),
        ])

        let sortItems = SortKey.allCases.map { k in item(k.title, #selector(W.sortBy(_:)), tag: k.rawValue) }
        let sortTop = NSMenuItem(title: "Sıralama", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        sortItems.forEach { sortMenu.addItem($0) }
        sortTop.submenu = sortMenu

        submenu("Görünüm", [
            item("Kenar Çubuğu", #selector(W.toggleSidebarPanel(_:)), "s", [.command, .option]),
            item("Önizleme Paneli", #selector(W.togglePreview(_:)), "p", [.command, .option]),
            item("Çift Panel", #selector(W.toggleDualPane(_:)), "d", [.command, .option]),
            item("Üst-Alt Yerleşim (kapalıysa yan yana)", #selector(W.toggleLayout(_:)), "l", [.command, .option]),
            item("Panelleri Değiştir", #selector(W.swapPanes(_:)), "u", [.command, .option]),
            item("Diğer Panelde Aynı Klasör", #selector(W.sameFolderInOther(_:)), "=", [.command, .option]),
            .separator(),
            {
                let top = NSMenuItem(title: "Tema", action: nil, keyEquivalent: "")
                let m = NSMenu()
                for (i, t) in Theme.all.enumerated() { m.addItem(item(t.name, #selector(W.setTheme(_:)), tag: i)) }
                top.submenu = m
                return top
            }(),
            item("Gizli Dosyaları Göster", #selector(W.toggleHidden(_:)), ".", [.command, .shift]),
            sortTop,
            .separator(),
            item("Hızlı Bakış", #selector(W.toggleQuickLook(_:)), "y"),
            item("Yenile", #selector(W.reload(_:)), "r"),
            .separator(),
            item("Tam Ekran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        func place(_ title: String, _ path: String, _ key: String, _ mods: NSEvent.ModifierFlags = [.command, .shift]) -> NSMenuItem {
            let i = item(title, #selector(W.goToPlace(_:)), key, mods)
            i.representedObject = path
            return i
        }
        submenu("Git", [
            item("Geri", #selector(W.goBack(_:)), "["),
            item("İleri", #selector(W.goForward(_:)), "]"),
            item("Üst Klasör", #selector(W.goUp(_:)), up),
            item("Diğer Panele Geç (Tab)", #selector(W.focusSwitch(_:))),
            .separator(),
            place("Ev", "~", "h"),
            place("Masaüstü", "~/Desktop", "d"),
            place("Belgeler", "~/Documents", "o"),
            place("İndirilenler", "~/Downloads", "l", [.command, .option]),
            place("Uygulamalar", "/Applications", "a"),
            place("Bilgisayar (/)", "/", "c"),
            .separator(),
            item("Klasöre Git…", #selector(W.goToFolder(_:)), "g", [.command, .shift]),
            item("Komut Paleti…", #selector(W.showCommandPalette(_:)), "k"),
            recentItem(),
            .separator(),
            item("Yeni Akıllı Klasör…", #selector(W.newSmartFolder(_:)), "n", [.command, .control]),
        ])

        submenu("Pencere", [
            item("Küçült", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Büyüt", #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }

    private static let recentDelegate = RecentMenuDelegate()

    /// "Son Klasörler ▸" filled from the visit history each time it opens.
    private static func recentItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Son Klasörler", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Son Klasörler")
        m.delegate = recentDelegate
        item.submenu = m
        return item
    }
}

private final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = History.shared.recent(limit: 20)
        if recent.isEmpty { menu.addItem(NSMenuItem(title: "Geçmiş boş", action: nil, keyEquivalent: "")) }
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
