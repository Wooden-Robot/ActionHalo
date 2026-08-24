import XCTest
@testable import ActionHalo

final class DiagnosticsWindowTests: XCTestCase {
    func testDiagnosticContextTextUsesRecentFallbackTextWhenAccessibilitySelectionIsEmpty() {
        let now = Date()
        let acquisitionStatus = AccessibilityManager.SelectionAcquisitionStatus(
            source: .copyFallback,
            timestamp: now.addingTimeInterval(-1),
            textLength: 11
        )

        let text = DiagnosticsWindow.diagnosticContextText(
            accessibilitySelectedText: "",
            lastSelectionAcquiredText: "copied text",
            acquisitionStatus: acquisitionStatus,
            now: now
        )

        XCTAssertEqual(text, "copied text")
    }

    func testDiagnosticContextTextIgnoresStaleFallbackText() {
        let now = Date()
        let acquisitionStatus = AccessibilityManager.SelectionAcquisitionStatus(
            source: .copyFallback,
            timestamp: now.addingTimeInterval(-10),
            textLength: 11
        )

        let text = DiagnosticsWindow.diagnosticContextText(
            accessibilitySelectedText: "",
            lastSelectionAcquiredText: "copied text",
            acquisitionStatus: acquisitionStatus,
            now: now
        )

        XCTAssertEqual(text, "")
    }

    func testPluginPresentationStateTreatsContextFilteredPluginAsShownButDisabled() throws {
        let plugin = try makePlugin(
            name: "Regex",
            identifier: "com.test.regex",
            actionType: "url",
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
