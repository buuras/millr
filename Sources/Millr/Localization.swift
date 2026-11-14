import AppKit

/// Localized UI text. The key is the English text; other languages live in
/// Resources/<lang>.lproj/Localizable.strings. English needs no table: a missing key is shown as is.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string: `L("%d selected", n)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Fmt.appLocale, arguments: args)
}

extension Fmt {
    /// The language the UI runs in (not the region), for dates and upper-casing.
    static let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    static func items(_ n: Int) -> String { n == 1 ? L("1 item") : L("%d items", n) }
}

/// The UI language chosen in the app. macOS reads `AppleLanguages` from the app's own defaults
/// at launch, so a change applies after a restart; without it the app follows the system.
enum AppLanguage {
    /// nil = follow macOS.
    static let options: [(code: String?, title: String)] = [(nil, L("System Default")), ("en", "English"), ("tr", "Türkçe")]

    static var chosen: String? {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (domain?["AppleLanguages"] as? [String])?.first
    }

    static func choose(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Starts a new instance of the app and quits this one.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
