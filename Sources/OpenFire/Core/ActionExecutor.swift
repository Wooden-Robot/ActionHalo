import Cocoa

/// Executes built-in actions on selected text
final class ActionExecutor {
    
    static let shared = ActionExecutor()
    
    private init() {}
    
    /// Execute a built-in menu action with the given text
    func execute(action: BuiltInAction, text: String) {
        switch action {
        case .copy:
            simulateKeyCombo(key: .c, modifiers: .maskCommand)
        case .cut:
            simulateKeyCombo(key: .x, modifiers: .maskCommand)
        case .paste:
            simulateKeyCombo(key: .v, modifiers: .maskCommand)
        case .search:
            searchGoogle(text)
        case .translate:
            translateText(text)
        case .dictionary:
            lookUpInDictionary(text)
        case .openURL:
            openURL(text)
        }
    }
    
    // MARK: - Actions

    
    private func searchGoogle(_ text: String) {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
    
    private func translateText(_ text: String) {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.google.com/?sl=auto&tl=zh-CN&text=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
    
    private func lookUpInDictionary(_ text: String) {
        // Open in macOS Dictionary app via dict:// URL scheme
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "dict://\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openURL(_ text: String) {
        var urlString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Add https:// if no scheme present
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }
        
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Key Simulation
    
    /// Simulate a keyboard shortcut
    func simulateKeyCombo(key: CGKeyCode, modifiers: CGEventFlags) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        
        keyDown?.flags = modifiers
        keyUp?.flags = modifiers
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - Built-in Action Type

enum BuiltInAction: String, CaseIterable {
    case copy = "copy"
    case cut = "cut"
    case paste = "paste"
    case search = "search"
    case translate = "translate"
    case dictionary = "dictionary"
    case openURL = "openURL"
    
    var title: String {
        switch self {
        case .copy: return "Copy".localized
        case .cut: return "Cut".localized
        case .paste: return "Paste".localized
        case .search: return "Search".localized
        case .translate: return "Translate".localized
        case .dictionary: return "Dictionary".localized
        case .openURL: return "Open URL".localized
        }
    }
    
    var iconName: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        case .paste: return "doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .translate: return "globe"
        case .dictionary: return "book"
        case .openURL: return "link"
        }
    }
}

// MARK: - CGKeyCode Constants

extension CGKeyCode {
    static let c: CGKeyCode = 0x08
    static let x: CGKeyCode = 0x07
    static let v: CGKeyCode = 0x09
    static let p: CGKeyCode = 0x23
    static let a: CGKeyCode = 0x00
}
