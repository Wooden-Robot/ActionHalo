import Cocoa
import ApplicationServices
import XCTest
@testable import ActionHalo

final class TelegramSearchTests: XCTestCase {
    func testBundledTelegramSearchUsesNativeVerifiedAction() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = repositoryRoot.appendingPathComponent(
            "Plugins/Search Telegram.actionhaloext/Config.json"
        )
        let pluginURL = configURL.deletingLastPathComponent()
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        )
        let config = try XCTUnwrap(object as? [String: Any])
        let action = try XCTUnwrap(config["action"] as? [String: Any])

        XCTAssertEqual(
            action["type"] as? String,
            "native-command",
            "The bundled action must use the native verified path instead of fire-and-forget AppleScript."
        )
        XCTAssertEqual(action["command"] as? String, "telegram-search")
        XCTAssertNil(action["script"])
        XCTAssertNil(PluginLoader.load(from: pluginURL))
        XCTAssertEqual(
            PluginLoader.load(from: pluginURL, source: .bundled)?.action,
            .nativeCommand(.telegramSearch)
        )
    }

    @MainActor
    func testFallsBackUntilTheQueryIsVerified() async throws {
        let port = ScriptedTelegramSearchPort(
            deliveryResults: [
                .accessibility: .unavailable,
                .unicodeEvent: .delivered,
                .clipboard: .delivered,
            ],
            readbacks: [
                TelegramSearchReadback(text: "wrong", verification: .clipboardReadback),
                TelegramSearchReadback(text: "needle", verification: .accessibility),
            ]
        )
        let search = TelegramSearch(port: port)

        let result = await search.search("needle")

        XCTAssertEqual(
            try result.get(),
            TelegramSearchReceipt(
                inputMethod: .clipboard,
                verification: .accessibility
            )
        )
        XCTAssertEqual(
            port.attemptedMethods,
            [.accessibility, .unicodeEvent, .clipboard]
        )
    }

    @MainActor
    func testDeliveredButUnverifiedQueryIsFailure() async {
        let port = ScriptedTelegramSearchPort(
            deliveryResults: [
                .accessibility: .unavailable,
                .unicodeEvent: .delivered,
                .clipboard: .unavailable,
            ],
            readbacks: [nil]
        )
        let search = TelegramSearch(port: port)

        let result = await search.search("needle")

        XCTAssertEqual(
            result,
            .failure(
                TelegramSearchFailure(
                    stage: .verify,
                    reason: .textMismatch,
                    effect: .queryMayHaveBeenApplied
                )
            )
        )
    }

    @MainActor
    func testWhitespaceOnlyQueryDoesNotOpenTelegram() async {
        let port = ScriptedTelegramSearchPort()
        let search = TelegramSearch(port: port)

        let result = await search.search(" \n\t ")

        XCTAssertEqual(
            result,
            .failure(
                TelegramSearchFailure(
                    stage: .validate,
                    reason: .invalidQuery,
                    effect: .none
                )
            )
        )
        XCTAssertEqual(port.openCallCount, 0)
    }

    @MainActor
    func testRecognizedFocusedSearchFieldAllowsQueryReplacement() {
        let searchField = AXUIElementCreateApplication(101)
        var text = "previous search"

        let delivered = MacOSTelegramSearchAdapter.withVerifiedSearchField(
            capturedField: searchField,
            focusedField: searchField,
            isWritable: true,
            score: 100
        ) { _ in
            text = "needle"
            return true
        }

        XCTAssertTrue(delivered)
        XCTAssertEqual(text, "needle")
    }

    @MainActor
    func testWritableComposerDoesNotAllowQueryReplacement() {
        let composer = AXUIElementCreateApplication(102)
        var draft = "unsent message"

        let delivered = MacOSTelegramSearchAdapter.withVerifiedSearchField(
            capturedField: composer,
            focusedField: composer,
            isWritable: true,
            score: 0
        ) { _ in
            draft = "needle"
            return true
        }

        XCTAssertFalse(delivered)
        XCTAssertEqual(draft, "unsent message")
    }

    @MainActor
    func testFocusChangeDuringWaitStopsQueryReplacement() async {
        let searchField = AXUIElementCreateApplication(101)
        let composer = AXUIElementCreateApplication(102)
        var focusedField = searchField
        var didWrite = false
        XCTAssertTrue(MacOSTelegramSearchAdapter.withVerifiedSearchField(
            capturedField: searchField, focusedField: focusedField, isWritable: true, score: 100,
            operation: { _ in true }
        ))

        await Task.yield()
        focusedField = composer
        let delivered = MacOSTelegramSearchAdapter.withVerifiedSearchField(
            capturedField: searchField, focusedField: focusedField, isWritable: true, score: 100
        ) { _ in
            didWrite = true
            return true
        }

        XCTAssertFalse(delivered)
        XCTAssertFalse(didWrite)
    }

    @MainActor
    func testFocusChangeAfterDeliveryPreservesAppliedEffect() async {
        let port = ScriptedTelegramSearchPort(
            deliveryResults: [
                .accessibility: .delivered,
                .unicodeEvent: .failed(.targetChanged),
            ],
            readbacks: [nil]
        )

        let result = await TelegramSearch(port: port).search("needle")

        XCTAssertEqual(result, .failure(TelegramSearchFailure(
            stage: .input, reason: .targetChanged, effect: .queryMayHaveBeenApplied
        )))
        XCTAssertEqual(port.attemptedMethods, [.accessibility, .unicodeEvent])
    }

    @MainActor
    func testClipboardContentionAfterPastePreservesAppliedEffect() async {
        let port = ScriptedTelegramSearchPort(deliveryResults: [
            .clipboard: .failed(.clipboardContended, effect: .queryMayHaveBeenApplied),
        ])

        let result = await TelegramSearch(port: port).search("needle")

        XCTAssertEqual(result, .failure(TelegramSearchFailure(
            stage: .input, reason: .clipboardContended, effect: .queryMayHaveBeenApplied
        )))
    }

    @MainActor
    func testQueryReadbackRestoresSnapshotAfterSingleCopy() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original clipboard", forType: .string))
        let initialState = pasteboardState(pasteboard)
        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(from: pasteboard))
        defer { snapshot.discardTemporaryFiles() }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("needle", forType: .string))
        let copiedState = pasteboardState(pasteboard)
        let readback = MacOSTelegramSearchAdapter.finishQueryReadback(
            snapshot: snapshot, pasteboard: pasteboard,
            initialState: initialState, copiedState: copiedState
        )

        XCTAssertEqual(readback, "needle")
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    @MainActor
    func testQueryReadbackPreservesNewerClipboardWriteBeforeObservation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original clipboard", forType: .string))
        let initialState = pasteboardState(pasteboard)
        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(from: pasteboard))
        defer { snapshot.discardTemporaryFiles() }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("needle", forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user copy", forType: .string))
        let copiedState = pasteboardState(pasteboard)
        let readback = MacOSTelegramSearchAdapter.finishQueryReadback(
            snapshot: snapshot, pasteboard: pasteboard,
            initialState: initialState, copiedState: copiedState
        )

        XCTAssertNil(readback)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        XCTAssertEqual(pasteboard.changeCount, copiedState.changeCount)
    }

    @MainActor
    func testQueryReadbackPreservesNewerClipboardWriteAfterObservation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original clipboard", forType: .string))
        let initialState = pasteboardState(pasteboard)
        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(from: pasteboard))
        defer { snapshot.discardTemporaryFiles() }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("needle", forType: .string))
        let copiedState = pasteboardState(pasteboard)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user copy", forType: .string))
        let currentState = pasteboardState(pasteboard)
        let readback = MacOSTelegramSearchAdapter.finishQueryReadback(
            snapshot: snapshot, pasteboard: pasteboard,
            initialState: initialState, copiedState: copiedState
        )

        XCTAssertNil(readback)
        XCTAssertEqual(pasteboardState(pasteboard), currentState)
    }

    private func pasteboardState(_ pasteboard: NSPasteboard) -> AccessibilityManager.PasteboardState {
        AccessibilityManager.PasteboardState(
            changeCount: pasteboard.changeCount, string: pasteboard.string(forType: .string)
        )
    }
}

@MainActor
private final class ScriptedTelegramSearchPort: TelegramSearchDesktopPort {
    var openResult: TelegramSearchOpenResult = .ready
    var deliveryResults: [TelegramSearchInputMethod: TelegramSearchDeliveryResult]
    var readbacks: [TelegramSearchReadback?]
    private(set) var openCallCount = 0
    private(set) var attemptedMethods: [TelegramSearchInputMethod] = []

    init(
        deliveryResults: [TelegramSearchInputMethod: TelegramSearchDeliveryResult] = [:],
        readbacks: [TelegramSearchReadback?] = []
    ) {
        self.deliveryResults = deliveryResults
        self.readbacks = readbacks
    }

    func openGlobalSearch() async -> TelegramSearchOpenResult {
        openCallCount += 1
        return openResult
    }

    func replaceQuery(
        _ query: String,
        using method: TelegramSearchInputMethod
    ) async -> TelegramSearchDeliveryResult {
        attemptedMethods.append(method)
        return deliveryResults[method] ?? .unavailable
    }

    func readQuery() async -> TelegramSearchReadback? {
        guard !readbacks.isEmpty else { return nil }
        return readbacks.removeFirst()
    }
}
