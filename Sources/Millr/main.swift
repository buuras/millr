import AppKit

// The app was called OC Commander (bundle id com.bugras.occommander) before; carry its
// settings (favorites, history, sort orders) over once.
if let id = Bundle.main.bundleIdentifier, id != "com.bugras.occommander",
   UserDefaults.standard.persistentDomain(forName: id)?.isEmpty ?? true,
   let old = UserDefaults.standard.persistentDomain(forName: "com.bugras.occommander") {
    UserDefaults.standard.setPersistentDomain(old, forName: id)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
