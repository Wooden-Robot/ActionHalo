import Foundation
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
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        )
        let config = try XCTUnwrap(object as? [String: Any])
        let action = try XCTUnwrap(config["action"] as? [String: Any])

        XCTAssertEqual(
            action["type"] as? String,
            "telegram-search",
            "The bundled action must use the native verified path instead of fire-and-forget AppleScript."
        )
        XCTAssertNil(action["script"])
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
