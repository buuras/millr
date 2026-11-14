import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController!
    private var selfTest: SelfTest?
    private var stressTest: StressTest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        windowController = MainWindowController()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.didShow()
        NSApp.activate(ignoringOtherApps: true)
        FileWatcher.shared.start()
        Archives.cleanCache()
        scheduleDebugSnapshot()
    }

    /// Debug aid: `Millr --snapshot /path/out.png [--reveal /some/path]`
    /// writes the window contents to a PNG (no screen-recording permission needed).
    private func scheduleDebugSnapshot() {
        let args = CommandLine.arguments
        if let t = args.firstIndex(of: "--selftest"), t + 1 < args.count {
            let test = SelfTest(wc: windowController, root: URL(fileURLWithPath: args[t + 1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { test.run() }
            selfTest = test
            return
        }
        if let t = args.firstIndex(of: "--stress"), t + 2 < args.count {
            let test = StressTest(wc: windowController, a: URL(fileURLWithPath: args[t + 1]), b: URL(fileURLWithPath: args[t + 2]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { test.run() }
            stressTest = test
            return
        }
        if let p = args.firstIndex(of: "--palette"), p + 1 < args.count {
            let text = args[p + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.windowController.showCommandPalette(nil)
                self?.windowController.debugPaletteText(text)
            }
        }
        if let o = args.firstIndex(of: "--open"), o + 1 < args.count {
            let u = URL(fileURLWithPath: args[o + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let wc = self?.windowController else { return }
                if let f = SmartFolders.shared.folders.first(where: { $0.id == args[o + 1] }) {
                    wc.activePane.open(folder: SmartFolders.shared.url(for: f))
                } else {
                    wc.openItems([u], in: wc.activePane)
                }
            }
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = args[i + 1]
        if let t = args.firstIndex(of: "--theme"), t + 1 < args.count { Prefs.shared.themeID = args[t + 1] }
        if let r = args.firstIndex(of: "--reveal"), r + 1 < args.count {
            windowController.activePane.reveal(URL(fileURLWithPath: args[r + 1]))
        }
        if let s = args.firstIndex(of: "--shelf"), s + 1 < args.count {
            Shelf.shared.clear()
            Shelf.shared.add(args[s + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        }
        if let f = args.firstIndex(of: "--filter"), f + 1 < args.count {
            let text = args[f + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let cv = self?.windowController.activePane.columnsView, let c = cv.columns.last else { return }
                cv.setFilter(text, in: c)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let view = self?.windowController.window?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            for (k, child) in (self?.windowController.window?.childWindows ?? []).enumerated() {
                guard let v = child.contentView?.superview, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: r)
                try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".child\(k).png"))
            }
            if args.contains("--quit") { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveState()
        Archives.detachAll()
    }
}
