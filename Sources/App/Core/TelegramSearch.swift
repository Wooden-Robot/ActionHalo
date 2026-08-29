import Cocoa
import ApplicationServices

enum TelegramSearchInputMethod: Hashable, Equatable, Sendable {
    case accessibility
    case unicodeEvent
    case clipboard
}

enum TelegramSearchVerification: Equatable, Sendable {
    case accessibility
    case clipboardReadback
}

struct TelegramSearchReceipt: Equatable, Sendable {
    let inputMethod: TelegramSearchInputMethod
    let verification: TelegramSearchVerification
}

struct TelegramSearchFailure: Error, Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case validate
        case open
        case input
        case verify
    }

    enum Reason: Equatable, Sendable {
        case invalidQuery
        case busy
        case applicationUnavailable
        case permissionDenied
        case activationTimedOut
        case targetChanged
        case inputUnavailable
        case clipboardUnavailable
        case clipboardContended
        case textMismatch
    }

    enum Effect: Equatable, Sendable {
        case none
        case queryMayHaveBeenApplied
    }

    let stage: Stage
    let reason: Reason
    let effect: Effect
}

enum TelegramSearchOpenResult: Equatable, Sendable {
    case ready
    case failed(TelegramSearchFailure.Reason)
}

enum TelegramSearchDeliveryResult: Equatable, Sendable {
    case delivered
    case unavailable
    case failed(TelegramSearchFailure.Reason)
}

struct TelegramSearchReadback: Equatable, Sendable {
    let text: String
    let verification: TelegramSearchVerification
}

@MainActor
protocol TelegramSearchDesktopPort: AnyObject {
    func openGlobalSearch() async -> TelegramSearchOpenResult
    func replaceQuery(
        _ query: String,
        using method: TelegramSearchInputMethod
    ) async -> TelegramSearchDeliveryResult
    func readQuery() async -> TelegramSearchReadback?
}

/// Owns Telegram search orchestration and makes success mean that the query was
/// observed in Telegram, rather than merely that an automation command returned.
@MainActor
final class TelegramSearch {
    static let shared = TelegramSearch(port: MacOSTelegramSearchAdapter())

    private let port: TelegramSearchDesktopPort
    private var isSearching = false

    init(port: TelegramSearchDesktopPort) {
        self.port = port
    }

    func search(
        _ query: String
    ) async -> Result<TelegramSearchReceipt, TelegramSearchFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              query.utf8.count <= 16 * 1024,
              !query.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return .failure(
                TelegramSearchFailure(
                    stage: .validate,
                    reason: .invalidQuery,
                    effect: .none
                )
            )
        }
        guard !isSearching else {
            return .failure(
                TelegramSearchFailure(
                    stage: .validate,
                    reason: .busy,
                    effect: .none
                )
            )
        }

        isSearching = true
        defer { isSearching = false }

        switch await port.openGlobalSearch() {
        case .ready:
            break
        case .failed(let reason):
            return .failure(
                TelegramSearchFailure(stage: .open, reason: reason, effect: .none)
            )
        }

        var queryMayHaveBeenApplied = false
        for method in TelegramSearchInputMethod.allMethods {
            switch await port.replaceQuery(query, using: method) {
            case .unavailable:
                continue
            case .failed(let reason):
                return .failure(
                    TelegramSearchFailure(
                        stage: .input,
                        reason: reason,
                        effect: queryMayHaveBeenApplied ? .queryMayHaveBeenApplied : .none
                    )
                )
            case .delivered:
                queryMayHaveBeenApplied = true
                if let readback = await port.readQuery(), readback.text == query {
                    return .success(
                        TelegramSearchReceipt(
                            inputMethod: method,
                            verification: readback.verification
                        )
                    )
                }
            }
        }

        if queryMayHaveBeenApplied {
            return .failure(
                TelegramSearchFailure(
                    stage: .verify,
                    reason: .textMismatch,
                    effect: .queryMayHaveBeenApplied
                )
            )
        }
        return .failure(
            TelegramSearchFailure(
                stage: .input,
                reason: .inputUnavailable,
                effect: .none
            )
        )
    }
}

private extension TelegramSearchInputMethod {
    static let allMethods: [TelegramSearchInputMethod] = [
        .accessibility,
        .unicodeEvent,
        .clipboard,
    ]
}

/// The only macOS seam for Telegram search. It deliberately avoids
/// keyboard-layout-dependent characters, fixed window coordinates, and AppleScript.
@MainActor
final class MacOSTelegramSearchAdapter: TelegramSearchDesktopPort {
    private static let telegramBundleIdentifier = "ru.keepcoder.Telegram"
    private static let globalSearchURL = URL(string: "tg://chats/search")!
    private static let globalSearchMenuItemIdentifier = "aMa-rb-kjV"
    private static let globalSearchMenuItemTitles: Set<String> = [
        "Global Search",
        "全局搜索",
        "全局搜尋",
        "全域搜尋",
        "Глобальный поиск",
        "Globale Suche",
        "Recherche globale",
        "Búsqueda global",
        "グローバル検索",
        "전체 검색",
    ]
    private static let maximumAXNodes = 240

    private var application: NSRunningApplication?
    private var searchField: AXUIElement?

    func openGlobalSearch() async -> TelegramSearchOpenResult {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.telegramBundleIdentifier
        ) != nil else {
            return .failed(.applicationUnavailable)
        }
        guard NSWorkspace.shared.open(Self.globalSearchURL) else {
            return .failed(.applicationUnavailable)
        }

        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let runningApplication = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.telegramBundleIdentifier
            ).first {
                application = runningApplication
                _ = runningApplication.activate(options: [.activateIgnoringOtherApps])
                if NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                    runningApplication.processIdentifier {
                    await settle(for: 0.20)
                    guard AXIsProcessTrusted() else {
                        return .failed(.permissionDenied)
                    }
                    guard pressGlobalSearchMenuItem(
                        processIdentifier: runningApplication.processIdentifier
                    ) else {
                        return .failed(.inputUnavailable)
                    }
                    await settle(for: 0.22)
                    searchField = locateSearchField(
                        processIdentifier: runningApplication.processIdentifier
                    )
                    return .ready
                }
            }
            await settle(for: 0.05)
        } while Date() < deadline

        return .failed(.activationTimedOut)
    }

    private func pressGlobalSearchMenuItem(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let menuBar = elementAttribute(
            kAXMenuBarAttribute,
            from: applicationElement
        ) else {
            return false
        }

        var queue = [menuBar]
        var index = 0
        while index < queue.count, index < Self.maximumAXNodes {
            let element = queue[index]
            index += 1

            let identifier = stringAttribute(kAXIdentifierAttribute, from: element)
            let title = stringAttribute(kAXTitleAttribute, from: element)
            if identifier == Self.globalSearchMenuItemIdentifier ||
                title.map(Self.globalSearchMenuItemTitles.contains) == true {
                return AXUIElementPerformAction(
                    element,
                    kAXPressAction as CFString
                ) == .success
            }

            if queue.count < Self.maximumAXNodes {
                queue.append(contentsOf: elementChildren(of: element).prefix(
                    Self.maximumAXNodes - queue.count
                ))
            }
        }
        return false
    }

    func replaceQuery(
        _ query: String,
        using method: TelegramSearchInputMethod
    ) async -> TelegramSearchDeliveryResult {
        guard let processIdentifier = activeTelegramProcessIdentifier() else {
            return .failed(.targetChanged)
        }

        switch method {
        case .accessibility:
            guard AXIsProcessTrusted() else { return .unavailable }
            let field = searchField ?? locateSearchField(processIdentifier: processIdentifier)
            guard let field, isWritableTextElement(field) else { return .unavailable }
            _ = AXUIElementSetAttributeValue(
                field,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            guard AXUIElementSetAttributeValue(
                field,
                kAXValueAttribute as CFString,
                query as CFString
            ) == .success else {
                return .unavailable
            }
            searchField = field
            await settle(for: 0.08)
            return .delivered

        case .unicodeEvent:
            postKey(
                keyCode: 0x00,
                flags: .maskCommand,
                processIdentifier: processIdentifier
            )
            await settle(for: 0.03)
            guard postUnicode(query, processIdentifier: processIdentifier) else {
                return .unavailable
            }
            await settle(for: 0.15)
            return .delivered

        case .clipboard:
            return await pasteQuery(query, processIdentifier: processIdentifier)
        }
    }

    func readQuery() async -> TelegramSearchReadback? {
        guard let processIdentifier = activeTelegramProcessIdentifier() else { return nil }

        if let field = searchField ?? locateSearchField(processIdentifier: processIdentifier),
           let value = stringAttribute(kAXValueAttribute, from: field) {
            searchField = field
            return TelegramSearchReadback(text: value, verification: .accessibility)
        }

        guard let copiedText = await copyFocusedQuery(
            processIdentifier: processIdentifier
        ) else {
            return nil
        }
        return TelegramSearchReadback(
            text: copiedText,
            verification: .clipboardReadback
        )
    }

    private func activeTelegramProcessIdentifier() -> pid_t? {
        guard let application,
              !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                application.processIdentifier else {
            return nil
        }
        return application.processIdentifier
    }

    private func locateSearchField(processIdentifier: pid_t) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)

        if let focused = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: applicationElement
        ), isWritableTextElement(focused) {
            return focused
        }

        var queue = elementChildren(of: applicationElement)
        var index = 0
        var bestCandidate: (element: AXUIElement, score: Int)?

        while index < queue.count, index < Self.maximumAXNodes {
            let element = queue[index]
            index += 1

            if isWritableTextElement(element) {
                let score = searchFieldScore(element)
                if score > (bestCandidate?.score ?? 0) {
                    bestCandidate = (element, score)
                }
            }
            if queue.count < Self.maximumAXNodes {
                queue.append(contentsOf: elementChildren(of: element).prefix(
                    Self.maximumAXNodes - queue.count
                ))
            }
        }

        return (bestCandidate?.score ?? 0) > 0 ? bestCandidate?.element : nil
    }

    private func searchFieldScore(_ element: AXUIElement) -> Int {
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        if subrole == kAXSearchFieldSubrole as String { return 100 }

        let metadataAttributes: [String] = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXIdentifierAttribute,
            kAXPlaceholderValueAttribute,
        ]
        let metadata = metadataAttributes.compactMap {
            stringAttribute($0, from: element)?.lowercased()
        }.joined(separator: " ")
        let searchTerms = ["search", "搜索", "搜尋", "поиск", "suche", "recherche"]
        if searchTerms.contains(where: metadata.contains) { return 80 }
        return 0
    }

    private func isWritableTextElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String else {
            return false
        }
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    private func elementChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success, let children = value as? [AnyObject] else {
            return []
        }
        return children.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(child, to: AXUIElement.self)
        }
    }

    private func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func postKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        processIdentifier: pid_t
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.postToPid(processIdentifier)
        up?.postToPid(processIdentifier)
    }

    private func postUnicode(_ text: String, processIdentifier: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }

        for offset in stride(from: 0, to: units.count, by: 20) {
            let end = min(offset + 20, units.count)
            var chunk = Array(units[offset..<end])
            guard let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                return false
            }
            chunk.withUnsafeMutableBufferPointer { buffer in
                down.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                up.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            down.postToPid(processIdentifier)
            up.postToPid(processIdentifier)
        }
        return true
    }

    private func pasteQuery(
        _ query: String,
        processIdentifier: pid_t
    ) async -> TelegramSearchDeliveryResult {
        let pasteboard = NSPasteboard.general
        guard let snapshot = AccessibilityManager.capturePasteboardSnapshot(from: pasteboard),
              stablePasteboardState(pasteboard) != nil else {
            return .failed(.clipboardUnavailable)
        }
        defer { snapshot.discardTemporaryFiles() }

        pasteboard.clearContents()
        guard pasteboard.setString(query, forType: .string),
              let ownedState = stablePasteboardState(pasteboard) else {
            _ = AccessibilityManager.restorePasteboardSnapshot(snapshot, to: pasteboard)
            return .failed(.clipboardUnavailable)
        }

        postKey(keyCode: 0x00, flags: .maskCommand, processIdentifier: processIdentifier)
        await settle(for: 0.02)
        postKey(keyCode: 0x09, flags: .maskCommand, processIdentifier: processIdentifier)
        await settle(for: 0.35)

        guard AccessibilityManager.restorePasteboardSnapshot(
            snapshot,
            to: pasteboard,
            ifCurrentStateMatches: ownedState
        ) else {
            return .failed(.clipboardContended)
        }
        return .delivered
    }

    private func copyFocusedQuery(processIdentifier: pid_t) async -> String? {
        let pasteboard = NSPasteboard.general
        guard let snapshot = AccessibilityManager.capturePasteboardSnapshot(from: pasteboard),
              let initialState = stablePasteboardState(pasteboard) else {
            return nil
        }
        defer { snapshot.discardTemporaryFiles() }

        postKey(keyCode: 0x00, flags: .maskCommand, processIdentifier: processIdentifier)
        await settle(for: 0.02)
        postKey(keyCode: 0x08, flags: .maskCommand, processIdentifier: processIdentifier)

        var copiedState: AccessibilityManager.PasteboardState?
        for _ in 0..<12 {
            await settle(for: 0.025)
            guard let state = stablePasteboardState(pasteboard) else { continue }
            if state.changeCount != initialState.changeCount, state.string != nil {
                copiedState = state
                break
            }
        }
        guard let copiedState else { return nil }

        let copiedText = copiedState.string
        _ = AccessibilityManager.restorePasteboardSnapshot(
            snapshot,
            to: pasteboard,
            ifCurrentStateMatches: copiedState
        )
        return copiedText
    }

    private func stablePasteboardState(
        _ pasteboard: NSPasteboard
    ) -> AccessibilityManager.PasteboardState? {
        AccessibilityManager.stablePasteboardState(
            readChangeCount: { pasteboard.changeCount },
            readString: { pasteboard.string(forType: .string) }
        )
    }

    private func settle(for seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
