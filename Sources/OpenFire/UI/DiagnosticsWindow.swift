import Cocoa

/// A lightweight diagnostics panel for selection context and plugin visibility.
final class DiagnosticsWindow: NSWindowController {
    private let summaryLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()

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
        refreshReport()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        refreshReport()
        super.showWindow(sender)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Current OpenFire context and plugin visibility report.".localized)
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

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
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
        let report = buildReport()
        textView.string = report.text
        summaryLabel.stringValue = String(
            format: "Visible plugins: %d / %d".localized,
            report.visibleCount,
            report.totalCount
        )
    }

    private func buildReport() -> (text: String, visibleCount: Int, totalCount: Int) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontAppName = frontApp?.localizedName ?? "Unknown".localized
        let frontAppBundleID = frontApp?.bundleIdentifier ?? "Unavailable".localized

        let excludedApps = UserDefaults.standard.stringArray(forKey: "ExcludedApps") ?? []
        let isAppExcluded = excludedApps.contains(frontAppBundleID)
        let accessibilityEnabled = AccessibilityManager.shared.isAccessibilityEnabled
        let selectedText = AccessibilityManager.shared.getSelectedText() ?? ""
        let selectedPreview = previewText(selectedText)
        let focusedRole = AccessibilityManager.shared.focusedElementRoleDescription() ?? "Unavailable".localized
        let acquisitionStatus = AccessibilityManager.shared.lastSelectionAcquisitionStatus
        let attemptStatus = AccessibilityManager.shared.lastSelectionAttemptStatus
        let readiness = readinessReasons(
            accessibilityEnabled: accessibilityEnabled,
            isAppExcluded: isAppExcluded,
            selectedText: selectedText
        )

        let diagnostics = PluginManager.shared.visibilityDiagnostics(for: selectedText, appBundleID: frontApp?.bundleIdentifier)
        let visibleCount = diagnostics.filter(\.isVisible).count

        var lines: [String] = []
        lines.append("OpenFire Diagnostics".localized)
        lines.append(String(repeating: "=", count: 20))
        lines.append("")
        lines.append("\("Frontmost app".localized): \(frontAppName)")
        lines.append("\("Bundle ID".localized): \(frontAppBundleID)")
        lines.append("\("Accessibility".localized): \(accessibilityEnabled ? "Granted".localized : "Missing".localized)")
        lines.append("\("App exclusion".localized): \(isAppExcluded ? "Disabled in current app".localized : "Active in current app".localized)")
        lines.append("\("Focused element".localized): \(focusedRole)")
        lines.append("\("Selected text length".localized): \(selectedText.count)")
        lines.append("\("Selected text preview".localized): \(selectedPreview)")
        lines.append("\("Selection source".localized): \(selectionSourceText(from: acquisitionStatus))")
        lines.append("\("Last selection failure".localized): \(selectionFailureText(from: attemptStatus))")
        lines.append("\("Menu readiness".localized): \(readiness.isReady ? "Ready".localized : "Blocked".localized)")
        if !readiness.reasons.isEmpty {
            for reason in readiness.reasons {
                lines.append("  - \(reason)")
            }
        }
        lines.append("")
        lines.append("\("Plugins".localized) (\(visibleCount)/\(diagnostics.count) \("visible".localized))")
        lines.append("")

        for diagnostic in diagnostics {
            let plugin = diagnostic.plugin
            let visibility = diagnostic.isVisible ? "Visible".localized : "Hidden".localized
            lines.append("[\(visibility)] \(plugin.name) (\(plugin.id))")
            lines.append("  \("Type".localized): \(plugin.config.action.type.rawValue)")

            if diagnostic.isVisible {
                lines.append("  \("Reason".localized): \("Matches current context".localized)")
            } else {
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

    private func readinessReasons(accessibilityEnabled: Bool, isAppExcluded: Bool, selectedText: String) -> (isReady: Bool, reasons: [String]) {
        var reasons: [String] = []

        if !accessibilityEnabled {
            reasons.append("Accessibility permission is missing".localized)
        }
        if isAppExcluded {
            reasons.append("OpenFire is disabled in the current app".localized)
        }
        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("No selected text was detected via Accessibility".localized)
        }

        return (reasons.isEmpty, reasons)
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

    private func selectionSourceText(from status: AccessibilityManager.SelectionAcquisitionStatus?) -> String {
        guard let status else { return "No selection captured yet".localized }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relativeTime = formatter.localizedString(for: status.timestamp, relativeTo: Date())
        return String(
            format: "%@ · %@ · %d chars".localized,
            status.source.localizationKey.localized,
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
