import XCTest
@testable import ActionHalo

final class DiagnosticsWindowTests: XCTestCase {
    func testDiagnosticContextTextUsesRecentFallbackTextWhenAccessibilitySelectionIsEmpty() {
        let now = Date()
        let acquisitionStatus = AccessibilityManager.SelectionAcquisitionStatus(
            source: .copyFallback,
            timestamp: now.addingTimeInterval(-1),
            textLength: 11,
            processIdentifier: 100,
            windowID: 10
        )

        let text = DiagnosticsWindow.diagnosticContextText(
            accessibilitySelectedText: "",
            lastSelectionAcquiredText: "copied text",
            acquisitionStatus: acquisitionStatus,
            currentProcessIdentifier: 100,
            currentWindowID: 10,
            now: now
        )

        XCTAssertEqual(text, "copied text")
    }

    func testDiagnosticContextTextIgnoresStaleFallbackText() {
        let now = Date()
        let acquisitionStatus = AccessibilityManager.SelectionAcquisitionStatus(
            source: .copyFallback,
            timestamp: now.addingTimeInterval(-10),
            textLength: 11,
            processIdentifier: 100,
            windowID: 10
        )

        let text = DiagnosticsWindow.diagnosticContextText(
            accessibilitySelectedText: "",
            lastSelectionAcquiredText: "copied text",
            acquisitionStatus: acquisitionStatus,
            currentProcessIdentifier: 100,
            currentWindowID: 10,
            now: now
        )

        XCTAssertEqual(text, "")
    }

    func testDiagnosticContextNeverBorrowsFallbackTextFromAnotherAppOrWindow() {
        let now = Date()
        for (acquiredPID, acquiredWindow, currentPID, currentWindow): (pid_t?, CGWindowID?, pid_t?, CGWindowID?) in [
            (100, 10, 200, 20),
            (100, 10, 100, 20),
            (100, 10, nil, nil),
            (nil, nil, 100, 10),
            (100, nil, 100, nil)
        ] {
            let status = AccessibilityManager.SelectionAcquisitionStatus(
                source: .copyFallback, timestamp: now, textLength: 11,
                processIdentifier: acquiredPID, windowID: acquiredWindow
            )
            XCTAssertEqual(DiagnosticsWindow.diagnosticContextText(
                accessibilitySelectedText: "", lastSelectionAcquiredText: "other context",
                acquisitionStatus: status, currentProcessIdentifier: currentPID,
                currentWindowID: currentWindow, now: now
            ), "")
            XCTAssertEqual(DiagnosticsWindow.diagnosticContextText(
                accessibilitySelectedText: "current selection", lastSelectionAcquiredText: "other context",
                acquisitionStatus: status, currentProcessIdentifier: currentPID,
                currentWindowID: currentWindow, now: now
            ), "current selection")
        }
    }

    func testPluginPresentationStateTreatsContextFilteredPluginAsShownButDisabled() throws {
        let plugin = try makePlugin(
            name: "Regex",
            identifier: "com.test.regex",
            actionType: "url",
            actionContent: #""url":"https://example.com?q={text}""#,
            filterJSON: #""filter":{"regex":"^[0-9]+$"}"#
        )
        let diagnostic = plugin.visibilityDiagnostic(text: "plain text", appBundleID: nil)

        let state = DiagnosticsWindow.pluginPresentationState(
            pluginID: diagnostic.plugin.id,
            shownPluginIDs: Set([plugin.id]),
            executablePluginIDs: []
        )

        XCTAssertEqual(state, .shownDisabled)
    }

    func testReadinessStateIncludesFrontmostSuppressionBlocker() {
        let readiness = DiagnosticsWindow.readinessState(
            accessibilityEnabled: true,
            isAppExcluded: false,
            isFrontmostAppSuppressed: true,
            selectedText: "",
            emptyInputShortcutReady: false
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.blockers, [.frontmostAppSuppressed, .noSelectionContext])
    }

    func testDisabledAutoTriggerCannotReportReadyEvenWithUsableSelection() {
        let readiness = DiagnosticsWindow.readinessState(
            isEnabled: false,
            accessibilityEnabled: true,
            isAppExcluded: false,
            isFrontmostAppSuppressed: false,
            selectedText: "selected text",
            emptyInputShortcutReady: false
        )
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.blockers, [.autoTriggerDisabled])
    }

    private func makePlugin(
        name: String,
        identifier: String,
        actionType: String,
        actionContent: String? = nil,
        filterJSON: String? = nil
    ) throws -> Plugin {
        let extraActionFields = actionContent.map { ",\($0)" } ?? ""
        let extraFilter = filterJSON.map { ",\($0)" } ?? ""
        let json = """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": {
                "type": "\(actionType)"\(extraActionFields)
            }\(extraFilter)
        }
        """

        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/\(identifier)"))
    }
}
