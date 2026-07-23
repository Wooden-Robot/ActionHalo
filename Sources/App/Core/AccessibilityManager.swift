import Cocoa
import ApplicationServices
import Carbon

final class CopyFallbackRequestCoordinator {
    private let lock = NSLock()
    private var activeRequestID: UUID?

    func beginRequest() -> UUID {
        lock.lock()
        defer { lock.unlock() }

        let requestID = UUID()
        activeRequestID = requestID
        return requestID
    }

    func isRequestActive(_ requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestID == requestID
    }

    func cancelRequest(_ requestID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if activeRequestID == requestID {
            activeRequestID = nil
        }
    }

    func completeRequestIfActive(_ requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        return true
    }

    func cancelActiveRequest() {
        lock.lock()
        defer { lock.unlock() }
        activeRequestID = nil
    }
}

private enum PasteboardSnapshotPayload {
    case memory(Data)
    case file(URL)
}

private final class PasteboardSnapshotFileStore {
    let directoryURL: URL

    private let fileManager: FileManager
    private let cleanupLock = NSLock()
    private var isCleanedUp = false

    init?(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "OpenFire-Pasteboard-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
    }

    func store(_ data: Data) -> URL? {
        let fileURL = directoryURL.appendingPathComponent(UUID().uuidString)
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    func cleanup() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        guard !isCleanedUp else { return }
        isCleanedUp = true
        try? fileManager.removeItem(at: directoryURL)
    }

    deinit {
        cleanup()
    }
}

private final class PasteboardSnapshotDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let filesByType: [NSPasteboard.PasteboardType: URL]
    private let fileStore: PasteboardSnapshotFileStore

    init(
        filesByType: [NSPasteboard.PasteboardType: URL],
        fileStore: PasteboardSnapshotFileStore
    ) {
        self.filesByType = filesByType
        self.fileStore = fileStore
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let fileURL = filesByType[type],
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return
        }
        item.setData(data, forType: type)
    }
}

/// Manages macOS Accessibility API integration for detecting text selection
final class AccessibilityManager {
    static let copyFallbackPreflightDelay: TimeInterval = 0.05
    static let copyFallbackKeyGap: TimeInterval = 0.01
    static let copyFallbackPollAttempts = 12
    static let copyFallbackLatePollAttempts = 8
    static let copyFallbackPollInterval: TimeInterval = 0.025
    static let maximumPasteboardSnapshotBytes = 256 * 1024 * 1024
    static let maximumPasteboardSnapshotInMemoryBytes = 8 * 1024 * 1024
    static let maximumPasteboardSnapshotItems = 32
    static let maximumPasteboardSnapshotTypes = 128
    static let copyFallbackWorstCaseDuration =
        copyFallbackPreflightDelay +
        copyFallbackKeyGap +
        (Double(copyFallbackPollAttempts + copyFallbackLatePollAttempts) * copyFallbackPollInterval)

    private static let protectedTextSubroles: Set<String> = [
        "AXSecureTextField",
        "AXSecureTextArea"
    ]
    private static let richTextHostBundleTokenHints: Set<String> = [
        "telegram",
        "electron",
        "discord",
        "obsidian",
        "chrome",
        "chromium",
        "brave",
        "edge",
        "edgemac",
        "codex",
        "webview",
        "vscode"
    ]
    private static let richTextHostBundleExactHints: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.visualstudio.code",
        "com.visualstudio.code.oss"
    ]
    private static let blindCopyFallbackBundleTokenHints: Set<String> = [
        "telegram",
        "chrome",
        "chromium",
        "brave",
        "edge",
        "edgemac",
        "browser",
        "firefox",
        "safari",
        "webkit",
        "vivaldi",
        "opera",
        "arc",
        "codex"
    ]
    private static let blindCopyFallbackBundleExactHints: Set<String> = [
        "ru.keepcoder.telegram",
        "com.apple.safari",
        "com.google.chrome",
        "com.google.chrome.canary",
        "org.chromium.chromium",
        "org.mozilla.firefox",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "company.thebrowser.browser",
        "com.openai.codex"
    ]

    private static let protectedTextBooleanAttributes = [
        "AXValueProtected",
        "AXProtectedContent",
        "AXSecure"
    ]
    
    static let shared = AccessibilityManager()
    
    private let systemWideElement: AXUIElement
    private let copyFallbackQueue = DispatchQueue(label: "com.openfire.copy-fallback", qos: .userInitiated)
    private let copyFallbackCoordinator = CopyFallbackRequestCoordinator()

    enum SelectionAcquisitionSource {
        case accessibility
        case copyFallback

        var localizationKey: String {
            switch self {
            case .accessibility:
                return "Accessibility API"
            case .copyFallback:
                return "Cmd+C Fallback"
            }
        }
    }

    struct SelectionAcquisitionStatus {
        let source: SelectionAcquisitionSource
        let timestamp: Date
        let textLength: Int
    }

    struct SelectionSnapshot: Equatable {
        let text: String?
        let rangeLocation: Int?
        let rangeLength: Int?
        let hasReadableSelectedTextAttribute: Bool
        let hasReadableSelectedRangeAttribute: Bool

        init(
            text: String?,
            rangeLocation: Int?,
            rangeLength: Int?,
            hasReadableSelectedTextAttribute: Bool = false,
            hasReadableSelectedRangeAttribute: Bool = false
        ) {
            self.text = text
            self.rangeLocation = rangeLocation
            self.rangeLength = rangeLength
            self.hasReadableSelectedTextAttribute = hasReadableSelectedTextAttribute
            self.hasReadableSelectedRangeAttribute = hasReadableSelectedRangeAttribute
        }

        var normalizedText: String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var normalizedRange: (Int, Int)? {
            guard let rangeLocation, let rangeLength, rangeLength > 0 else { return nil }
            return (rangeLocation, rangeLength)
        }

        var isReadable: Bool {
            hasReadableSelectedTextAttribute || hasReadableSelectedRangeAttribute
        }

        var canReadSelectedTextViaAccessibility: Bool {
            hasReadableSelectedTextAttribute
        }
    }

    enum SelectionAttemptFailure {
        case accessibilityEmptySelection
        case copyFallbackEmptySelection
        case observerSetupFailed
        case observerTimedOut
        case noFocusedApplication
    }

    struct SelectionAttemptStatus {
        let timestamp: Date
        let failure: SelectionAttemptFailure
    }

    struct PasteboardSnapshot {
        fileprivate let items: [[NSPasteboard.PasteboardType: PasteboardSnapshotPayload]]
        let totalBytes: Int
        let temporaryDirectoryURL: URL?
        fileprivate let fileStore: PasteboardSnapshotFileStore?

        func discardTemporaryFiles() {
            fileStore?.cleanup()
        }
    }

    var onPermissionLost: (() -> Void)?
    private var permissionWatchdog: Timer?
    private(set) var lastSelectionAcquisitionStatus: SelectionAcquisitionStatus?
    private(set) var lastSelectionAttemptStatus: SelectionAttemptStatus?
    private(set) var lastSelectionAcquiredText: String?
    
    private init() {
        systemWideElement = AXUIElementCreateSystemWide()
    }

    /// Convert AppKit's bottom-left global coordinates into the shared top-left AX/Quartz space.
    func accessibilityScreenPoint(
        for point: NSPoint,
        screenFrames: [NSRect] = NSScreen.screens.map(\.frame)
    ) -> CGPoint? {
        Self.coreGraphicsScreenPoint(for: point, screenFrames: screenFrames)
    }

    /// Convert a global AppKit point into Quartz global coordinates used by CGEvent APIs.
    /// The first NSScreen is the menu-bar display and defines the global coordinate origin.
    static func coreGraphicsScreenPoint(for point: NSPoint, screenFrames: [NSRect] = NSScreen.screens.map(\.frame)) -> CGPoint? {
        guard let primaryScreenFrame = screenFrames.first else { return nil }
        return CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }
    
    func startWatchdog() {
        permissionWatchdog?.invalidate()
        // Only run watchdog if we CURRENTLY have permission.
        guard isAccessibilityEnabled else { return }
        
        permissionWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isAccessibilityEnabled {
                self.stopWatchdog()
                DispatchQueue.main.async {
                    self.onPermissionLost?()
                }
            }
        }
    }
    
    func stopWatchdog() {
        permissionWatchdog?.invalidate()
        permissionWatchdog = nil
    }
    
    // MARK: - Permission Management
    
    /// Check if accessibility permission is granted silently
    var isAccessibilityEnabled: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Prompt user to grant accessibility permission
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    /// Check and prompt for accessibility permission if not granted
    func ensureAccessibilityPermission() -> Bool {
        if isAccessibilityEnabled {
            return true
        }
        requestAccessibilityPermission()
        return false
    }
    
    // MARK: - Text Selection
    
    func getSelectedText() -> String? {
        guard isAccessibilityEnabled else { return nil }
        guard !isSecureEventInputEnabled() else { return nil }
        
        guard let element = getFocusedElement() else { return nil }
        guard !Self.isProtectedTextElement(element) else { return nil }
        
        // Get the selected text from the focused element
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        guard textResult == .success, let text = selectedText as? String else { return nil }
        
        // Return nil for empty strings
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func currentSelectionSnapshot() -> SelectionSnapshot? {
        guard isAccessibilityEnabled else { return nil }
        guard !isSecureEventInputEnabled() else { return nil }
        guard let element = getFocusedElement() else { return nil }
        guard !Self.isProtectedTextElement(element) else { return nil }

        var selectedText: String?
        var selectedTextRaw: AnyObject?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRaw
        )
        if selectedTextResult == .success,
           let text = selectedTextRaw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedText = trimmed.isEmpty ? nil : trimmed
        }

        var rangeLocation: Int?
        var rangeLength: Int?
        var selectedRangeRaw: AnyObject?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRaw
        )
        if selectedRangeResult == .success,
           let selectedRangeRaw,
           CFGetTypeID(selectedRangeRaw) == AXValueGetTypeID() {
            let selectedRangeAXValue = unsafeBitCast(selectedRangeRaw, to: AXValue.self)
            var range = CFRange()
            if AXValueGetValue(selectedRangeAXValue, .cfRange, &range) {
                rangeLocation = range.location
                rangeLength = range.length
            }
        }

        return SelectionSnapshot(
            text: selectedText,
            rangeLocation: rangeLocation,
            rangeLength: rangeLength,
            hasReadableSelectedTextAttribute: selectedTextResult == .success,
            hasReadableSelectedRangeAttribute: selectedRangeResult == .success
        )
    }

    static func didSelectionChange(from previous: SelectionSnapshot?, to current: SelectionSnapshot?) -> Bool {
        let previousText = previous?.normalizedText
        let currentText = current?.normalizedText
        if previousText != currentText {
            return true
        }

        let previousRange = previous?.normalizedRange
        let currentRange = current?.normalizedRange
        switch (previousRange, currentRange) {
        case (.none, .none):
            return false
        case let (.some(previousRange), .some(currentRange)):
            return previousRange.0 != currentRange.0 || previousRange.1 != currentRange.1
        default:
            return true
        }
    }

    func isFocusedSelectionEditable() -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let focusedElement = getFocusedElement() else { return false }

        var isSettable: DarwinBoolean = false
        let isValueSettable =
            AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == .success &&
            isSettable.boolValue
        let isSelectedTextSettable =
            AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &isSettable) == .success &&
            isSettable.boolValue

        if isValueSettable || isSelectedTextSettable {
            return true
        }

        var isEditing: AnyObject?
        if AXUIElementCopyAttributeValue(focusedElement, "AXDocumentIsEditing" as CFString, &isEditing) == .success,
           let editing = isEditing as? Bool {
            return editing
        }

        return false
    }
    
    static func shouldContinueCopyFallback(
        requestIsActive: Bool,
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        isSelectionSuppressed: Bool
    ) -> Bool {
        guard requestIsActive, !isSelectionSuppressed else { return false }
        return isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        )
    }

    static func isExpectedCopyFallbackProcess(
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?
    ) -> Bool {
        guard let expectedProcessIdentifier, let currentProcessIdentifier else { return false }
        return expectedProcessIdentifier == currentProcessIdentifier
    }

    // Fallback: Simulate Cmd+C to grab text from apps that refuse to expose accessibility text.
    // Requests are serialized because every request temporarily owns the global pasteboard.
    @discardableResult
    func getSelectedTextViaCopy(
        expectedProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        completion: @escaping (String?) -> Void
    ) -> UUID {
        let requestID = copyFallbackCoordinator.beginRequest()

        guard !shouldSuppressSelectionPresentation() else {
            finishCopyFallbackRequest(requestID, result: nil, completion: completion)
            return requestID
        }

        copyFallbackQueue.async {
            // Give the user ~50ms to lift their fingers from the global hotkey
            // so physical modifiers (like Option/Control) don't turn Cmd+C into Option+Cmd+C
            usleep(useconds_t(Self.copyFallbackPreflightDelay * 1_000_000))

            guard let targetProcessIdentifier = expectedProcessIdentifier,
                  self.copyFallbackContextIsValid(
                requestID: requestID,
                expectedProcessIdentifier: expectedProcessIdentifier
            ) else {
                self.finishCopyFallbackRequest(requestID, result: nil, completion: completion)
                return
            }
            
            let pasteboard = NSPasteboard.general
            let initialChangeCount = pasteboard.changeCount
            let initialString = pasteboard.string(forType: .string)
            guard let snapshot = Self.capturePasteboardSnapshot(from: pasteboard) else {
                NSLog("[OpenFire] Skipping Cmd+C fallback because the clipboard cannot be snapshotted safely.")
                self.finishCopyFallbackRequest(requestID, result: nil, completion: completion)
                return
            }
            var snapshotWasRestored = false
            defer {
                if !snapshotWasRestored {
                    snapshot.discardTemporaryFiles()
                }
            }
            
            // Simulate Cmd+C via CGEvent
            let source = CGEventSource(stateID: .hidSystemState)
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(8), keyDown: true)
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(8), keyDown: false)
            
            cmdDown?.flags = .maskCommand
            cmdUp?.flags = .maskCommand
            
            cmdDown?.postToPid(targetProcessIdentifier)
            usleep(useconds_t(Self.copyFallbackKeyGap * 1_000_000))
            cmdUp?.postToPid(targetProcessIdentifier)
            
            // Wait for Electron/Chromium/WebView apps to detect the event, process the DOM,
            // and asynchronously write to the pasteboard.
            var copyObservation = Self.pollPasteboardForCopiedText(
                pasteboard: pasteboard,
                initialChangeCount: initialChangeCount,
                initialString: initialString,
                attempts: Self.copyFallbackPollAttempts
            )

            if !copyObservation.hasFreshCopiedText {
                copyObservation = Self.pollPasteboardForCopiedText(
                    pasteboard: pasteboard,
                    initialChangeCount: initialChangeCount,
                    initialString: initialString,
                    attempts: Self.copyFallbackLatePollAttempts
                )
            }
            
            // Only restore if the pasteboard still contains the value created by this fallback.
            if Self.shouldRestorePasteboardSnapshot(
                initialChangeCount: initialChangeCount,
                observedChangeCount: copyObservation.observedChangeCount,
                copiedText: copyObservation.copiedText,
                initialString: initialString,
                currentChangeCount: pasteboard.changeCount,
                currentString: pasteboard.string(forType: .string)
            ) {
                snapshotWasRestored = Self.restorePasteboardSnapshot(snapshot, to: pasteboard)
                if !snapshotWasRestored {
                    NSLog("[OpenFire] Failed to restore the clipboard after Cmd+C fallback.")
                }
            }
            
            let trimmed = copyObservation.copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextIsStillValid = self.copyFallbackContextIsValid(
                requestID: requestID,
                expectedProcessIdentifier: expectedProcessIdentifier
            )
            let result = contextIsStillValid &&
                copyObservation.hasFreshCopiedText &&
                (trimmed?.isEmpty == false) ? trimmed : nil

            self.finishCopyFallbackRequest(requestID, result: result, completion: completion)
        }

        return requestID
    }

    func cancelSelectedTextViaCopy(_ requestID: UUID) {
        copyFallbackCoordinator.cancelRequest(requestID)
    }

    func cancelActiveSelectedTextViaCopy() {
        copyFallbackCoordinator.cancelActiveRequest()
    }

    private func copyFallbackContextIsValid(
        requestID: UUID,
        expectedProcessIdentifier: pid_t?
    ) -> Bool {
        var currentProcessIdentifier: pid_t?
        var isSelectionSuppressed = true

        let readContext = {
            currentProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            isSelectionSuppressed = self.shouldSuppressSelectionPresentation()
        }

        if Thread.isMainThread {
            readContext()
        } else {
            DispatchQueue.main.sync(execute: readContext)
        }

        return Self.shouldContinueCopyFallback(
            requestIsActive: copyFallbackCoordinator.isRequestActive(requestID),
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            isSelectionSuppressed: isSelectionSuppressed
        )
    }

    private func finishCopyFallbackRequest(
        _ requestID: UUID,
        result: String?,
        completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.main.async {
            let isLatestRequest = self.copyFallbackCoordinator.completeRequestIfActive(requestID)
            completion(isLatestRequest ? result : nil)
        }
    }

    func recordSelectionAcquisition(source: SelectionAcquisitionSource, text: String) {
        lastSelectionAcquisitionStatus = SelectionAcquisitionStatus(
            source: source,
            timestamp: Date(),
            textLength: text.count
        )
        lastSelectionAcquiredText = text
        lastSelectionAttemptStatus = nil
    }

    func recordSelectionAttemptFailure(_ failure: SelectionAttemptFailure) {
        lastSelectionAttemptStatus = SelectionAttemptStatus(
            timestamp: Date(),
            failure: failure
        )
    }

    func isFocusedElementProtected() -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let focusedElement = getFocusedElement() else { return false }
        return Self.isProtectedTextElement(focusedElement)
    }

    func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    func shouldSuppressSelectionPresentation() -> Bool {
        isSecureEventInputEnabled() || isFocusedElementProtected()
    }

    static func capturePasteboardSnapshot(
        from pasteboard: NSPasteboard,
        maxBytes: Int = maximumPasteboardSnapshotBytes,
        maxItems: Int = maximumPasteboardSnapshotItems,
        maxTypes: Int = maximumPasteboardSnapshotTypes,
        maxInMemoryBytes: Int = maximumPasteboardSnapshotInMemoryBytes,
        fileManager: FileManager = .default
    ) -> PasteboardSnapshot? {
        guard maxBytes >= 0, maxItems >= 0, maxTypes >= 0, maxInMemoryBytes >= 0 else {
            return nil
        }
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        guard pasteboardItems.count <= maxItems else { return nil }

        var totalBytes = 0
        var inMemoryBytes = 0
        var totalTypes = 0
        var capturedItems: [[NSPasteboard.PasteboardType: PasteboardSnapshotPayload]] = []
        var fileStore: PasteboardSnapshotFileStore?
        capturedItems.reserveCapacity(pasteboardItems.count)

        for item in pasteboardItems {
            guard item.types.count <= maxTypes - totalTypes else { return nil }
            totalTypes += item.types.count

            var snapshot: [NSPasteboard.PasteboardType: PasteboardSnapshotPayload] = [:]
            for type in item.types {
                guard let data = item.data(forType: type),
                      data.count <= maxBytes - totalBytes else {
                    return nil
                }
                totalBytes += data.count

                let remainingInMemoryBytes = maxInMemoryBytes - min(inMemoryBytes, maxInMemoryBytes)
                if data.count <= remainingInMemoryBytes {
                    snapshot[type] = .memory(data)
                    inMemoryBytes += data.count
                } else {
                    if fileStore == nil {
                        fileStore = PasteboardSnapshotFileStore(fileManager: fileManager)
                    }
                    guard let fileStore,
                          let fileURL = fileStore.store(data) else {
                        return nil
                    }
                    snapshot[type] = .file(fileURL)
                }
            }
            capturedItems.append(snapshot)
        }

        return PasteboardSnapshot(
            items: capturedItems,
            totalBytes: totalBytes,
            temporaryDirectoryURL: fileStore?.directoryURL,
            fileStore: fileStore
        )
    }

    @discardableResult
    static func restorePasteboardSnapshot(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard !snapshot.items.isEmpty else {
            pasteboard.clearContents()
            return true
        }

        var dataProviders: [PasteboardSnapshotDataProvider] = []
        let restoredItems = snapshot.items.compactMap { itemSnapshot -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var filesByType: [NSPasteboard.PasteboardType: URL] = [:]

            for (type, payload) in itemSnapshot {
                switch payload {
                case .memory(let data):
                    guard item.setData(data, forType: type) else { return nil }
                case .file(let fileURL):
                    filesByType[type] = fileURL
                }
            }

            if !filesByType.isEmpty {
                guard let fileStore = snapshot.fileStore else { return nil }
                let provider = PasteboardSnapshotDataProvider(
                    filesByType: filesByType,
                    fileStore: fileStore
                )
                guard item.setDataProvider(provider, forTypes: Array(filesByType.keys)) else {
                    return nil
                }
                dataProviders.append(provider)
            }

            return item
        }

        guard restoredItems.count == snapshot.items.count else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(restoredItems)
    }

    private struct CopyObservation {
        let copiedText: String?
        let hasFreshCopiedText: Bool
        let observedChangeCount: Int
    }

    private static func pollPasteboardForCopiedText(
        pasteboard: NSPasteboard,
        initialChangeCount: Int,
        initialString: String?,
        attempts: Int = copyFallbackPollAttempts
    ) -> CopyObservation {
        var latestString = initialString
        var latestChangeCount = initialChangeCount

        for _ in 0..<attempts {
            usleep(useconds_t(copyFallbackPollInterval * 1_000_000))
            latestString = pasteboard.string(forType: .string)
            latestChangeCount = pasteboard.changeCount

            if shouldTreatCopiedTextAsFresh(
                initialChangeCount: initialChangeCount,
                observedChangeCount: latestChangeCount,
                initialString: initialString,
                observedString: latestString
            ) {
                return CopyObservation(
                    copiedText: latestString,
                    hasFreshCopiedText: true,
                    observedChangeCount: latestChangeCount
                )
            }
        }

        return CopyObservation(
            copiedText: latestString,
            hasFreshCopiedText: false,
            observedChangeCount: latestChangeCount
        )
    }

    static func shouldTreatCopiedTextAsFresh(
        initialChangeCount: Int,
        observedChangeCount: Int,
        initialString: String?,
        observedString: String?
    ) -> Bool {
        guard let observedString else { return false }
        let trimmedObservedString = observedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedObservedString.isEmpty else { return false }

        if observedChangeCount != initialChangeCount {
            return true
        }

        let trimmedInitialString = initialString?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedInitialString != trimmedObservedString
    }

    static func shouldRestorePasteboardSnapshot(
        initialChangeCount: Int,
        observedChangeCount: Int,
        copiedText: String?,
        initialString: String? = nil
    ) -> Bool {
        if initialString == nil {
            guard let copiedText else { return false }
            guard !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return observedChangeCount != initialChangeCount
        }

        return shouldTreatCopiedTextAsFresh(
            initialChangeCount: initialChangeCount,
            observedChangeCount: observedChangeCount,
            initialString: initialString,
            observedString: copiedText
        )
    }

    static func shouldRestorePasteboardSnapshot(
        initialChangeCount: Int,
        observedChangeCount: Int,
        copiedText: String?,
        initialString: String? = nil,
        currentChangeCount: Int,
        currentString: String?
    ) -> Bool {
        guard shouldRestorePasteboardSnapshot(
            initialChangeCount: initialChangeCount,
            observedChangeCount: observedChangeCount,
            copiedText: copiedText,
            initialString: initialString
        ) else {
            return false
        }

        return currentChangeCount == observedChangeCount &&
            currentString?.trimmingCharacters(in: .whitespacesAndNewlines) ==
            copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldAssumeFocusedTextInputContainsClickWhenBoundsUnavailable() -> Bool {
        false
    }

    static func isLikelyRichTextSelectionHost(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let normalizedBundleID = bundleID.lowercased()
        if richTextHostBundleExactHints.contains(normalizedBundleID) {
            return true
        }

        return !bundleTokens(for: normalizedBundleID).intersection(richTextHostBundleTokenHints).isEmpty
    }

    static func shouldAllowBlindCopyFallback(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let normalizedBundleID = bundleID.lowercased()
        if blindCopyFallbackBundleExactHints.contains(normalizedBundleID) {
            return true
        }

        return !bundleTokens(for: normalizedBundleID).intersection(blindCopyFallbackBundleTokenHints).isEmpty
    }

    static func shouldAllowContextlessBlindCopyFallback(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return blindCopyFallbackBundleExactHints.contains(bundleID.lowercased())
    }

    private static func bundleTokens(for normalizedBundleID: String) -> Set<String> {
        Set(
            normalizedBundleID
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    static func shouldTreatFocusedRoleAsTextSelectionContext(
        role: String,
        ancestorRoles: [String],
        bundleID: String?
    ) -> Bool {
        let allowedRoles = [
            kAXStaticTextRole,
            kAXTextFieldRole,
            kAXTextAreaRole,
            "AXWebArea",
            "AXHeading",
            "AXParagraph",
            "AXLink"
        ]
        let forbiddenRoles = [
            kAXImageRole,
            kAXCellRole,
            kAXRowRole,
            kAXButtonRole,
            kAXWindowRole,
            kAXApplicationRole
        ]

        if role == "AXGroup",
           Self.isLikelyRichTextSelectionHost(bundleID: bundleID) {
            return true
        }

        return shouldTreatElementAsText(
            role: role,
            ancestorRoles: ancestorRoles,
            bundleID: bundleID,
            allowedRoles: allowedRoles,
            forbiddenRoles: forbiddenRoles
        )
    }

    func isFocusedTextSelectionContext(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        guard let focusedElement = getFocusedElement() else { return false }

        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
              let role = roleValue as? String else { return false }

        let ancestorRoles = ancestorRoles(for: focusedElement)
        let bundleID = getFocusedAppBundleID()
        guard Self.shouldTreatFocusedRoleAsTextSelectionContext(
            role: role,
            ancestorRoles: ancestorRoles,
            bundleID: bundleID
        ) else {
            return false
        }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return false
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return false
        }

        return CGRect(origin: position, size: size).contains(axPoint)
    }

    func isPointInsideFocusedElementBounds(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        guard let focusedElement = getFocusedElement() else { return false }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return false
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return false
        }

        return CGRect(origin: position, size: size).contains(axPoint)
    }
    
    /// Check if the element at the specified screen coordinates is a text input field
    func isTextInputElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }

        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        
        // 1. Get the globally focused element instead of hit-testing.
        // Hit-testing often returns low-level items like AXGroup or AXStaticText which breaks the logic.
        guard let focusedElement = getFocusedElement() else { return false }
        
        // 2. Verify the role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else { return false }
        
        // 3. Verify it's a text input
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea", "AXGroup", "AXDocument", "AXSearchField"]
        let forbiddenRoles = [
            kAXCheckBoxRole,
            kAXRadioButtonRole,
            kAXButtonRole,
            kAXPopUpButtonRole,
            kAXMenuButtonRole,
            kAXSliderRole,
            kAXValueIndicatorRole,
            kAXColorWellRole,
            kAXListRole,
            kAXOutlineRole,
            kAXTableRole
        ]
        
        if forbiddenRoles.contains(role) {
            NSLog("[OpenFire-Debug] Focused element is forbidden (role: \(role)), refusing to treat as text input.")
            return false
        }
        
        var isEditableText = false
        
        var isSettable: DarwinBoolean = false
        let isValueSettable = AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == .success && isSettable.boolValue
        let isSelectedTextSettable = AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &isSettable) == .success && isSettable.boolValue
        
        if isValueSettable || isSelectedTextSettable {
            isEditableText = true
        } else if textRoles.contains(role) {
            // Some specific rich text editors don't flag attributes as settable but are actively editing
            var isEditing: AnyObject?
            if AXUIElementCopyAttributeValue(focusedElement, "AXDocumentIsEditing" as CFString, &isEditing) == .success,
               let editing = isEditing as? Bool, editing {
                isEditableText = true
            }
        }
        
        guard isEditableText else {
            NSLog("[OpenFire-Debug] Focused element is NOT an editable text input (role: \(role)).")
            return false
        }
        
        // 4. Verify the click fell INSIDE the element's bounds to avoid false positives when clicking out
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        
        if AXUIElementCopyAttributeValue(focusedElement, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(focusedElement, kAXSizeAttribute as CFString, &sizeValue) == .success {
            
            var position = CGPoint.zero
            var size = CGSize.zero

            guard
                let positionValue,
                let sizeValue,
                CFGetTypeID(positionValue) == AXValueGetTypeID(),
                CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else {
                NSLog("[OpenFire-Debug] Failed to decode AX position/size for focused text input.")
                return false
            }

            let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
            let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)

            guard
                AXValueGetValue(positionAXValue, .cgPoint, &position),
                AXValueGetValue(sizeAXValue, .cgSize, &size)
            else {
                NSLog("[OpenFire-Debug] Failed to decode AX position/size for focused text input.")
                return false
            }
            
            let elementRect = CGRect(origin: position, size: size)
            let contains = elementRect.contains(axPoint)
            
            NSLog("[OpenFire-Debug] Element bounds: \(elementRect), Click point: \(axPoint), Contains: \(contains)")
            return contains
        }
        
        // Fallback: If we couldn't get bounding boxes but we know it's a focused text input,
        // refuse to guess so clicks outside the field don't spuriously trigger empty-input UI.
        NSLog("[OpenFire-Debug] Could not get element bounds. Refusing to assume hit.")
        return Self.shouldAssumeFocusedTextInputContainsClickWhenBoundsUnavailable()
    }
    
    /// Check if the element at the specified screen coordinates is purely text (like a webpage paragraph, a text field, or static text label),
    /// specifically excluding structural elements like Finder rows, cells, or images that get double-clicked.
    func isTextElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }

        // 1. Get the globally focused element or the element exactly under the mouse
        // We use systemWideElement to hit-test the specific point on screen
        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        
        var hitElementRaw: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(systemWideElement, Float(axPoint.x), Float(axPoint.y), &hitElementRaw)
        
        guard hitResult == .success, let hitElement = hitElementRaw else { return false }
        
        // 2. Identify the role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(hitElement, kAXRoleAttribute as CFString, &roleValue)
        guard roleResult == .success, let role = roleValue as? String else { return false }
        let bundleID = getFocusedAppBundleID()
        let ancestorRoles = ancestorRoles(for: hitElement)
        
        // Allowed roles that represent actual selectable text content
        let allowedRoles = [
            kAXStaticTextRole,
            kAXTextFieldRole,
            kAXTextAreaRole,
            "AXWebArea",
            "AXHeading",
            "AXParagraph",
            "AXLink"
        ]
        
        // Strictly forbidden roles (Finder files, Desktop icons, buttons, table cells)
        let forbiddenRoles = [
            kAXImageRole,
            kAXCellRole,
            kAXRowRole,
            kAXButtonRole,
            kAXWindowRole,
            kAXApplicationRole
        ]

        NSLog("[OpenFire-Debug] Double-click hit test detected role: \(role)")

        if Self.shouldTreatElementAsText(
            role: role,
            ancestorRoles: ancestorRoles,
            bundleID: bundleID,
            allowedRoles: allowedRoles,
            forbiddenRoles: forbiddenRoles
        ) {
            return true
        }
        
        // If it's an unknown group, we default to false to be safe and avoid misfires,
        // EXCEPT if it's Electron/Chromium (which often wrap text in generic AXGroups).
        // Let's explicitly check the app ID.
        if role == "AXGroup",
           Self.isLikelyRichTextSelectionHost(bundleID: bundleID) {
            return true
        }
        
        return false
    }
    
    func getFocusedElement() -> AXUIElement? {
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        guard
            appResult == .success,
            let focusedApp,
            CFGetTypeID(focusedApp) == AXUIElementGetTypeID()
        else { return nil }
        let app = unsafeBitCast(focusedApp, to: AXUIElement.self)
        
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard
            elementResult == .success,
            let focusedElement,
            CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else { return nil }
        
        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    private static func isProtectedTextElement(_ element: AXUIElement) -> Bool {
        var subroleValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String,
           protectedTextSubroles.contains(subrole) {
            return true
        }

        for attribute in protectedTextBooleanAttributes {
            var attributeValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
               let isProtected = attributeValue as? Bool,
               isProtected {
                return true
            }
        }

        return false
    }

    static func isProtectedTextElementDescriptor(subrole: String?, flags: [String: Bool]) -> Bool {
        if let subrole, protectedTextSubroles.contains(subrole) {
            return true
        }

        return protectedTextBooleanAttributes.contains { flags[$0] == true }
    }

    static func shouldSuppressSelectionPresentation(
        isProtectedElement: Bool,
        secureEventInputEnabled: Bool
    ) -> Bool {
        secureEventInputEnabled || isProtectedElement
    }

    func focusedElementRoleDescription() -> String? {
        guard let element = getFocusedElement() else { return nil }

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard roleResult == .success, let role = roleValue as? String else { return nil }

        var subroleValue: AnyObject?
        let subroleResult = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )

        if subroleResult == .success, let subrole = subroleValue as? String, !subrole.isEmpty {
            return "\(role) / \(subrole)"
        }

        return role
    }
    
    /// Get the currently focused application's bundle identifier
    func getFocusedAppBundleID() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontApp.bundleIdentifier
    }

    private func ancestorRoles(for element: AXUIElement, maxDepth: Int = 6) -> [String] {
        var roles: [String] = []
        var currentElement = element

        for _ in 0..<maxDepth {
            var parentRaw: AnyObject?
            let result = AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentRaw)
            guard result == .success, let parentRaw, CFGetTypeID(parentRaw) == AXUIElementGetTypeID() else {
                break
            }

            let parent = unsafeBitCast(parentRaw, to: AXUIElement.self)
            var roleRaw: AnyObject?
            if AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRaw) == .success,
               let role = roleRaw as? String {
                roles.append(role)
            }

            currentElement = parent
        }

        return roles
    }

    static func shouldTreatElementAsText(
        role: String,
        ancestorRoles: [String],
        bundleID: String?,
        allowedRoles: [String],
        forbiddenRoles: [String]
    ) -> Bool {
        let structuralAncestorRoles: Set<String> = [
            kAXCellRole,
            kAXRowRole,
            kAXListRole,
            kAXOutlineRole,
            kAXTableRole
        ]
        let webContentAncestorRoles: Set<String> = [
            "AXBrowser",
            "AXWebArea",
            "AXDocument"
        ]

        if forbiddenRoles.contains(role) {
            return false
        }

        if allowedRoles.contains(role) {
            if let blockingAncestor = ancestorRoles.first(where: { forbiddenRoles.contains($0) || structuralAncestorRoles.contains($0) }) {
                NSLog("[OpenFire-Debug] Blocking allowed role \(role) because an ancestor is \(blockingAncestor)")
                return false
            }
            return true
        }

        if role == "AXGroup" {
            let isWithinWebContent = ancestorRoles.contains(where: webContentAncestorRoles.contains)
            let isWithinStructuralContainer = ancestorRoles.contains(where: structuralAncestorRoles.contains)
            if isWithinWebContent && !isWithinStructuralContainer {
                return true
            }
        }

        if role == "AXGroup",
           let bundleID,
           bundleID.lowercased().contains("jetbrains"),
           ancestorRoles.contains(where: structuralAncestorRoles.contains) {
            NSLog("[OpenFire-Debug] Blocking AXGroup in JetBrains structural container: \(ancestorRoles)")
            return false
        }

        return false
    }
}
