import Cocoa
import ApplicationServices
import Carbon

/// Thread-safe request ownership shared by the main actor and the serialized
/// pasteboard worker.
final class CopyFallbackRequestCoordinator: Sendable {
    private let activeRequestID = LockedState<UUID?>(initialState: nil)

    func beginRequest() -> UUID {
        let requestID = UUID()
        activeRequestID.withLock { $0 = requestID }
        return requestID
    }

    func isRequestActive(_ requestID: UUID) -> Bool {
        activeRequestID.withLock { $0 == requestID }
    }

    func cancelRequest(_ requestID: UUID) {
        activeRequestID.withLock {
            if $0 == requestID {
                $0 = nil
            }
        }
    }

    func completeRequestIfActive(_ requestID: UUID) -> Bool {
        activeRequestID.withLock {
            guard $0 == requestID else { return false }
            $0 = nil
            return true
        }
    }

    func cancelActiveRequest() {
        activeRequestID.withLock { $0 = nil }
    }
}

private enum PasteboardSnapshotPayload {
    case memory(Data)
    case file(URL)
}

private final class PasteboardSnapshotFileStore: Sendable {
    private struct CleanupState {
        var activeLeaseCount = 0
        var cleanupRequested = false
        var isCleanedUp = false
    }

    final class Lease: Sendable {
        private let fileStore: PasteboardSnapshotFileStore

        fileprivate init(fileStore: PasteboardSnapshotFileStore) {
            self.fileStore = fileStore
        }

        deinit {
            fileStore.releaseLease()
        }
    }

    let directoryURL: URL

    private let cleanupState = LockedState(initialState: CleanupState())

    init?(fileManager: FileManager = .default) {
        directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "ActionHalo-Pasteboard-\(UUID().uuidString)",
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

    func makeLease() -> Lease? {
        cleanupState.withLock {
            guard !$0.cleanupRequested, !$0.isCleanedUp else { return nil }
            $0.activeLeaseCount += 1
            return Lease(fileStore: self)
        }
    }

    func cleanup() {
        let shouldRemoveDirectory = cleanupState.withLock {
            guard !$0.isCleanedUp else { return false }
            $0.cleanupRequested = true
            guard $0.activeLeaseCount == 0 else { return false }
            $0.isCleanedUp = true
            return true
        }
        if shouldRemoveDirectory {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private func releaseLease() {
        let shouldRemoveDirectory = cleanupState.withLock {
            guard $0.activeLeaseCount > 0 else { return false }
            $0.activeLeaseCount -= 1
            guard $0.cleanupRequested,
                  $0.activeLeaseCount == 0,
                  !$0.isCleanedUp else {
                return false
            }
            $0.isCleanedUp = true
            return true
        }
        if shouldRemoveDirectory {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    deinit {
        cleanup()
    }
}

private final class PasteboardSnapshotDataProvider:
    NSObject,
    NSPasteboardItemDataProvider,
    Sendable
{
    private let retentionID = UUID()
    private let filesByType: [NSPasteboard.PasteboardType: URL]
    private let fileStoreLease: PasteboardSnapshotFileStore.Lease

    init(
        filesByType: [NSPasteboard.PasteboardType: URL],
        fileStoreLease: PasteboardSnapshotFileStore.Lease
    ) {
        self.filesByType = filesByType
        self.fileStoreLease = fileStoreLease
        super.init()
    }

    func activate() {
        PasteboardSnapshotDataProviderRegistry.shared.retain(
            self,
            identifier: retentionID
        )
    }

    func cancel() {
        PasteboardSnapshotDataProviderRegistry.shared.release(
            identifier: retentionID
        )
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

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        cancel()
    }
}

private final class PasteboardSnapshotDataProviderRegistry: Sendable {
    static let shared = PasteboardSnapshotDataProviderRegistry()

    private let retainedProviders =
        LockedState<[UUID: PasteboardSnapshotDataProvider]>(
            initialState: [:]
        )

    private init() {}

    func retain(
        _ provider: PasteboardSnapshotDataProvider,
        identifier: UUID
    ) {
        retainedProviders.withLock { $0[identifier] = provider }
    }

    func release(identifier: UUID) {
        _ = retainedProviders.withLock { $0.removeValue(forKey: identifier) }
    }
}

private struct MaterializedPasteboardContents {
    let items: [NSPasteboardItem]
    let dataProviders: [PasteboardSnapshotDataProvider]

    func activateDataProviders() {
        dataProviders.forEach { $0.activate() }
    }

    func cancelDataProviders() {
        dataProviders.forEach { $0.cancel() }
    }
}

/// Manages macOS Accessibility API integration for detecting text selection
@MainActor
final class AccessibilityManager {
    nonisolated static let copyFallbackPreflightDelay: TimeInterval = 0.05
    nonisolated static let copyFallbackKeyGap: TimeInterval = 0.01
    nonisolated static let copyFallbackPollAttempts = 12
    nonisolated static let copyFallbackLatePollAttempts = 8
    nonisolated static let copyFallbackPollInterval: TimeInterval = 0.025
    nonisolated static let copyFallbackStableObservationSamples = 3
    nonisolated static let maximumPasteboardSnapshotBytes = 256 * 1024 * 1024
    nonisolated static let maximumPasteboardSnapshotInMemoryBytes = 8 * 1024 * 1024
    nonisolated static let maximumPasteboardSnapshotItems = 32
    nonisolated static let maximumPasteboardSnapshotTypes = 128
    nonisolated static let pasteboardStableReadAttempts = 3
    nonisolated static let accessibilityMessagingTimeout: Float = 0.25
    nonisolated static let focusedElementRetryDelays: [TimeInterval] = [0.05, 0.1]
    nonisolated static let focusedElementRecoveryRetryDelays: [TimeInterval] = [0.05, 0.1]
    nonisolated static let copyFallbackWorstCaseDuration =
        copyFallbackPreflightDelay +
        copyFallbackKeyGap +
        (Double(copyFallbackPollAttempts + copyFallbackLatePollAttempts) * copyFallbackPollInterval)

    nonisolated private static let protectedTextSubroles: Set<String> = [
        "AXSecureTextField",
        "AXSecureTextArea"
    ]
    nonisolated private static let richTextHostBundleTokenHints: Set<String> = [
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
    nonisolated private static let richTextHostBundleExactHints: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.visualstudio.code",
        "com.visualstudio.code.oss"
    ]
    nonisolated private static let blindCopyFallbackBundleTokenHints: Set<String> = [
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
    nonisolated private static let blindCopyFallbackBundleExactHints: Set<String> = [
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

    nonisolated private static let protectedTextBooleanAttributes = [
        "AXValueProtected",
        "AXProtectedContent",
        "AXSecure"
    ]

    enum ProtectedTextAssessment: Equatable, Sendable {
        case protectedContent
        case unprotected
        case indeterminate
    }

    struct PasteboardState: Equatable {
        let changeCount: Int
        let string: String?
    }

    struct StableFreshPasteboardCandidate {
        private var state: PasteboardState?
        private var consecutiveSampleCount = 0

        mutating func observe(
            _ observedState: PasteboardState,
            relativeTo initialState: PasteboardState
        ) -> Bool {
            guard AccessibilityManager.shouldTreatCopiedTextAsFresh(
                initialChangeCount: initialState.changeCount,
                observedChangeCount: observedState.changeCount,
                initialString: initialState.string,
                observedString: observedState.string
            ) else {
                state = nil
                consecutiveSampleCount = 0
                return false
            }

            if state == observedState {
                consecutiveSampleCount += 1
            } else {
                state = observedState
                consecutiveSampleCount = 1
            }
            return consecutiveSampleCount >=
                AccessibilityManager.copyFallbackStableObservationSamples
        }
    }

    enum RetryDisposition: Equatable, Sendable {
        case accept
        case retry
        case retryLookup
        case reject
    }

    struct FocusedWindowConstraint {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let bounds: CGRect
        let expectedSelectionWindow: AXUIElement?

        init(
            windowID: CGWindowID,
            ownerPID: pid_t,
            bounds: CGRect,
            expectedSelectionWindow: AXUIElement? = nil
        ) {
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.bounds = bounds
            self.expectedSelectionWindow = expectedSelectionWindow
        }
    }

    /// AXUIElement is an immutable Core Foundation proxy but is not declared
    /// Sendable by the SDK. Keep the unchecked boundary private and use it only
    /// for a one-way ownership handoff between the AX worker and MainActor.
    private struct TransferredAXElement: @unchecked Sendable {
        let value: AXUIElement
    }

    private struct TransferredAssessedFocusedElement: @unchecked Sendable {
        let selectionWindow: AXUIElement?
        let assessment: FocusedElementAssessment
    }

    /// AX attributes can briefly time out even after focus itself has resolved.
    /// Keep those reads on a per-request worker and retry the whole assessment
    /// without blocking MainActor or asking it to touch the AX proxy again.
    private actor ElementAssessmentSession {
        private let focusedElement: AXUIElement
        private let systemWideElement: AXUIElement

        init(focusedElement: TransferredAXElement) {
            self.focusedElement = focusedElement.value
            systemWideElement = AXUIElementCreateSystemWide()
            _ = AXUIElementSetMessagingTimeout(
                systemWideElement,
                AccessibilityManager.accessibilityMessagingTimeout
            )
        }

        func resolve(
            bundleID: String?,
            accessibilityPoints: [CGPoint],
            requireUsableSelection: Bool,
            retryDelays: [TimeInterval]
        ) async -> TransferredAssessedFocusedElement? {
            var latestAssessment: FocusedElementAssessment?

            for attemptIndex in 0...retryDelays.count {
                guard !Task.isCancelled else { return nil }
                let assessment = AccessibilityManager.focusedElementAssessment(
                    for: focusedElement,
                    systemWideElement: systemWideElement,
                    bundleID: bundleID,
                    accessibilityPoints: accessibilityPoints
                )
                latestAssessment = assessment

                if assessment.protection == .protectedContent ||
                    (assessment.protection == .unprotected &&
                        assessment.pointAssessments.allSatisfy(\.isResolved) &&
                        (!requireUsableSelection ||
                            assessment.selectionSnapshot?.usableText != nil)) {
                    break
                }

                guard attemptIndex < retryDelays.count else { break }
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: UInt64(
                            max(0, retryDelays[attemptIndex]) * 1_000_000_000
                        )
                    )
                } catch {
                    return nil
                }
            }

            guard !Task.isCancelled, let latestAssessment else { return nil }
            return TransferredAssessedFocusedElement(
                selectionWindow: AccessibilityManager.selectionWindowElement(
                    for: focusedElement
                ),
                assessment: latestAssessment
            )
        }
    }

    /// One resolver is created per trigger request. A cancelled, uninterruptible
    /// AX IPC can therefore finish on its own executor without serializing a
    /// newer mouse or hotkey request behind it.
    private actor FocusResolutionSession {
        private var systemWideElement: AXUIElement?
        private var focusedElement: AXUIElement?
        private let expectedSelectionWindow: AXUIElement?
        private let capturedWindowBounds: CGRect?

        init(
            expectedSelectionWindow: TransferredAXElement?,
            capturedWindowBounds: CGRect?
        ) {
            self.expectedSelectionWindow = expectedSelectionWindow?.value
            self.capturedWindowBounds = capturedWindowBounds
        }

        func resolveFocus(processIdentifier: pid_t) -> Bool {
            guard !Task.isCancelled else { return false }
            if focusedElement == nil {
                focusedElement = lookupFocusedElement(
                    processIdentifier: processIdentifier
                )
            }
            return focusedElement != nil && !Task.isCancelled
        }

        /// nil means the AX window attributes are not published yet and may be
        /// retried. false is an explicit cross-window mismatch and must stop.
        func accessibilityWindowMatchesConstraint() -> Bool? {
            guard !Task.isCancelled, let focusedElement else { return nil }
            guard expectedSelectionWindow != nil || capturedWindowBounds != nil else {
                return true
            }
            guard let selectionWindow = AccessibilityManager.selectionWindowElement(
                for: focusedElement
            ) else {
                return nil
            }

            if let expectedSelectionWindow {
                return CFEqual(expectedSelectionWindow, selectionWindow)
            }

            guard let frame = AccessibilityManager.frameOfElement(selectionWindow),
                  let capturedWindowBounds else {
                return nil
            }
            return TextSelectionMonitor.accessibilityWindowFrameMatchesCapturedWindow(
                frame,
                capturedBounds: capturedWindowBounds
            )
        }

        func discardFocusedElement() {
            focusedElement = nil
        }

        func takeFocusedElement() -> TransferredAXElement? {
            guard !Task.isCancelled, let focusedElement else { return nil }
            self.focusedElement = nil
            return TransferredAXElement(value: focusedElement)
        }

        private func lookupFocusedElement(
            processIdentifier: pid_t
        ) -> AXUIElement? {
            // The PID-specific application query avoids the system-wide focus
            // publication gap seen in Notes on macOS 15.x and is also cheaper.
            let application = AXUIElementCreateApplication(processIdentifier)
            _ = AXUIElementSetMessagingTimeout(
                application,
                AccessibilityManager.accessibilityMessagingTimeout
            )
            if let candidate = AccessibilityManager.focusedElement(
                fromApplication: application,
                expectedProcessIdentifier: processIdentifier
            ), AccessibilityManager.element(
                candidate,
                belongsTo: processIdentifier
            ) {
                return candidate
            }

            guard !Task.isCancelled else { return nil }
            let systemWide: AXUIElement
            if let systemWideElement {
                systemWide = systemWideElement
            } else {
                let newSystemWideElement = AXUIElementCreateSystemWide()
                _ = AXUIElementSetMessagingTimeout(
                    newSystemWideElement,
                    AccessibilityManager.accessibilityMessagingTimeout
                )
                systemWideElement = newSystemWideElement
                systemWide = newSystemWideElement
            }
            guard let candidate = AccessibilityManager.focusedElement(
                fromSystemWideElement: systemWide,
                expectedProcessIdentifier: processIdentifier
            ), AccessibilityManager.element(
                candidate,
                belongsTo: processIdentifier
            ) else {
                return nil
            }
            return candidate
        }
    }
    
    static let shared = AccessibilityManager()
    
    private let systemWideElement: AXUIElement
    private let copyFallbackQueue = DispatchQueue(label: "com.actionhalo.copy-fallback", qos: .userInitiated)
    private let copyFallbackCoordinator = CopyFallbackRequestCoordinator()

    enum SelectionAcquisitionSource {
        case accessibility
        case copyFallback

        var localizedName: String {
            switch self {
            case .accessibility:
                return "Accessibility API".localized
            case .copyFallback:
                return "Cmd+C Fallback".localized
            }
        }
    }

    struct SelectionAcquisitionStatus {
        let source: SelectionAcquisitionSource
        let timestamp: Date
        let textLength: Int
    }

    struct SelectionSnapshot: Equatable, Sendable {
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

        var usableText: String? {
            guard let text, normalizedText != nil else { return nil }
            return text
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

    struct PointSelectionAssessment: Equatable, Sendable {
        let isTextSelectionContext: Bool
        let isInsideFocusedElementBounds: Bool
        let isResolved: Bool
    }

    struct FocusedElementAssessment: Equatable, Sendable {
        let protection: ProtectedTextAssessment
        let isSelectionEditable: Bool
        let selectionSnapshot: SelectionSnapshot?
        let pointAssessments: [PointSelectionAssessment]
    }

    struct AssessedFocusedElement {
        let focusedElement: AXUIElement
        let selectionWindow: AXUIElement?
        let assessment: FocusedElementAssessment
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
        _ = AXUIElementSetMessagingTimeout(systemWideElement, Self.accessibilityMessagingTimeout)
    }

    /// Convert AppKit's bottom-left global coordinates into the shared top-left AX/Quartz space.
    func accessibilityScreenPoint(for point: NSPoint) -> CGPoint? {
        accessibilityScreenPoint(for: point, screenFrames: NSScreen.screens.map(\.frame))
    }

    nonisolated func accessibilityScreenPoint(
        for point: NSPoint,
        screenFrames: [NSRect]
    ) -> CGPoint? {
        Self.coreGraphicsScreenPoint(for: point, screenFrames: screenFrames)
    }

    /// Convert a global AppKit point into Quartz global coordinates used by CGEvent APIs.
    /// The first NSScreen is the menu-bar display and defines the global coordinate origin.
    static func coreGraphicsScreenPoint(for point: NSPoint) -> CGPoint? {
        coreGraphicsScreenPoint(for: point, screenFrames: NSScreen.screens.map(\.frame))
    }

    nonisolated static func coreGraphicsScreenPoint(
        for point: NSPoint,
        screenFrames: [NSRect]
    ) -> CGPoint? {
        guard let primaryScreenFrame = screenFrames.first else { return nil }
        return CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }

    /// Convert Quartz's top-left global event coordinates back into AppKit's
    /// bottom-left global coordinate space.
    static func appKitScreenPoint(for point: CGPoint) -> NSPoint? {
        appKitScreenPoint(for: point, screenFrames: NSScreen.screens.map(\.frame))
    }

    nonisolated static func appKitScreenPoint(
        for point: CGPoint,
        screenFrames: [NSRect]
    ) -> NSPoint? {
        guard let primaryScreenFrame = screenFrames.first else { return nil }
        return NSPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }
    
    func startWatchdog() {
        permissionWatchdog?.invalidate()
        // Only run watchdog if we CURRENTLY have permission.
        guard isAccessibilityEnabled else { return }
        
        permissionWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isAccessibilityEnabled else { return }
                self.stopWatchdog()
                self.onPermissionLost?()
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
        let options = ["AXTrustedCheckOptionPrompt" as CFString: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Prompt user to grant accessibility permission
    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
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
        return selectedText(from: element)
    }

    func selectedText(from element: AXUIElement) -> String? {
        guard Self.protectionAssessment(for: element) == .unprotected else { return nil }

        // Get the selected text from the focused element
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        guard textResult == .success, let text = selectedText as? String else { return nil }
        
        // Keep the exact selection payload while treating whitespace-only
        // selections as empty.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    func currentSelectionSnapshot() -> SelectionSnapshot? {
        guard isAccessibilityEnabled else { return nil }
        guard !isSecureEventInputEnabled() else { return nil }
        guard let element = getFocusedElement() else { return nil }
        return currentSelectionSnapshot(for: element)
    }

    func currentSelectionSnapshot(for element: AXUIElement) -> SelectionSnapshot? {
        Self.selectionSnapshot(for: element)
    }

    nonisolated private static func selectionSnapshot(
        for element: AXUIElement
    ) -> SelectionSnapshot? {
        guard Self.protectionAssessment(for: element) == .unprotected else { return nil }

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
            selectedText = trimmed.isEmpty ? nil : text
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

    nonisolated static func didSelectionChange(
        from previous: SelectionSnapshot?,
        to current: SelectionSnapshot?
    ) -> Bool {
        let previousText = previous?.usableText
        let currentText = current?.usableText
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
        return isSelectionEditable(focusedElement)
    }

    func isSelectionEditable(_ focusedElement: AXUIElement) -> Bool {
        Self.selectionEditable(focusedElement)
    }

    nonisolated private static func selectionEditable(
        _ focusedElement: AXUIElement
    ) -> Bool {
        guard Self.protectionAssessment(for: focusedElement) == .unprotected else { return false }

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
    
    nonisolated static func shouldContinueCopyFallback(
        requestIsActive: Bool,
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        isSelectionSuppressed: Bool,
        focusedElementMatches: Bool
    ) -> Bool {
        guard requestIsActive,
              !isSelectionSuppressed,
              focusedElementMatches else {
            return false
        }
        return isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        )
    }

    nonisolated static func copyFallbackFocusedElementMatches(
        expectedFocusedElementAvailable: Bool,
        focusedElementMatches: Bool,
        allowMissingFocusedElement: Bool,
        acquiredSelectionContextMatches: Bool? = nil
    ) -> Bool {
        if let acquiredSelectionContextMatches {
            return acquiredSelectionContextMatches
        }
        if expectedFocusedElementAvailable {
            return focusedElementMatches
        }
        return allowMissingFocusedElement
    }

    nonisolated static func shouldPostCopyFallbackEvents(
        contextIsValidAfterSnapshot: Bool,
        initialPasteboardState: PasteboardState,
        currentPasteboardState: PasteboardState?
    ) -> Bool {
        contextIsValidAfterSnapshot &&
            currentPasteboardState == initialPasteboardState
    }

    nonisolated static func isExpectedCopyFallbackProcess(
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
        expectedFocusedElement: AXUIElement? = nil,
        expectedFocusedElementAssessment: ProtectedTextAssessment? = nil,
        allowMissingFocusedElement: Bool = false,
        expectedBundleID: String? = nil,
        expectedWindowID: CGWindowID? = nil,
        allowsAcquiredSelectionFocusFallback: Bool = false,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) -> UUID {
        let requestID = copyFallbackCoordinator.beginRequest()
        let coordinator = copyFallbackCoordinator
        let requestExpectedFocusedElement = expectedFocusedElement ??
            (allowMissingFocusedElement ? nil : getFocusedElement(
                expectedProcessIdentifier: expectedProcessIdentifier
            ))
        let requestAllowsMissingFocusedElement =
            requestExpectedFocusedElement == nil && allowMissingFocusedElement
        let requestFocusedElementAssessment = expectedFocusedElementAssessment ??
            requestExpectedFocusedElement.map { Self.protectionAssessment(for: $0) }
        guard !Self.shouldSuppressCopyFallback(
            focusedElementAssessment: requestFocusedElementAssessment,
            secureEventInputEnabled: isSecureEventInputEnabled(),
            accessibilityEnabled: isAccessibilityEnabled,
            allowMissingFocusedElement: requestAllowsMissingFocusedElement
        ) else {
            Self.finishCopyFallbackRequest(
                coordinator: coordinator,
                requestID,
                result: nil,
                completion: completion
            )
            return requestID
        }
        let transferredExpectedFocusedElement = requestExpectedFocusedElement.map {
            TransferredAXElement(value: $0)
        }

        copyFallbackQueue.async {
            // Give the user ~50ms to lift their fingers from the global hotkey
            // so physical modifiers (like Option/Control) don't turn Cmd+C into Option+Cmd+C
            usleep(useconds_t(Self.copyFallbackPreflightDelay * 1_000_000))

            guard let targetProcessIdentifier = expectedProcessIdentifier,
                  Self.copyFallbackContextIsValid(
                coordinator: coordinator,
                requestID: requestID,
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedFocusedElement: transferredExpectedFocusedElement?.value,
                allowMissingFocusedElement: requestAllowsMissingFocusedElement,
                expectedWindowID: expectedWindowID
            ) else {
                Self.finishCopyFallbackRequest(
                    coordinator: coordinator,
                    requestID,
                    result: nil,
                    completion: completion
                )
                return
            }
            
            let pasteboard = NSPasteboard.general
            guard let initialState = Self.stablePasteboardState(from: pasteboard) else {
                Self.finishCopyFallbackRequest(
                    coordinator: coordinator,
                    requestID,
                    result: nil,
                    completion: completion
                )
                return
            }
            guard let snapshot = Self.capturePasteboardSnapshot(from: pasteboard) else {
                NSLog("[ActionHalo] Skipping Cmd+C fallback because the clipboard cannot be snapshotted safely.")
                Self.finishCopyFallbackRequest(
                    coordinator: coordinator,
                    requestID,
                    result: nil,
                    completion: completion
                )
                return
            }
            defer {
                snapshot.discardTemporaryFiles()
            }

            // Simulate Cmd+C via CGEvent
            let source = CGEventSource(stateID: .hidSystemState)
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(8), keyDown: true)
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(8), keyDown: false)

            cmdDown?.flags = .maskCommand
            cmdUp?.flags = .maskCommand

            // Snapshotting may spill a large clipboard to disk. Revalidate both
            // the pasteboard and original target immediately before sending
            // synthetic input so a cancelled or stale request cannot type into
            // the application that used to be frontmost.
            let pasteboardStateAfterSnapshot = Self.stablePasteboardState(from: pasteboard)
            let contextIsValidAfterSnapshot = Self.copyFallbackContextIsValid(
                coordinator: coordinator,
                requestID: requestID,
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedFocusedElement: transferredExpectedFocusedElement?.value,
                allowMissingFocusedElement: requestAllowsMissingFocusedElement,
                expectedWindowID: expectedWindowID
            )
            guard Self.shouldPostCopyFallbackEvents(
                contextIsValidAfterSnapshot: contextIsValidAfterSnapshot,
                initialPasteboardState: initialState,
                currentPasteboardState: pasteboardStateAfterSnapshot
            ) else {
                Self.finishCopyFallbackRequest(
                    coordinator: coordinator,
                    requestID,
                    result: nil,
                    completion: completion
                )
                return
            }

            cmdDown?.postToPid(targetProcessIdentifier)
            usleep(useconds_t(Self.copyFallbackKeyGap * 1_000_000))
            cmdUp?.postToPid(targetProcessIdentifier)
            
            // Wait for Electron/Chromium/WebView apps to detect the event, process the DOM,
            // and asynchronously write to the pasteboard.
            var copyObservation = Self.pollPasteboardForCopiedText(
                pasteboard: pasteboard,
                initialState: initialState,
                attempts: Self.copyFallbackPollAttempts
            )

            if !copyObservation.hasFreshCopiedText {
                copyObservation = Self.pollPasteboardForCopiedText(
                    pasteboard: pasteboard,
                    initialState: initialState,
                    startingState: copyObservation.state,
                    attempts: Self.copyFallbackLatePollAttempts
                )
            }
            
            // Restore only a single, still-current pasteboard generation. macOS
            // exposes no writer identity, so multi-generation clipboard-manager
            // rewrites are ambiguous and must be left untouched.
            if let currentState = Self.stablePasteboardState(from: pasteboard),
               Self.shouldRestorePasteboardSnapshot(
                initialState: initialState,
                observedState: copyObservation.state,
                currentState: currentState
               ) {
                if !Self.restorePasteboardSnapshot(
                    snapshot,
                    to: pasteboard,
                    ifCurrentStateMatches: currentState
                ) {
                    NSLog("[ActionHalo] Failed to restore the clipboard after Cmd+C fallback.")
                }
            }
            
            // Synthetic input remains strictly bound to the original focused
            // element. Only after fresh copied text exists may Telegram's
            // Monterey AX focus degrade to the same owning AXWindow.
            let contextIsStillValid = Self.copyFallbackContextIsValid(
                coordinator: coordinator,
                requestID: requestID,
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedFocusedElement: transferredExpectedFocusedElement?.value,
                allowMissingFocusedElement: requestAllowsMissingFocusedElement,
                expectedBundleID: expectedBundleID,
                expectedWindowID: expectedWindowID,
                allowsAcquiredSelectionFocusFallback:
                    allowsAcquiredSelectionFocusFallback && copyObservation.hasFreshCopiedText
            )
            let result = Self.copyFallbackResult(
                copiedText: copyObservation.copiedText,
                hasFreshCopiedText: copyObservation.hasFreshCopiedText,
                contextIsValid: contextIsStillValid
            )

            Self.finishCopyFallbackRequest(
                coordinator: coordinator,
                requestID,
                result: result,
                completion: completion
            )
        }

        return requestID
    }

    func cancelSelectedTextViaCopy(_ requestID: UUID) {
        copyFallbackCoordinator.cancelRequest(requestID)
    }

    func cancelActiveSelectedTextViaCopy() {
        copyFallbackCoordinator.cancelActiveRequest()
    }

    nonisolated private static func copyFallbackContextIsValid(
        coordinator: CopyFallbackRequestCoordinator,
        requestID: UUID,
        expectedProcessIdentifier: pid_t?,
        expectedFocusedElement: AXUIElement?,
        allowMissingFocusedElement: Bool,
        expectedBundleID: String? = nil,
        expectedWindowID: CGWindowID? = nil,
        allowsAcquiredSelectionFocusFallback: Bool = false
    ) -> Bool {
        guard coordinator.isRequestActive(requestID),
              let expectedProcessIdentifier else {
            return false
        }
        let currentFocusedElement = focusedElementForCopyFallbackWithRetry(
            processIdentifier: expectedProcessIdentifier,
            retryDelays: expectedFocusedElement == nil && allowMissingFocusedElement
                ? []
                : focusedElementRetryDelays,
            isAccepted: { candidate in
                guard let expectedFocusedElement else {
                    return allowMissingFocusedElement
                }
                if areSameAccessibilityElement(expectedFocusedElement, candidate) {
                    return protectionAssessment(for: candidate) == .unprotected
                }
                guard allowsAcquiredSelectionFocusFallback,
                      expectedBundleID?.lowercased() == "ru.keepcoder.telegram",
                      isStructuralSelectionFocusElement(candidate) else {
                    return false
                }
                return areSameAccessibilityElement(
                    selectionWindowElement(for: expectedFocusedElement),
                    selectionWindowElement(for: candidate)
                ) && protectionAssessment(for: candidate) == .unprotected
            },
            shouldContinue: {
                coordinator.isRequestActive(requestID) &&
                    frontmostProcessIdentifierOnMainActor() ==
                        expectedProcessIdentifier
            }
        )
        guard coordinator.isRequestActive(requestID) else { return false }
        let currentProcessIdentifier = frontmostProcessIdentifierOnMainActor()
        let currentWindowID = TextSelectionMonitor.currentFrontmostWindowSnapshot(
            frontmostProcessID: currentProcessIdentifier
        )?.windowID
        if let expectedWindowID, currentWindowID != expectedWindowID {
            return false
        }

        let focusedElementMatches = areSameAccessibilityElement(
            expectedFocusedElement,
            currentFocusedElement
        )
        let needsStructuralFocusFallback =
            expectedFocusedElement != nil && !focusedElementMatches
        let acquiredSelectionContextMatches = allowsAcquiredSelectionFocusFallback
            ? TextSelectionMonitor.shouldContinueAcquiredSelectionPresentation(
                expectedProcessIdentifier: expectedProcessIdentifier,
                currentProcessIdentifier: currentProcessIdentifier,
                bundleID: expectedBundleID,
                expectedFocusedElementAvailable: expectedFocusedElement != nil,
                currentFocusedElementAvailable: currentFocusedElement != nil,
                focusedElementMatches: focusedElementMatches,
                currentFocusedElementIsStructural:
                    needsStructuralFocusFallback &&
                    isStructuralSelectionFocusElement(currentFocusedElement),
                focusedWindowMatches: needsStructuralFocusFallback &&
                    areSameAccessibilityElement(
                        selectionWindowElement(for: expectedFocusedElement),
                        selectionWindowElement(for: currentFocusedElement)
                    ),
                expectedWindowID: expectedWindowID,
                currentWindowID: currentWindowID
            )
            : nil
        let focusedElementAssessment: ProtectedTextAssessment?
        if currentFocusedElement != nil, expectedFocusedElement != nil {
            // The bounded resolver accepts a captured-focus candidate only
            // after its protection chain reads as unprotected. Re-reading it
            // here would reintroduce the one-shot AX false negative we just
            // eliminated.
            focusedElementAssessment = .unprotected
        } else {
            focusedElementAssessment = currentFocusedElement.map {
                protectionAssessment(for: $0)
            }
        }
        let isSelectionSuppressed = shouldSuppressCopyFallback(
            focusedElementAssessment: focusedElementAssessment,
            secureEventInputEnabled: IsSecureEventInputEnabled(),
            accessibilityEnabled: AXIsProcessTrusted(),
            allowMissingFocusedElement: allowMissingFocusedElement
        )
        let focusedElementContextMatches = copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: expectedFocusedElement != nil,
            focusedElementMatches: focusedElementMatches,
            allowMissingFocusedElement: allowMissingFocusedElement,
            acquiredSelectionContextMatches: acquiredSelectionContextMatches
        )
        return shouldContinueCopyFallback(
            requestIsActive: coordinator.isRequestActive(requestID),
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            isSelectionSuppressed: isSelectionSuppressed,
            focusedElementMatches: focusedElementContextMatches
        )
    }

    nonisolated private static func focusedElementForCopyFallbackWithRetry(
        processIdentifier: pid_t,
        retryDelays: [TimeInterval] = focusedElementRetryDelays,
        isAccepted: (AXUIElement) -> Bool,
        shouldContinue: () -> Bool
    ) -> AXUIElement? {
        resolveSynchronousCandidateWithRetry(
            retryDelays: retryDelays,
            lookup: {
                guard shouldContinue() else { return nil }
                let application = AXUIElementCreateApplication(processIdentifier)
                _ = AXUIElementSetMessagingTimeout(
                    application,
                    accessibilityMessagingTimeout
                )
                guard let focusedElement = focusedElement(
                    fromApplication: application,
                    expectedProcessIdentifier: processIdentifier
                ), element(focusedElement, belongsTo: processIdentifier) else {
                    return nil
                }
                return focusedElement
            },
            isAccepted: isAccepted,
            shouldContinue: shouldContinue,
            wait: { delay in
                guard delay >= 0, shouldContinue() else { return false }
                usleep(useconds_t(delay * 1_000_000))
                return shouldContinue()
            }
        )
    }

    nonisolated static func resolveSynchronousCandidateWithRetry<Candidate>(
        retryDelays: [TimeInterval],
        lookup: () -> Candidate?,
        isAccepted: (Candidate) -> Bool,
        shouldContinue: () -> Bool,
        wait: (TimeInterval) -> Bool
    ) -> Candidate? {
        for attemptIndex in 0...retryDelays.count {
            guard shouldContinue() else { return nil }
            if let candidate = lookup(), isAccepted(candidate) {
                return candidate
            }

            guard attemptIndex < retryDelays.count,
                  wait(retryDelays[attemptIndex]) else {
                break
            }
        }
        return nil
    }

    nonisolated private static func frontmostProcessIdentifierOnMainActor() -> pid_t? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
        }
        return DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    nonisolated private static func finishCopyFallbackRequest(
        coordinator: CopyFallbackRequestCoordinator,
        _ requestID: UUID,
        result: String?,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        Task { @MainActor in
            let isLatestRequest = coordinator.completeRequestIfActive(requestID)
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
        guard isAccessibilityEnabled else { return true }
        guard let focusedElement = getFocusedElement() else { return true }
        return Self.protectionAssessment(for: focusedElement) != .unprotected
    }

    func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    func shouldSuppressSelectionPresentation(
        allowMissingFocusedElement: Bool = false,
        expectedProcessIdentifier: pid_t? = nil
    ) -> Bool {
        let accessibilityEnabled = isAccessibilityEnabled
        let focusedElement = accessibilityEnabled
            ? getFocusedElement(expectedProcessIdentifier: expectedProcessIdentifier)
            : nil
        return shouldSuppressSelectionPresentation(
            focusedElement: focusedElement,
            allowMissingFocusedElement: allowMissingFocusedElement,
            accessibilityEnabled: accessibilityEnabled
        )
    }

    func shouldSuppressSelectionPresentation(
        focusedElement: AXUIElement?,
        allowMissingFocusedElement: Bool = false,
        accessibilityEnabled: Bool? = nil
    ) -> Bool {
        let accessibilityEnabled = accessibilityEnabled ?? isAccessibilityEnabled
        let focusedElementAssessment = focusedElement.map {
            Self.protectionAssessment(for: $0)
        }
        return Self.shouldSuppressCopyFallback(
            focusedElementAssessment: focusedElementAssessment,
            secureEventInputEnabled: isSecureEventInputEnabled(),
            accessibilityEnabled: accessibilityEnabled,
            allowMissingFocusedElement: allowMissingFocusedElement
        )
    }

    nonisolated static func capturePasteboardSnapshot(
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
    nonisolated static func restorePasteboardSnapshot(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ifCurrentStateMatches expectedCurrentState: PasteboardState? = nil,
        rollbackMaxBytes: Int = maximumPasteboardSnapshotBytes
    ) -> Bool {
        guard let restoredContents = materializedPasteboardContents(from: snapshot) else {
            return false
        }

        if let expectedCurrentState,
           stablePasteboardState(from: pasteboard) != expectedCurrentState {
            return false
        }

        // Capturing the temporary Cmd+C result is only a best-effort rollback.
        // A huge or delayed result must never prevent restoring the user's
        // original clipboard snapshot.
        let rollbackSnapshot = capturePasteboardSnapshot(
            from: pasteboard,
            maxBytes: rollbackMaxBytes
        )
        defer { rollbackSnapshot?.discardTemporaryFiles() }
        let rollbackContents = rollbackSnapshot.flatMap(materializedPasteboardContents)

        // Snapshot materialization can invoke lazy data providers. Recheck ownership immediately
        // before replacing the pasteboard so a newer third-party write wins.
        if let expectedCurrentState,
           stablePasteboardState(from: pasteboard) != expectedCurrentState {
            return false
        }

        guard replacePasteboardContents(with: restoredContents, on: pasteboard) else {
            if let rollbackContents {
                _ = replacePasteboardContents(with: rollbackContents, on: pasteboard)
            }
            return false
        }
        return true
    }

    nonisolated private static func materializedPasteboardContents(
        from snapshot: PasteboardSnapshot
    ) -> MaterializedPasteboardContents? {
        var restoredItems: [NSPasteboardItem] = []
        var dataProviders: [PasteboardSnapshotDataProvider] = []
        restoredItems.reserveCapacity(snapshot.items.count)

        for itemSnapshot in snapshot.items {
            let item = NSPasteboardItem()
            var spilledFiles: [NSPasteboard.PasteboardType: URL] = [:]

            for (type, payload) in itemSnapshot {
                switch payload {
                case .memory(let inMemoryData):
                    guard item.setData(inMemoryData, forType: type) else {
                        return nil
                    }
                case .file(let fileURL):
                    guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                        return nil
                    }
                    spilledFiles[type] = fileURL
                }
            }

            if !spilledFiles.isEmpty {
                guard let fileStore = snapshot.fileStore,
                      let lease = fileStore.makeLease() else {
                    return nil
                }
                let provider = PasteboardSnapshotDataProvider(
                    filesByType: spilledFiles,
                    fileStoreLease: lease
                )
                item.setDataProvider(provider, forTypes: Array(spilledFiles.keys))
                dataProviders.append(provider)
            }

            restoredItems.append(item)
        }

        return MaterializedPasteboardContents(
            items: restoredItems,
            dataProviders: dataProviders
        )
    }

    nonisolated private static func replacePasteboardContents(
        with contents: MaterializedPasteboardContents,
        on pasteboard: NSPasteboard
    ) -> Bool {
        contents.activateDataProviders()
        pasteboard.clearContents()
        guard !contents.items.isEmpty else {
            contents.cancelDataProviders()
            return true
        }
        guard pasteboard.writeObjects(contents.items) else {
            contents.cancelDataProviders()
            return false
        }
        return true
    }

    private struct CopyObservation {
        let state: PasteboardState
        let hasFreshCopiedText: Bool

        var copiedText: String? {
            state.string
        }
    }

    nonisolated static func stablePasteboardState(
        maximumAttempts: Int = pasteboardStableReadAttempts,
        readChangeCount: () -> Int,
        readString: () -> String?
    ) -> PasteboardState? {
        guard maximumAttempts > 0 else { return nil }

        for _ in 0..<maximumAttempts {
            let changeCountBeforeRead = readChangeCount()
            let string = readString()
            let changeCountAfterRead = readChangeCount()
            if changeCountBeforeRead == changeCountAfterRead {
                return PasteboardState(changeCount: changeCountAfterRead, string: string)
            }
        }

        return nil
    }

    nonisolated private static func stablePasteboardState(
        from pasteboard: NSPasteboard
    ) -> PasteboardState? {
        stablePasteboardState(
            readChangeCount: { pasteboard.changeCount },
            readString: { pasteboard.string(forType: .string) }
        )
    }

    nonisolated private static func pollPasteboardForCopiedText(
        pasteboard: NSPasteboard,
        initialState: PasteboardState,
        startingState: PasteboardState? = nil,
        attempts: Int = copyFallbackPollAttempts
    ) -> CopyObservation {
        var latestState = startingState ?? initialState
        var stableFreshCandidate = StableFreshPasteboardCandidate()

        for _ in 0..<attempts {
            usleep(useconds_t(copyFallbackPollInterval * 1_000_000))
            guard let state = stablePasteboardState(from: pasteboard) else {
                continue
            }
            latestState = state

            if stableFreshCandidate.observe(state, relativeTo: initialState) {
                return CopyObservation(
                    state: state,
                    hasFreshCopiedText: true
                )
            }
        }

        return CopyObservation(
            state: latestState,
            hasFreshCopiedText: false
        )
    }

    nonisolated static func shouldTreatCopiedTextAsFresh(
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

    nonisolated static func shouldRestorePasteboardSnapshot(
        initialState: PasteboardState,
        observedState: PasteboardState,
        currentState: PasteboardState
    ) -> Bool {
        // A normal pasteboard ownership handoff advances changeCount once.
        // Refuse multi-hop mutations even when their final value stayed stable.
        let (expectedCopyGeneration, overflowed) =
            initialState.changeCount.addingReportingOverflow(1)
        guard !overflowed,
              observedState.changeCount == expectedCopyGeneration else {
            return false
        }
        return currentState == observedState
    }

    nonisolated static func copyFallbackResult(
        copiedText: String?,
        hasFreshCopiedText: Bool,
        contextIsValid: Bool
    ) -> String? {
        guard contextIsValid, hasFreshCopiedText,
              let copiedText,
              !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return copiedText
    }

    nonisolated static func shouldAssumeFocusedTextInputContainsClickWhenBoundsUnavailable() -> Bool {
        false
    }

    nonisolated static func isLikelyRichTextSelectionHost(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let normalizedBundleID = bundleID.lowercased()
        if richTextHostBundleExactHints.contains(normalizedBundleID) {
            return true
        }

        return !bundleTokens(for: normalizedBundleID).intersection(richTextHostBundleTokenHints).isEmpty
    }

    nonisolated static func shouldAllowBlindCopyFallback(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let normalizedBundleID = bundleID.lowercased()
        if blindCopyFallbackBundleExactHints.contains(normalizedBundleID) {
            return true
        }

        return !bundleTokens(for: normalizedBundleID).intersection(blindCopyFallbackBundleTokenHints).isEmpty
    }

    nonisolated static func shouldAllowContextlessBlindCopyFallback(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return blindCopyFallbackBundleExactHints.contains(bundleID.lowercased())
    }

    nonisolated private static func bundleTokens(for normalizedBundleID: String) -> Set<String> {
        Set(
            normalizedBundleID
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    nonisolated static func shouldTreatFocusedRoleAsTextSelectionContext(
        role: String,
        ancestorRoles: [String],
        bundleID: String?
    ) -> Bool {
        let allowedRoles = [
            kAXStaticTextRole,
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
            "AXDocument",
            "AXSearchField",
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
        guard let focusedElement = getFocusedElement() else { return false }
        return isFocusedTextSelectionContext(at: point, focusedElement: focusedElement)
    }

    func isFocusedTextSelectionContext(
        at point: NSPoint,
        focusedElement: AXUIElement
    ) -> Bool {
        guard Self.protectionAssessment(for: focusedElement) == .unprotected else { return false }

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

        return isPoint(point, inside: focusedElement)
    }

    func isPointInsideFocusedElementBounds(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let focusedElement = getFocusedElement() else { return false }
        return isPointInsideFocusedElementBounds(at: point, focusedElement: focusedElement)
    }

    func isPointInsideFocusedElementBounds(
        at point: NSPoint,
        focusedElement: AXUIElement
    ) -> Bool {
        guard Self.protectionAssessment(for: focusedElement) == .unprotected else { return false }
        return isPoint(point, inside: focusedElement)
    }

    private func isPoint(_ point: NSPoint, inside element: AXUIElement) -> Bool {
        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        guard let frame = frame(of: element) else { return false }
        return frame.contains(axPoint)
    }

    func frame(of element: AXUIElement?) -> CGRect? {
        Self.frameOfElement(element)
    }

    nonisolated private static func frameOfElement(
        _ element: AXUIElement?
    ) -> CGRect? {
        guard let element else { return nil }
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }
    
    /// Check if the element at the specified screen coordinates is a text input field
    func isTextInputElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }
        
        // 1. Get the globally focused element instead of hit-testing.
        // Hit-testing often returns low-level items like AXGroup or AXStaticText which breaks the logic.
        guard let focusedElement = getFocusedElement() else { return false }
        return isTextInputElement(at: point, focusedElement: focusedElement)
    }

    func isTextInputElement(
        at point: NSPoint,
        focusedElement: AXUIElement
    ) -> Bool {
        guard Self.protectionAssessment(for: focusedElement) == .unprotected else { return false }
        
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
        
        if forbiddenRoles.contains(role) { return false }
        
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
        
        guard isEditableText else { return false }
        
        // 4. Verify the click fell INSIDE the element's bounds to avoid false positives when clicking out
        return isPoint(point, inside: focusedElement)
    }
    
    /// Check if the element at the specified screen coordinates is purely text (like a webpage paragraph, a text field, or static text label),
    /// specifically excluding structural elements like Finder rows, cells, or images that get double-clicked.
    func isTextElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        return Self.textElementAssessment(
            atAccessibilityPoint: axPoint,
            systemWideElement: systemWideElement,
            bundleID: getFocusedAppBundleID()
        ) ?? false
    }

    nonisolated private static func textElementAssessment(
        atAccessibilityPoint point: CGPoint,
        systemWideElement: AXUIElement,
        bundleID: String?
    ) -> Bool? {
        var hitElementRaw: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElementRaw
        )

        guard hitResult == .success, let hitElement = hitElementRaw else { return nil }
        let hitProtection = Self.protectionAssessment(for: hitElement)
        guard hitProtection != .indeterminate else { return nil }
        guard hitProtection == .unprotected else { return false }

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            hitElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else { return nil }
        let ancestorRoles = Self.ancestorRoles(for: hitElement)

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

        if Self.shouldTreatElementAsText(
            role: role,
            ancestorRoles: ancestorRoles,
            bundleID: bundleID,
            allowedRoles: allowedRoles,
            forbiddenRoles: forbiddenRoles
        ) {
            return true
        }

        if role == "AXGroup",
           Self.isLikelyRichTextSelectionHost(bundleID: bundleID) {
            return true
        }

        return false
    }

    nonisolated private static func focusedElementAssessment(
        for focusedElement: AXUIElement,
        systemWideElement: AXUIElement,
        bundleID: String?,
        accessibilityPoints: [CGPoint]
    ) -> FocusedElementAssessment {
        let protection = protectionAssessment(for: focusedElement)
        guard protection == .unprotected else {
            return FocusedElementAssessment(
                protection: protection,
                isSelectionEditable: false,
                selectionSnapshot: nil,
                pointAssessments: accessibilityPoints.map { _ in
                    PointSelectionAssessment(
                        isTextSelectionContext: false,
                        isInsideFocusedElementBounds: false,
                        isResolved: protection == .protectedContent
                    )
                }
            )
        }

        let focusedFrame = frameOfElement(focusedElement)
        var roleValue: AnyObject?
        let role = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success ? roleValue as? String : nil
        let ancestorRoles = ancestorRoles(for: focusedElement)
        let focusedRoleIsTextContext = role.map {
            shouldTreatFocusedRoleAsTextSelectionContext(
                role: $0,
                ancestorRoles: ancestorRoles,
                bundleID: bundleID
            )
        }
        let pointAssessments = accessibilityPoints.map { point in
            let isInsideFocusedElementBounds = focusedFrame?.contains(point) ?? false
            let focusedContextAssessment: Bool?
            if let focusedRoleIsTextContext {
                focusedContextAssessment = focusedRoleIsTextContext
                    ? focusedFrame.map { $0.contains(point) }
                    : false
            } else {
                focusedContextAssessment = nil
            }
            let hitContextAssessment = textElementAssessment(
                atAccessibilityPoint: point,
                systemWideElement: systemWideElement,
                bundleID: bundleID
            )
            let isTextSelectionContext =
                hitContextAssessment == true || focusedContextAssessment == true
            return PointSelectionAssessment(
                isTextSelectionContext: isTextSelectionContext,
                isInsideFocusedElementBounds: isInsideFocusedElementBounds,
                isResolved: isTextSelectionContext ||
                    (hitContextAssessment != nil && focusedContextAssessment != nil)
            )
        }

        return FocusedElementAssessment(
            protection: protection,
            isSelectionEditable: selectionEditable(focusedElement),
            selectionSnapshot: selectionSnapshot(for: focusedElement),
            pointAssessments: pointAssessments
        )
    }
    
    nonisolated static func resolveFocusedElement(
        frontmostProcessIdentifier: pid_t?,
        systemWideLookup: () -> AXUIElement?,
        directApplicationLookup: (pid_t) -> AXUIElement?,
        candidateBelongsToProcess: (AXUIElement, pid_t) -> Bool,
        isProcessStillFrontmost: (pid_t) -> Bool
    ) -> AXUIElement? {
        guard let frontmostProcessIdentifier,
              isProcessStillFrontmost(frontmostProcessIdentifier) else {
            return nil
        }

        let focusedElement: AXUIElement?
        if let systemWideCandidate = systemWideLookup(),
           candidateBelongsToProcess(systemWideCandidate, frontmostProcessIdentifier) {
            focusedElement = systemWideCandidate
        } else if let directCandidate = directApplicationLookup(frontmostProcessIdentifier),
                  candidateBelongsToProcess(directCandidate, frontmostProcessIdentifier) {
            focusedElement = directCandidate
        } else {
            focusedElement = nil
        }

        guard isProcessStillFrontmost(frontmostProcessIdentifier) else { return nil }
        return focusedElement
    }

    static func resolveFocusedElementWithRetry(
        retryDelays: [TimeInterval],
        lookup: () -> AXUIElement?,
        wait: (TimeInterval) async -> Bool
    ) async -> AXUIElement? {
        guard !Task.isCancelled else { return nil }
        if let focusedElement = lookup() {
            return focusedElement
        }

        for delay in retryDelays {
            guard !Task.isCancelled else { return nil }
            guard await wait(delay) else { return nil }
            guard !Task.isCancelled else { return nil }
            if let focusedElement = lookup() {
                return focusedElement
            }
        }
        return nil
    }

    static func resolveCandidateWithRetry<Candidate: Sendable>(
        retryDelays: [TimeInterval],
        lookup: () async -> Candidate?,
        validate: (Candidate) async -> RetryDisposition,
        isContextCurrent: () -> Bool = { true },
        wait: (TimeInterval) async -> Bool
    ) async -> Candidate? {
        var candidate: Candidate?

        for attemptIndex in 0...retryDelays.count {
            guard !Task.isCancelled, isContextCurrent() else { return nil }
            if candidate == nil {
                guard !Task.isCancelled else { return nil }
                candidate = await lookup()
                guard !Task.isCancelled, isContextCurrent() else { return nil }
            }

            if let candidateToValidate = candidate {
                guard !Task.isCancelled else { return nil }
                let disposition = await validate(candidateToValidate)
                guard !Task.isCancelled, isContextCurrent() else { return nil }
                switch disposition {
                case .accept:
                    return candidateToValidate
                case .retry:
                    break
                case .retryLookup:
                    candidate = nil
                case .reject:
                    return nil
                }
            }

            guard attemptIndex < retryDelays.count else { break }
            guard !Task.isCancelled else { return nil }
            guard await wait(retryDelays[attemptIndex]) else { return nil }
            guard !Task.isCancelled else { return nil }
        }

        return nil
    }

    /// Focus and its assessment must come from the same fresh lookup. Always
    /// consume the final configured attempt so a stale, non-nil AX focus (which
    /// can even carry an old selection) cannot win before macOS publishes the
    /// newly focused text element. A protected result is terminal and fails
    /// closed immediately. Its closures stay on MainActor so generic pairs
    /// containing AX proxies never cross an executor boundary.
    static func resolveFreshAssessedCandidateWithRetry<Candidate, Assessment>(
        retryDelays: [TimeInterval],
        recoveryRetryDelays: [TimeInterval] = [],
        attempt: @MainActor () async -> (
            candidate: Candidate,
            assessment: Assessment
        )?,
        isTerminal: @MainActor (Assessment) -> Bool,
        isRetryable: @MainActor (Assessment) -> Bool = { _ in false },
        isContextCurrent: @MainActor () -> Bool = { true },
        wait: @MainActor (TimeInterval) async -> Bool
    ) async -> (candidate: Candidate, assessment: Assessment)? {
        for attemptIndex in 0...retryDelays.count {
            guard !Task.isCancelled, isContextCurrent() else { return nil }
            let result = await attempt()
            guard !Task.isCancelled, isContextCurrent() else { return nil }

            if let result, isTerminal(result.assessment) {
                return result
            }
            guard attemptIndex < retryDelays.count else {
                if let result, !isRetryable(result.assessment) {
                    return result
                }
                break
            }
            guard await wait(retryDelays[attemptIndex]) else { return nil }
        }

        // The required final sample may itself hit a transient AX timeout.
        // Give that state a separate bounded recovery budget, but never fall
        // back to an older pair if all fresh recovery attempts remain unusable.
        for delay in recoveryRetryDelays {
            guard !Task.isCancelled, isContextCurrent() else { return nil }
            guard await wait(delay) else { return nil }
            guard !Task.isCancelled, isContextCurrent() else { return nil }
            guard let result = await attempt() else { continue }
            guard !Task.isCancelled, isContextCurrent() else { return nil }
            if isTerminal(result.assessment) || !isRetryable(result.assessment) {
                return result
            }
        }

        return nil
    }

    func assessFocusedElement(
        _ focusedElement: AXUIElement,
        expectedProcessIdentifier: pid_t? = nil,
        bundleID: String? = nil,
        points: [NSPoint] = [],
        requireUsableSelection: Bool = false,
        retryDelays: [TimeInterval] = AccessibilityManager.focusedElementRetryDelays
    ) async -> AssessedFocusedElement? {
        guard !Task.isCancelled else { return nil }
        if let expectedProcessIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier !=
            expectedProcessIdentifier {
            return nil
        }
        let accessibilityPoints = points.compactMap {
            Self.coreGraphicsScreenPoint(for: $0)
        }
        guard accessibilityPoints.count == points.count else { return nil }

        let session = ElementAssessmentSession(
            focusedElement: TransferredAXElement(value: focusedElement)
        )
        guard let transferred = await session.resolve(
            bundleID: bundleID,
            accessibilityPoints: accessibilityPoints,
            requireUsableSelection: requireUsableSelection,
            retryDelays: retryDelays
        ), !Task.isCancelled else {
            return nil
        }
        if let expectedProcessIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier !=
            expectedProcessIdentifier {
            return nil
        }
        return AssessedFocusedElement(
            focusedElement: focusedElement,
            selectionWindow: transferred.selectionWindow,
            assessment: transferred.assessment
        )
    }

    func resolveAssessedFocusedElementWithRetry(
        expectedProcessIdentifier: pid_t? = nil,
        windowConstraint: FocusedWindowConstraint? = nil,
        bundleID: String? = nil,
        points: [NSPoint] = [],
        requireUsableSelection: Bool = false,
        retryDelays: [TimeInterval] = AccessibilityManager.focusedElementRetryDelays
    ) async -> AssessedFocusedElement? {
        let targetProcessIdentifier = expectedProcessIdentifier ??
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let targetProcessIdentifier else { return nil }

        let result: (
            candidate: AXUIElement,
            assessment: AssessedFocusedElement
        )? = await Self.resolveFreshAssessedCandidateWithRetry(
            retryDelays: retryDelays,
            recoveryRetryDelays:
                AccessibilityManager.focusedElementRecoveryRetryDelays,
            attempt: {
                guard let focusedElement = await self.getFocusedElementWithRetry(
                    expectedProcessIdentifier: targetProcessIdentifier,
                    windowConstraint: windowConstraint,
                    retryDelays: []
                ), let assessedFocusedElement = await self.assessFocusedElement(
                    focusedElement,
                    expectedProcessIdentifier: targetProcessIdentifier,
                    bundleID: bundleID,
                    points: points,
                    requireUsableSelection: requireUsableSelection,
                    retryDelays: []
                ) else {
                    return nil
                }
                // AX focus can advance while the assessment's attribute IPC is
                // suspended. Commit the pair only when a second fresh,
                // window-bound lookup still identifies the assessed element.
                guard let confirmedFocusedElement = await self
                    .getFocusedElementWithRetry(
                        expectedProcessIdentifier: targetProcessIdentifier,
                        windowConstraint: windowConstraint,
                        retryDelays: []
                    ), Self.areSameAccessibilityElement(
                        focusedElement,
                        confirmedFocusedElement
                    ) else {
                    return nil
                }
                return (
                    candidate: focusedElement,
                    assessment: assessedFocusedElement
                )
            },
            isTerminal: {
                $0.assessment.protection == .protectedContent
            },
            isRetryable: {
                $0.assessment.protection == .indeterminate ||
                    !$0.assessment.pointAssessments.allSatisfy(\.isResolved)
            },
            isContextCurrent: {
                guard NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == targetProcessIdentifier else {
                    return false
                }
                guard let windowConstraint else { return true }
                guard let currentWindow =
                    TextSelectionMonitor.currentFrontmostWindowSnapshot(
                        frontmostProcessID: targetProcessIdentifier
                    ) else {
                    // A missing CG snapshot can be transient; the AX/window
                    // attempt below remains fail-closed and consumes budget.
                    return true
                }
                guard currentWindow.ownerPID == windowConstraint.ownerPID,
                      currentWindow.windowID == windowConstraint.windowID else {
                    return false
                }
                return !TextSelectionMonitor.didFrontmostWindowMove(
                    from: TextSelectionMonitor.FrontmostWindowSnapshot(
                        windowID: windowConstraint.windowID,
                        ownerPID: windowConstraint.ownerPID,
                        bounds: windowConstraint.bounds
                    ),
                    to: currentWindow
                )
            },
            wait: { delay in
                guard delay >= 0 else { return false }
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }
        )

        guard let result,
              Self.areSameAccessibilityElement(
                result.candidate,
                result.assessment.focusedElement
              ) else {
            return nil
        }
        return result.assessment
    }

    func getFocusedElementWithRetry(
        expectedProcessIdentifier: pid_t? = nil,
        windowConstraint: FocusedWindowConstraint? = nil,
        retryDelays: [TimeInterval] = AccessibilityManager.focusedElementRetryDelays
    ) async -> AXUIElement? {
        let frontmostProcessIdentifier =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let expectedProcessIdentifier,
           expectedProcessIdentifier != frontmostProcessIdentifier {
            return nil
        }
        guard let targetProcessIdentifier =
                expectedProcessIdentifier ?? frontmostProcessIdentifier,
              windowConstraint == nil ||
                windowConstraint?.ownerPID == targetProcessIdentifier else {
            return nil
        }

        let session = FocusResolutionSession(
            expectedSelectionWindow: windowConstraint?.expectedSelectionWindow.map {
                TransferredAXElement(value: $0)
            },
            capturedWindowBounds: windowConstraint?.bounds
        )
        var unavailableAccessibilityWindowValidationCount = 0
        let resolvedSession = await Self.resolveCandidateWithRetry(
            retryDelays: retryDelays,
            lookup: {
                await session.resolveFocus(
                    processIdentifier: targetProcessIdentifier
                ) ? session : nil
            },
            validate: { _ in
                guard let windowConstraint else { return .accept }
                let accessibilityWindowMatches =
                    await session.accessibilityWindowMatchesConstraint()
                let currentTopmostWindow =
                    TextSelectionMonitor.currentFrontmostWindowSnapshot(
                        frontmostProcessID: targetProcessIdentifier
                    )
                var disposition = TextSelectionMonitor.focusedWindowRetryDisposition(
                    capturedWindow: TextSelectionMonitor.FrontmostWindowSnapshot(
                        windowID: windowConstraint.windowID,
                        ownerPID: windowConstraint.ownerPID,
                        bounds: windowConstraint.bounds
                    ),
                    currentTopmostWindow: currentTopmostWindow,
                    accessibilityWindowMatches: accessibilityWindowMatches
                )
                if disposition == .retry,
                   accessibilityWindowMatches == nil,
                   currentTopmostWindow?.windowID == windowConstraint.windowID {
                    unavailableAccessibilityWindowValidationCount += 1
                    if unavailableAccessibilityWindowValidationCount >= 2 {
                        disposition = .retryLookup
                        unavailableAccessibilityWindowValidationCount = 0
                    }
                } else if disposition != .retry {
                    unavailableAccessibilityWindowValidationCount = 0
                }
                if disposition == .retryLookup {
                    await session.discardFocusedElement()
                }
                return disposition
            },
            isContextCurrent: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                    targetProcessIdentifier
            },
            wait: { delay in
                guard delay >= 0 else { return false }
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }
        )
        guard resolvedSession != nil,
              !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                targetProcessIdentifier,
              let transferredElement = await session.takeFocusedElement(),
              !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                targetProcessIdentifier else {
            return nil
        }
        return transferredElement.value
    }

    func getFocusedElement(expectedProcessIdentifier: pid_t? = nil) -> AXUIElement? {
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let expectedProcessIdentifier,
           frontmostProcessIdentifier != expectedProcessIdentifier {
            return nil
        }
        let targetProcessIdentifier = expectedProcessIdentifier ?? frontmostProcessIdentifier

        let focusedElement = Self.resolveFocusedElement(
            frontmostProcessIdentifier: targetProcessIdentifier,
            systemWideLookup: { [systemWideElement] in
                Self.focusedElement(
                    fromSystemWideElement: systemWideElement,
                    expectedProcessIdentifier: targetProcessIdentifier
                )
            },
            directApplicationLookup: { processIdentifier in
                let application = AXUIElementCreateApplication(processIdentifier)
                _ = AXUIElementSetMessagingTimeout(
                    application,
                    Self.accessibilityMessagingTimeout
                )
                return Self.focusedElement(
                    fromApplication: application,
                    expectedProcessIdentifier: processIdentifier
                )
            },
            candidateBelongsToProcess: { candidate, processIdentifier in
                Self.element(candidate, belongsTo: processIdentifier)
            },
            isProcessStillFrontmost: { processIdentifier in
                NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
            }
        )
        return focusedElement
    }

    nonisolated private static func element(
        _ element: AXUIElement,
        belongsTo expectedProcessIdentifier: pid_t
    ) -> Bool {
        var actualProcessIdentifier = pid_t()
        return AXUIElementGetPid(element, &actualProcessIdentifier) == .success &&
            actualProcessIdentifier == expectedProcessIdentifier
    }

    nonisolated private static func focusedElement(
        fromSystemWideElement systemWideElement: AXUIElement,
        expectedProcessIdentifier: pid_t?
    ) -> AXUIElement? {
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
        _ = AXUIElementSetMessagingTimeout(
            app,
            Self.accessibilityMessagingTimeout
        )

        if let expectedProcessIdentifier {
            var actualProcessIdentifier = pid_t()
            guard AXUIElementGetPid(app, &actualProcessIdentifier) == .success,
                  actualProcessIdentifier == expectedProcessIdentifier else {
                return nil
            }
        }

        return focusedElement(
            fromApplication: app,
            expectedProcessIdentifier: expectedProcessIdentifier
        )
    }

    nonisolated private static func focusedElement(
        fromApplication application: AXUIElement,
        expectedProcessIdentifier: pid_t?
    ) -> AXUIElement? {
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard
            elementResult == .success,
            let focusedElement,
            CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else { return nil }
        
        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        if let expectedProcessIdentifier {
            var actualProcessIdentifier = pid_t()
            guard AXUIElementGetPid(element, &actualProcessIdentifier) == .success,
                  actualProcessIdentifier == expectedProcessIdentifier else {
                return nil
            }
        }
        return element
    }

    nonisolated static func areSameAccessibilityElement(
        _ lhs: AXUIElement?,
        _ rhs: AXUIElement?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    nonisolated private static func directProtectionAssessment(
        for element: AXUIElement
    ) -> ProtectedTextAssessment {
        var subroleValue: AnyObject?
        let subroleResult = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        switch subroleResult {
        case .success:
            guard let subrole = subroleValue as? String else {
                return .indeterminate
            }
            if protectedTextSubroles.contains(subrole) {
                return .protectedContent
            }
        case .attributeUnsupported, .noValue:
            break
        default:
            return .indeterminate
        }

        for attribute in protectedTextBooleanAttributes {
            var attributeValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &attributeValue
            )
            switch result {
            case .success:
                guard let isProtected = attributeValue as? Bool else {
                    return .indeterminate
                }
                if isProtected {
                    return .protectedContent
                }
            case .attributeUnsupported, .noValue:
                continue
            default:
                return .indeterminate
            }
        }

        return .unprotected
    }

    nonisolated private static func protectionAssessment(
        for element: AXUIElement,
        maxAncestorDepth: Int = 6
    ) -> ProtectedTextAssessment {
        let directAssessment = directProtectionAssessment(for: element)
        guard directAssessment == .unprotected else { return directAssessment }

        var currentElement = element
        for _ in 0..<maxAncestorDepth {
            var parentRaw: AnyObject?
            let parentResult = AXUIElementCopyAttributeValue(
                currentElement,
                kAXParentAttribute as CFString,
                &parentRaw
            )
            switch parentResult {
            case .success:
                guard let parentRaw,
                      CFGetTypeID(parentRaw) == AXUIElementGetTypeID() else {
                    return .indeterminate
                }
                let parent = unsafeBitCast(parentRaw, to: AXUIElement.self)
                let parentAssessment = directProtectionAssessment(for: parent)
                guard parentAssessment == .unprotected else {
                    return parentAssessment
                }
                currentElement = parent
            case .attributeUnsupported, .noValue:
                return .unprotected
            default:
                return .indeterminate
            }
        }

        return .unprotected
    }

    nonisolated static func isProtectedTextElementDescriptor(
        subrole: String?,
        flags: [String: Bool]
    ) -> Bool {
        if let subrole, protectedTextSubroles.contains(subrole) {
            return true
        }

        return protectedTextBooleanAttributes.contains { flags[$0] == true }
    }

    nonisolated static func shouldSuppressSelectionPresentation(
        isProtectedElement: Bool,
        secureEventInputEnabled: Bool
    ) -> Bool {
        secureEventInputEnabled || isProtectedElement
    }

    nonisolated static func shouldSuppressSelectionPresentation(
        elementAssessment: ProtectedTextAssessment,
        ancestorAssessments: [ProtectedTextAssessment],
        secureEventInputEnabled: Bool
    ) -> Bool {
        if secureEventInputEnabled {
            return true
        }

        return ([elementAssessment] + ancestorAssessments).contains {
            $0 != .unprotected
        }
    }

    nonisolated static func shouldSuppressCopyFallback(
        focusedElementAssessment: ProtectedTextAssessment?,
        secureEventInputEnabled: Bool,
        accessibilityEnabled: Bool,
        allowMissingFocusedElement: Bool
    ) -> Bool {
        guard accessibilityEnabled, !secureEventInputEnabled else { return true }
        guard let focusedElementAssessment else {
            return !allowMissingFocusedElement
        }
        return focusedElementAssessment != .unprotected
    }

    nonisolated static func isStructuralSelectionFocusRole(_ role: String?) -> Bool {
        role == kAXWindowRole
    }

    func isStructuralSelectionFocus(_ element: AXUIElement?) -> Bool {
        Self.isStructuralSelectionFocusElement(element)
    }

    nonisolated private static func isStructuralSelectionFocusElement(
        _ element: AXUIElement?
    ) -> Bool {
        guard let element else { return false }

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else {
            return false
        }

        return isStructuralSelectionFocusRole(role)
    }

    func selectionWindow(for element: AXUIElement?) -> AXUIElement? {
        Self.selectionWindowElement(for: element)
    }

    nonisolated private static func selectionWindowElement(
        for element: AXUIElement?,
        maxAncestorDepth: Int = 12
    ) -> AXUIElement? {
        guard let element else { return nil }

        var roleValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
           let role = roleValue as? String,
           role == kAXWindowRole {
            return element
        }

        var windowValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowValue
        ) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            return unsafeBitCast(windowValue, to: AXUIElement.self)
        }

        // Older macOS releases can publish AXFocusedUIElement before its
        // AXWindow attribute. Walking the already-published parent chain gives
        // Notes and other native editors a safe path to the same window.
        var currentElement = element
        for _ in 0..<maxAncestorDepth {
            var parentValue: AnyObject?
            guard AXUIElementCopyAttributeValue(
                currentElement,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return nil
            }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            var parentRoleValue: AnyObject?
            if AXUIElementCopyAttributeValue(
                parent,
                kAXRoleAttribute as CFString,
                &parentRoleValue
            ) == .success,
               let parentRole = parentRoleValue as? String,
               parentRole == kAXWindowRole {
                return parent
            }
            currentElement = parent
        }

        return nil
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
        Self.ancestorRoles(for: element, maxDepth: maxDepth)
    }

    nonisolated private static func ancestorRoles(
        for element: AXUIElement,
        maxDepth: Int = 6
    ) -> [String] {
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

    nonisolated static func shouldTreatElementAsText(
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
            if ancestorRoles.contains(where: { forbiddenRoles.contains($0) || structuralAncestorRoles.contains($0) }) {
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
            return false
        }

        return false
    }
}
