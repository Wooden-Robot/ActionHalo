import Foundation

#if SWIFT_PACKAGE
private let currentBundle = Bundle.module
#else
private let currentBundle = Bundle.main
#endif

extension String {
    /// Returns a localized version of the string using standard macOS `NSLocalizedString`
    var localized: String {
        let preferredLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        var bundle = currentBundle
        
        if preferredLanguage != "auto" {
            // User explicitly overrode the language
            var resolvedLangBundle: Bundle? = nil
            let pathsToTry = [
                currentBundle.bundlePath + "/Contents/Resources/\(preferredLanguage).lproj",
                currentBundle.bundlePath + "/\(preferredLanguage).lproj",
                currentBundle.bundlePath + "/\(preferredLanguage.lowercased()).lproj"
            ]
            for path in pathsToTry {
                if FileManager.default.fileExists(atPath: path), let lb = Bundle(path: path) {
                    resolvedLangBundle = lb
                    break
                }
            }
            if let lb = resolvedLangBundle {
                bundle = lb
            }
        } else {
            // In "auto" mode, if the system language is not Chinese, force English as the fallback
            // (preventing it from defaulting to Chinese if the app's base region is messed up)
            let sysLang = Locale.preferredLanguages.first ?? "en"
            if !sysLang.hasPrefix("zh") {
                let enPaths = [
                    currentBundle.bundlePath + "/Contents/Resources/en.lproj",
                    currentBundle.bundlePath + "/en.lproj"
                ]
                for path in enPaths {
                    if FileManager.default.fileExists(atPath: path), let lb = Bundle(path: path) {
                        bundle = lb
                        break
                    }
                }
            }
        }
        
        return NSLocalizedString(self, tableName: nil, bundle: bundle, value: "", comment: "")
    }
}
