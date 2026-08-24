import Cocoa

/// A lightweight diagnostics panel for selection context and plugin visibility.
final class DiagnosticsWindow: NSWindowController {
    enum PluginPresentationState: Equatable {
        case shownExecutable
        case shownDisabled
        case hidden
    }

    enum ReadinessBlocker: Equatable {
        case missingAccessibilityPermission
        case appExcluded
        case frontmostAppSuppressed
        case noSelectionContext
    }

    private static let recentAcquisitionContextWindow: TimeInterval = 5

    private struct CapturedContext {
        let processIdentifier: pid_t?
        let appName: String
        let appBundleID: String?
        let selectedText: String
        let focusedRole: String
        let focusedSelectionEditable: Bool
        let emptyInputCheckLocation: NSPoint
        let isTextInputAtEmptyInputCheckLocation: Bool
        let acquisitionStatus: AccessibilityManager.SelectionAcquisitionStatus?
        let attemptStatus: AccessibilityManager.SelectionAttemptStatus?
    }

    private let summaryLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private var capturedContext: CapturedContext?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Diagnostics".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // Capture before showing/activating ActionHalo so refreshes keep diagnosing
        // the application and focused element the user actually invoked us from.
        if window?.isVisible != true {
            capturedContext = captureCurrentContext()
        }
        refreshReport()
        super.showWindow(sender)
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        refreshReport()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Current ActionHalo context and plugin visibility report.".localized)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 20, y: 462, width: 420, height: 18)
        contentView.addSubview(titleLabel)

        summaryLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = .tertiaryLabelColor
        summaryLabel.frame = NSRect(x: 20, y: 440, width: 420, height: 18)
        contentView.addSubview(summaryLabel)

        let refreshButton = NSButton(frame: NSRect(x: 520, y: 452, width: 100, height: 28))
        refreshButton.title = "Refresh".localized
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        contentView.addSubview(refreshButton)

        let copyButton = NSButton(frame: NSRect(x: 520, y: 418, width: 100, height: 28))
        copyButton.title = "Copy Report".localized
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyReportClicked)
        contentView.addSubview(copyButton)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 600, height: 388))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView.frame = scrollView.contentView.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.minSize = scrollView.contentView.bounds.size
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        contentView.addSubview(scrollView)
    }

    @objc private func refreshClicked() {
        refreshReport()
    }

    @objc private func copyReportClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }

    private func refreshReport() {
        if capturedContext == nil {
            capturedContext = captureCurrentContext()
        }
        let report = buildReport()
        textView.string = report.text
        summaryLabel.stringValue = String(
            format: "Shown plugins: %d / %d".localized,
            report.visibleCount,
            report.totalCount
        )
    }

    static func diagnosticContextText(
        accessibilitySelectedText: String,
        lastSelectionAcquiredText: String?,
        acquisitionStatus: AccessibilityManager.SelectionAcquisitionStatus?,
        now: Date = Date()
    ) -> String {
        let accessibilityText = accessibilitySelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accessibilityText.isEmpty {
            return accessibilityText
        }

        guard let acquisitionStatus,
              now.timeIntervalSince(acquisitionStatus.timestamp) <= recentAcquisitionContextWindow,
              let lastSelectionAcquiredText else {
            return ""
        }

        return lastSelectionAcquiredText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pluginPresentationState(
        pluginID: String,
        shownPluginIDs: Set<String>,
        executablePluginIDs: Set<String>
    ) -> PluginPresentationState {
        guard shownPluginIDs.contains(pluginID) else { return .hidden }
        return executablePluginIDs.contains(pluginID) ? .shownExecutable : .shownDisabled
    }

    static func readinessState(
        accessibilityEnabled: Bool,
        isAppExcluded: Bool,
        isFrontmostAppSuppressed: Bool,
        selectedText: String,
        emptyInputShortcutReady: Bool
    ) -> (isReady: Bool, blockers: [ReadinessBlocker]) {
        var blockers: [ReadinessBlocker] = []

        if !accessibilityEnabled {
            blockers.append(.missingAccessibilityPermission)
        }
        if isAppExcluded {
            blockers.append(.appExcluded)
        }
        if isFrontmostAppSuppressed {
            blockers.append(.frontmostAppSuppressed)
        }
        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !emptyInputShortcutReady {
            blockers.append(.noSelectionContext)
        }

        return (blockers.isEmpty, blockers)
    }

    private func captureCurrentContext() -> CapturedContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let accessibilitySelectedText = AccessibilityManager.shared.getSelectedText() ?? ""
        let acquisitionStatus = AccessibilityManager.shared.lastSelectionAcquisitionStatus
        let emptyInputCheckLocation = TextSelectionMonitor.shared.lastEmptyInputCheckLocation ?? NSEvent.mouseLocation

        return CapturedContext(
            processIdentifier: frontApp?.processIdentifier,
            appName: frontApp?.localizedName ?? "Unknown".localized,
            appBundleID: frontApp?.bundleIdentifier,
            selectedText: Self.diagnosticContextText(
                accessibilitySelectedText: accessibilitySelectedText,
                lastSelectionAcquiredText: AccessibilityManager.shared.lastSelectionAcquiredText,
                acquisitionStatus: acquisitionStatus
            ),
            focusedRole: AccessibilityManager.shared.focusedElementRoleDescription() ?? "Unavailable".localized,
            focusedSelectionEditable: AccessibilityManager.shared.isFocusedSelectionEditable(),
            emptyInputCheckLocation: emptyInputCheckLocation,
            isTextInputAtEmptyInputCheckLocation: AccessibilityManager.shared.isTextInputElement(
                at: emptyInputCheckLocation
            ),
            acquisitionStatus: acquisitionStatus,
            attemptStatus: AccessibilityManager.shared.lastSelectionAttemptStatus
        )
    }

    private func buildReport() -> (text: String, visibleCount: Int, totalCount: Int) {
        guard let context = capturedContext else {
            return ("Unable to capture diagnostics context.".localized, 0, 0)
        }

        let frontAppName = context.appName
        let frontAppBundleID = context.appBundleID ?? "Unavailable".localized
        let isAppExcluded = AppExclusionStore.isExcluded(context.appBundleID)
        let accessibilityEnabled = AccessibilityManager.shared.isAccessibilityEnabled
        let acquisitionStatus = context.acquisitionStatus
        let attemptStatus = context.attemptStatus
        let focusedSelectionEditable = context.focusedSelectionEditable
        let selectedText = context.selectedText
        let selectedPreview = previewText(selectedText)
        let isFrontmostAppSuppressed = TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: context.appBundleID,
            localizedName: context.appName,
            isFocusedSelectionEditable: focusedSelectionEditable
        )
        let emptyInputCheckLocation = context.emptyInputCheckLocation
        let clipboardHasText = TextSelectionMonitor.hasUsableClipboardText(
            NSPasteboard.general.string(forType: .string)
        )
        let emptyInputShortcutReady = accessibilityEnabled &&
            !isAppExcluded &&
            !isFrontmostAppSuppressed &&
            selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            clipboardHasText &&
            context.isTextInputAtEmptyInputCheckLocation
        let readiness = Self.readinessState(
            accessibilityEnabled: accessibilityEnabled,
            isAppExcluded: isAppExcluded,
            isFrontmostAppSuppressed: isFrontmostAppSuppressed,
            selectedText: selectedText,
            emptyInputShortcutReady: emptyInputShortcutReady
        )

        let diagnostics = PluginManager.shared.visibilityDiagnostics(for: selectedText, appBundleID: context.appBundleID)
        let shownPlugins = PluginManager.shared.presentationPlugins(appBundleID: context.appBundleID)
        let shownPluginIDs = Set(shownPlugins.map(\.id))
        let executablePluginIDs = Set(
            shownPlugins
                .filter {
                    AppDelegate.isPluginExecutable(
                        $0,
                        text: selectedText,
                        appBundleID: context.appBundleID,
                        isSelectionEditable: focusedSelectionEditable
                    )
                }
                .map(\.id)
        )
        let visibleCount = shownPluginIDs.count

        var lines: [String] = []
        lines.append("ActionHalo Diagnostics".localized)
        lines.append(String(repeating: "=", count: 20))
        lines.append("")
        lines.append("\("Frontmost app".localized): \(frontAppName)")
        lines.append("\("Bundle ID".localized): \(frontAppBundleID)")
        if let processIdentifier = context.processIdentifier {
            lines.append("PID: \(processIdentifier)")
        }
        lines.append("\("Accessibility".localized): \(accessibilityEnabled ? "Granted".localized : "Missing".localized)")
        lines.append("\("App exclusion".localized): \(isAppExcluded ? "Disabled in current app".localized : "Active in current app".localized)")
        lines.append("\("Focused element".localized): \(context.focusedRole)")
        lines.append("\("Selected text length".localized): \(selectedText.count)")
        lines.append("\("Selected text preview".localized): \(selectedPreview)")
        lines.append("\("Clipboard".localized): \(clipboardHasText ? "Has text".localized : "Empty".localized)")
        lines.append("\("Empty-input probe point".localized): \(String(format: "(%.0f, %.0f)", emptyInputCheckLocation.x, emptyInputCheckLocation.y))")
        lines.append("\("Selection source".localized): \(selectionSourceText(from: acquisitionStatus))")
        lines.append("\("Last selection failure".localized): \(selectionFailureText(from: attemptStatus))")
        lines.append("\("Menu readiness".localized): \(readiness.isReady ? "Ready".localized : "Blocked".localized)")
        if !readiness.blockers.isEmpty {
            for blocker in readiness.blockers {
                lines.append("  - \(localizedReadinessBlocker(blocker))")
            }
        }
        if emptyInputShortcutReady {
            lines.append("  - \("Empty-input Paste / Clear shortcut is currently available".localized)")
        }
        lines.append("")
        lines.append("\("Plugins".localized) (\(visibleCount)/\(diagnostics.count) \("shown".localized))")
        lines.append("")

        for diagnostic in diagnostics {
            let plugin = diagnostic.plugin
            let state = Self.pluginPresentationState(
                pluginID: plugin.id,
                shownPluginIDs: shownPluginIDs,
                executablePluginIDs: executablePluginIDs
            )
            lines.append("[\(localizedPluginPresentationState(state))] \(plugin.name) (\(plugin.id))")
            lines.append("  \("Type".localized): \(plugin.config.action.type.rawValue)")

            switch state {
            case .shownExecutable:
                lines.append("  \("Reason".localized): \("Executable in current context".localized)")
            case .shownDisabled:
                if diagnostic.reasons.isEmpty {
                    lines.append("  - \("Requires an editable text context".localized)")
                } else {
                    for reason in diagnostic.reasons {
                        lines.append("  - \(localizedReason(reason))")
                    }
                }
            case .hidden:
                for reason in diagnostic.reasons {
                    lines.append("  - \(localizedReason(reason))")
                }
            }

            if plugin.requiresExecutionTrust {
                let trustStatus = PluginManager.shared.isExecutionTrusted(for: plugin) ? "Trusted".localized : "Not Trusted".localized
                lines.append("  \("Trust".localized): \(trustStatus)")
            }

            lines.append("")
        }

        return (lines.joined(separator: "\n"), visibleCount, diagnostics.count)
    }

    private func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "None".localized }

        let singleLine = trimmed.replacingOccurrences(of: "\n", with: "\\n")
        if singleLine.count <= 120 {
            return singleLine
        }

        let cutoff = singleLine.index(singleLine.startIndex, offsetBy: 120)
        return String(singleLine[..<cutoff]) + "..."
    }

    private func localizedReason(_ reason: PluginVisibilityReason) -> String {
        switch reason {
        case .disabled:
            return "Plugin is disabled".localized
        case .disabledForApp(let bundleID):
            return String(format: "Plugin is disabled for app %@".localized, bundleID)
        case .textTooShort(let min, let actual):
            return String(format: "Selected text is too short (%d < %d)".localized, actual, min)
        case .textTooLong(let max, let actual):
            return String(format: "Selected text is too long (%d > %d)".localized, actual, max)
        case .invalidRegex(let pattern):
            return String(format: "Plugin regex is invalid: %@".localized, pattern)
        case .regexNoMatch(let pattern):
            return String(format: "Selected text did not match regex: %@".localized, pattern)
        case .appNotAllowed(let current, let allowed):
            let currentApp = current ?? "None".localized
            return String(
                format: "Current app %@ is not in allowed apps: %@".localized,
                currentApp,
                allowed.joined(separator: ", ")
            )
        case .appExcluded(let bundleID):
            return String(format: "Current app %@ is explicitly excluded".localized, bundleID)
        }
    }

    private func localizedPluginPresentationState(_ state: PluginPresentationState) -> String {
        switch state {
        case .shownExecutable:
            return "Shown".localized
        case .shownDisabled:
            return "Shown, Disabled".localized
        case .hidden:
            return "Hidden".localized
        }
    }

    private func localizedReadinessBlocker(_ blocker: ReadinessBlocker) -> String {
        switch blocker {
        case .missingAccessibilityPermission:
            return "Accessibility permission is missing".localized
        case .appExcluded:
            return "ActionHalo is disabled in the current app".localized
        case .frontmostAppSuppressed:
            return "ActionHalo is intentionally suppressed for the current frontmost app".localized
        case .noSelectionContext:
            return "No active selected text or empty-input shortcut is currently available".localized
        }
    }

    private func selectionSourceText(from status: AccessibilityManager.SelectionAcquisitionStatus?) -> String {
        guard let status else { return "No selection captured yet".localized }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relativeTime = formatter.localizedString(for: status.timestamp, relativeTo: Date())
        return String(
            format: "%@ · %@ · %d chars".localized,
            status.source.localizedName,
            relativeTime,
            status.textLength
        )
    }

    private func selectionFailureText(from status: AccessibilityManager.SelectionAttemptStatus?) -> String {
        guard let status else { return "No recent selection failure".localized }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relativeTime = formatter.localizedString(for: status.timestamp, relativeTo: Date())
        return String(
            format: "%@ · %@".localized,
            localizedSelectionFailure(status.failure),
            relativeTime
        )
    }

    private func localizedSelectionFailure(_ failure: AccessibilityManager.SelectionAttemptFailure) -> String {
        switch failure {
        case .accessibilityEmptySelection:
            return "Accessibility read returned no selected text".localized
        case .copyFallbackEmptySelection:
            return "Cmd+C fallback returned no selected text".localized
        case .observerSetupFailed:
            return "AX observer could not be attached".localized
        case .observerTimedOut:
            return "AX observer timed out waiting for selection".localized
        case .noFocusedApplication:
            return "No focused application was available".localized
        }
    }
}
