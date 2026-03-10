import Foundation

extension String {
    /// Returns a localized version of the string using standard macOS `NSLocalizedString`
    var localized: String {
        let preferredLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        var bundle = Bundle.main
        
        if preferredLanguage != "auto" {
            // User explicitly overrode the language
            if let path = Bundle.main.path(forResource: preferredLanguage, ofType: "lproj"),
               let langBundle = Bundle(path: path) {
                bundle = langBundle
            }
        } else {
            // In "auto" mode, if the system language is not Chinese, force English as the fallback
            // (preventing it from defaulting to Chinese if the app's base region is messed up)
            let sysLang = Locale.preferredLanguages.first ?? "en"
            if !sysLang.hasPrefix("zh") {
                if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
                   let langBundle = Bundle(path: path) {
                    bundle = langBundle
                }
            }
        }
        
        return NSLocalizedString(self, tableName: nil, bundle: bundle, value: "", comment: "")
    }
}
