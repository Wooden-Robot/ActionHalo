import XCTest
@testable import ActionHalo

@MainActor
final class LegacyMigrationStartupCoordinatorTests: XCTestCase {
    func testCompletedImportOffersCleanupOnlyOnce() {
        var result = LegacyDataImportResult()
        result.state = .completed
        var cleanupCount = 0
        var warnings: [(String, String)] = []
        let coordinator = LegacyMigrationStartupCoordinator(
            importResult: result,
            dependencies: .init(
                promptForLegacyCleanup: { cleanupCount += 1 },
                presentIncompleteImport: { warnings.append(($0, $1)) }
            )
        )

        coordinator.handlePostLaunchResult()
        coordinator.handlePostLaunchResult()

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(coordinator.hasHandledPostLaunchResult)
    }

    func testAlreadyCompletedImportStillOffersCleanupOnThisLaunch() {
        var result = LegacyDataImportResult()
        result.state = .alreadyCompleted
        var cleanupCount = 0
        let coordinator = LegacyMigrationStartupCoordinator(
            importResult: result,
            dependencies: .init(
                promptForLegacyCleanup: { cleanupCount += 1 },
                presentIncompleteImport: { _, _ in
                    XCTFail("A completed import must not show a failure warning")
                }
            )
        )

        coordinator.handlePostLaunchResult()

        XCTAssertEqual(cleanupCount, 1)
    }

    func testIncompleteImportWarnsAndNeverOffersCleanup() {
        var result = LegacyDataImportResult()
        result.state = .incomplete
        result.preferenceFailures = [
            .init(key: "ringOpacity", details: "bad value")
        ]
        result.failedPlugins = [
            .init(
                sourceName: "Search.openfireext",
                stage: .configurationConversion,
                details: "invalid identifier"
            )
        ]
        result.generalFailures = [
            .init(stage: .launchAgent, details: "invalid legacy launch agent")
        ]
        var cleanupCount = 0
        var capturedWarning: (title: String, message: String)?
        let coordinator = LegacyMigrationStartupCoordinator(
            importResult: result,
            dependencies: .init(
                promptForLegacyCleanup: { cleanupCount += 1 },
                presentIncompleteImport: { title, message in
                    capturedWarning = (title, message)
                }
            )
        )

        coordinator.handlePostLaunchResult()

        XCTAssertEqual(cleanupCount, 0)
        XCTAssertEqual(
            capturedWarning?.title,
            "OpenFire Migration Incomplete".localized
        )
        XCTAssertTrue(capturedWarning?.message.contains("ringOpacity") == true)
        XCTAssertTrue(capturedWarning?.message.contains("bad value") == true)
        XCTAssertTrue(capturedWarning?.message.contains("Search.openfireext") == true)
        XCTAssertTrue(capturedWarning?.message.contains("invalid identifier") == true)
        XCTAssertTrue(capturedWarning?.message.contains("invalid legacy launch agent") == true)
    }

    func testIncompleteImportWithoutFailureDetailsUsesFallback() {
        var result = LegacyDataImportResult()
        result.state = .incomplete

        let message = LegacyMigrationStartupCoordinator.incompleteImportMessage(
            for: result
        )

        XCTAssertTrue(
            message.contains(
                "The migration did not complete, but no detailed error was reported.".localized
            )
        )
    }

    func testIncompleteImportRecoveryPromiseIsLocalizedInEnglishAndChinese() {
        let key = "ActionHalo could not finish importing all compatible settings and plugins from OpenFire.\n\nFailed items:\n%@\n\nOpenFire, its settings, and its plugins will be kept. ActionHalo will retry the import the next time it starts. The old app will not be cleaned up until the import succeeds."

        let english = key.localized(preferredLanguage: "en")
        let chinese = key.localized(preferredLanguage: "zh-Hans")

        XCTAssertTrue(english.contains("will retry the import the next time it starts"))
        XCTAssertTrue(english.contains("will not be cleaned up until the import succeeds"))
        XCTAssertTrue(chinese.contains("下次启动时重试导入"))
        XCTAssertTrue(chinese.contains("导入成功前不会清理旧版 App"))
    }
}
