import Foundation
import XCTest
@testable import ActionHalo

final class LegacyInstallationCleanupTests: XCTestCase {
    private static let testHomeURL = URL(
        fileURLWithPath: "/Users/tester",
        isDirectory: true
    )
    private static let installedSystemAppURL = URL(
        fileURLWithPath: "/Applications/ActionHalo.app",
        isDirectory: true
    )
    private static let eligibleCurrentMetadata = LegacyInstallationCleanup.ApplicationBundleMetadata(
        bundleIdentifier: "com.actionhalo.app",
        isDirectory: true,
        isSymbolicLink: false,
        volumeIsLocal: true,
        volumeIsReadOnly: false
    )

    private enum TestError: LocalizedError {
        case expected(String)

        var errorDescription: String? {
            switch self {
            case .expected(let message):
                return message
            }
        }
    }

    private func makeDependencies(
        homeDirectory: URL = LegacyInstallationCleanupTests.testHomeURL,
        currentApplicationURL: URL = LegacyInstallationCleanupTests.installedSystemAppURL,
        currentApplicationMetadata: LegacyInstallationCleanup.ApplicationBundleMetadata? = LegacyInstallationCleanupTests.eligibleCurrentMetadata,
        currentApplicationExists: Bool = true,
        fileExists: @escaping (URL) -> Bool = { _ in false },
        verifiedBundleIdentifier: @escaping (URL) -> String? = { _ in nil },
        isOfficialLegacyLaunchAgent: @escaping (URL) -> Bool = { _ in false },
        terminateApplications: @escaping (String) -> Bool = { _ in true },
        moveToTrash: @escaping (URL) throws -> Void = { _ in },
        resetAccessibilityPermission: @escaping (String) throws -> Void = { _ in }
    ) -> LegacyInstallationCleanup.Dependencies {
        LegacyInstallationCleanup.Dependencies(
            homeDirectory: homeDirectory,
            currentApplicationURL: currentApplicationURL,
            fileExists: { url in
                if url.standardizedFileURL == currentApplicationURL.standardizedFileURL {
                    return currentApplicationExists
                }
                return fileExists(url)
            },
            applicationBundleMetadata: { url in
                if url.standardizedFileURL == currentApplicationURL.standardizedFileURL {
                    return currentApplicationMetadata
                }
                guard let bundleIdentifier = verifiedBundleIdentifier(url) else {
                    return nil
                }
                return LegacyInstallationCleanup.ApplicationBundleMetadata(
                    bundleIdentifier: bundleIdentifier,
                    isDirectory: true,
                    isSymbolicLink: false,
                    volumeIsLocal: true,
                    volumeIsReadOnly: false
                )
            },
            isOfficialLegacyLaunchAgent: isOfficialLegacyLaunchAgent,
            terminateApplications: terminateApplications,
            moveToTrash: moveToTrash,
            resetAccessibilityPermission: resetAccessibilityPermission
        )
    }

    private func currentMetadata(
        bundleIdentifier: String = "com.actionhalo.app",
        isSymbolicLink: Bool = false,
        volumeIsLocal: Bool = true,
        volumeIsReadOnly: Bool = false
    ) -> LegacyInstallationCleanup.ApplicationBundleMetadata {
        LegacyInstallationCleanup.ApplicationBundleMetadata(
            bundleIdentifier: bundleIdentifier,
            isDirectory: true,
            isSymbolicLink: isSymbolicLink,
            volumeIsLocal: volumeIsLocal,
            volumeIsReadOnly: volumeIsReadOnly
        )
    }

    func testCandidateLocationsAreLimitedToSystemAndUserApplicationsFolders() {
        let homeURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            LegacyInstallationCleanup.candidateApplicationURLs(homeDirectory: homeURL),
            [
                URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true),
                URL(
                    fileURLWithPath: "/Users/tester/Applications/OpenFire.app",
                    isDirectory: true
                )
            ]
        )
        XCTAssertEqual(
            LegacyInstallationCleanup.launchAgentURL(homeDirectory: homeURL),
            URL(fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.openfire.app.plist")
        )
    }

    func testSystemApplicationsInstallIsEligibleForLegacyCleanup() {
        XCTAssertTrue(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies()
            )
        )
    }

    func testUserApplicationsInstallIsEligibleForLegacyCleanup() {
        let userInstalledURL = Self.testHomeURL
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("ActionHalo.app", isDirectory: true)

        XCTAssertTrue(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationURL: userInstalledURL
                )
            )
        )
    }

    func testMountedDMGInstallIsNotEligibleForLegacyCleanup() {
        let dmgURL = URL(
            fileURLWithPath: "/Volumes/ActionHalo/ActionHalo.app",
            isDirectory: true
        )

        XCTAssertFalse(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationURL: dmgURL,
                    currentApplicationMetadata: currentMetadata(
                        volumeIsReadOnly: true
                    )
                )
            )
        )
    }

    func testDownloadsInstallIsNotEligibleForLegacyCleanup() {
        let downloadsURL = Self.testHomeURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("ActionHalo.app", isDirectory: true)

        XCTAssertFalse(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationURL: downloadsURL
                )
            )
        )
    }

    func testWrongCurrentBundleIdentifierIsNotEligibleForLegacyCleanup() {
        XCTAssertFalse(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationMetadata: currentMetadata(
                        bundleIdentifier: "com.example.lookalike"
                    )
                )
            )
        )
    }

    func testSymlinkCurrentAppIsNotEligibleForLegacyCleanup() {
        XCTAssertFalse(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationMetadata: currentMetadata(
                        isSymbolicLink: true
                    )
                )
            )
        )
    }

    func testReadOnlyCurrentVolumeIsNotEligibleForLegacyCleanup() {
        XCTAssertFalse(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationMetadata: currentMetadata(
                        volumeIsReadOnly: true
                    )
                )
            )
        )
    }

    func testNetworkCurrentVolumeIsNotEligibleForLegacyCleanup() {
        XCTAssertFalse(
            LegacyInstallationCleanup.isEligibleCurrentInstallation(
                dependencies: makeDependencies(
                    currentApplicationMetadata: currentMetadata(
                        volumeIsLocal: false
                    )
                )
            )
        )
    }

    func testCleanupFromDMGStopsBeforeAnyLegacyMutation() {
        let dmgURL = URL(
            fileURLWithPath: "/Volumes/ActionHalo/ActionHalo.app",
            isDirectory: true
        )
        let legacyURL = URL(
            fileURLWithPath: "/Applications/OpenFire.app",
            isDirectory: true
        )
        var didMutate = false
        let dependencies = makeDependencies(
            currentApplicationURL: dmgURL,
            currentApplicationMetadata: currentMetadata(volumeIsReadOnly: true),
            fileExists: { $0 == legacyURL },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            terminateApplications: { _ in didMutate = true; return true },
            moveToTrash: { _ in didMutate = true },
            resetAccessibilityPermission: { _ in didMutate = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [legacyURL],
                launchAgentURL: URL(fileURLWithPath: "/tmp/launch-agent.plist"),
                dependencies: dependencies
            ),
            .failure(.currentInstallationNotEligible)
        )
        XCTAssertFalse(didMutate)
    }

    func testCleanupRejectsVerifiedBundleOutsideExactCandidatePaths() {
        let outsideURL = URL(
            fileURLWithPath: "/tmp/OpenFire.app",
            isDirectory: true
        )
        var didMutate = false
        let dependencies = makeDependencies(
            fileExists: { $0 == outsideURL },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            terminateApplications: { _ in didMutate = true; return true },
            moveToTrash: { _ in didMutate = true },
            resetAccessibilityPermission: { _ in didMutate = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [outsideURL],
                launchAgentURL: LegacyInstallationCleanup.launchAgentURL(
                    homeDirectory: Self.testHomeURL
                ),
                dependencies: dependencies
            ),
            .success(trashedItems: [])
        )
        XCTAssertFalse(didMutate)
    }

    func testDisappearedVerifiedAppCausesNoCleanupSideEffects() {
        let appURL = URL(
            fileURLWithPath: "/Applications/OpenFire.app",
            isDirectory: true
        )
        var didMutate = false
        let dependencies = makeDependencies(
            fileExists: { _ in false },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            isOfficialLegacyLaunchAgent: { _ in true },
            terminateApplications: { _ in didMutate = true; return true },
            moveToTrash: { _ in didMutate = true },
            resetAccessibilityPermission: { _ in didMutate = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: LegacyInstallationCleanup.launchAgentURL(
                    homeDirectory: Self.testHomeURL
                ),
                dependencies: dependencies
            ),
            .success(trashedItems: [])
        )
        XCTAssertFalse(didMutate)
    }

    func testDetectionRequiresExactVerifiedLegacyBundleIdentifier() {
        let matchingURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let wrongIdentityURL = URL(
            fileURLWithPath: "/Users/tester/Applications/OpenFire.app",
            isDirectory: true
        )
        let missingURL = URL(fileURLWithPath: "/tmp/OpenFire.app", isDirectory: true)
        let dependencies = makeDependencies(
            fileExists: { $0 != missingURL },
            verifiedBundleIdentifier: { url in
                url == matchingURL ? "com.openfire.app" : "com.example.unrelated"
            },
            terminateApplications: { _ in XCTFail("Detection must not terminate apps"); return false },
            moveToTrash: { _ in XCTFail("Detection must not trash files") },
            resetAccessibilityPermission: { _ in XCTFail("Detection must not reset TCC") }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.detectedLegacyApplications(
                candidateURLs: [matchingURL, wrongIdentityURL, missingURL],
                dependencies: dependencies
            ),
            [matchingURL]
        )
    }

    func testOfficialLegacyLaunchAgentRequiresExactThreeKeyDefinition() {
        let official: [String: Any] = [
            "Label": "com.openfire.app",
            "ProgramArguments": ["/usr/bin/open", "-b", "com.openfire.app"],
            "RunAtLoad": true,
        ]

        XCTAssertTrue(
            LegacyInstallationCleanup.isOfficialLegacyLaunchAgentPropertyList(official)
        )

        var extraKey = official
        extraKey["KeepAlive"] = true
        XCTAssertFalse(
            LegacyInstallationCleanup.isOfficialLegacyLaunchAgentPropertyList(extraKey)
        )

        var wrongArguments = official
        wrongArguments["ProgramArguments"] = ["/usr/bin/open", "/Applications/OpenFire.app"]
        XCTAssertFalse(
            LegacyInstallationCleanup.isOfficialLegacyLaunchAgentPropertyList(wrongArguments)
        )

        var nonBooleanRunAtLoad = official
        nonBooleanRunAtLoad["RunAtLoad"] = 1
        XCTAssertFalse(
            LegacyInstallationCleanup.isOfficialLegacyLaunchAgentPropertyList(
                nonBooleanRunAtLoad
            )
        )
    }

    func testCleanupTerminatesBeforeTrashingAndResetsTCCOnlyAfterSuccess() {
        let systemAppURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let userAppURL = URL(
            fileURLWithPath: "/Users/tester/Applications/OpenFire.app",
            isDirectory: true
        )
        let launchAgentURL = URL(
            fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.openfire.app.plist"
        )
        let existingPaths = Set([systemAppURL.path, userAppURL.path, launchAgentURL.path])
        var events: [String] = []
        let dependencies = makeDependencies(
            fileExists: { existingPaths.contains($0.path) },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            isOfficialLegacyLaunchAgent: { $0 == launchAgentURL },
            terminateApplications: { bundleIdentifier in
                events.append("terminate:\(bundleIdentifier)")
                return true
            },
            moveToTrash: { url in events.append("trash:\(url.path)") },
            resetAccessibilityPermission: { bundleIdentifier in
                events.append("tcc:\(bundleIdentifier)")
            }
        )

        let outcome = LegacyInstallationCleanup.performCleanup(
            applications: [systemAppURL, userAppURL],
            launchAgentURL: launchAgentURL,
            dependencies: dependencies
        )

        XCTAssertEqual(
            outcome,
            .success(trashedItems: [systemAppURL, userAppURL, launchAgentURL])
        )
        XCTAssertEqual(
            events,
            [
                "terminate:com.openfire.app",
                "trash:/Applications/OpenFire.app",
                "trash:/Users/tester/Applications/OpenFire.app",
                "trash:/Users/tester/Library/LaunchAgents/com.openfire.app.plist",
                "tcc:com.openfire.app"
            ]
        )
    }

    func testInvalidSameNamedLaunchAgentIsNeverMoved() {
        let appURL = URL(
            fileURLWithPath: "/Applications/OpenFire.app",
            isDirectory: true
        )
        let launchAgentURL = URL(
            fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.openfire.app.plist"
        )
        let existingPaths = Set([appURL.path, launchAgentURL.path])
        var trashedURLs: [URL] = []
        var resetBundleIdentifiers: [String] = []
        let dependencies = makeDependencies(
            fileExists: { existingPaths.contains($0.path) },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            isOfficialLegacyLaunchAgent: { _ in false },
            terminateApplications: { $0 == "com.openfire.app" },
            moveToTrash: { trashedURLs.append($0) },
            resetAccessibilityPermission: { resetBundleIdentifiers.append($0) }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: launchAgentURL,
                dependencies: dependencies
            ),
            .success(trashedItems: [appURL])
        )
        XCTAssertEqual(trashedURLs, [appURL])
        XCTAssertEqual(resetBundleIdentifiers, ["com.openfire.app"])
    }

    func testCleanupRevalidatesIdentityAndDoesNotMutateChangedBundle() {
        let appURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let launchAgentURL = URL(fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.openfire.app.plist")
        var verificationCount = 0
        var didTrash = false
        var didResetTCC = false
        let dependencies = makeDependencies(
            fileExists: { _ in true },
            verifiedBundleIdentifier: { _ in
                verificationCount += 1
                return verificationCount == 1 ? "com.openfire.app" : "com.example.replacement"
            },
            terminateApplications: { _ in true },
            moveToTrash: { _ in didTrash = true },
            resetAccessibilityPermission: { _ in didResetTCC = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: launchAgentURL,
                dependencies: dependencies
            ),
            .failure(.identityValidationFailed(appURL))
        )
        XCTAssertFalse(didTrash)
        XCTAssertFalse(didResetTCC)
    }

    func testCleanupRefusesMatchingFilenameWithWrongBundleIdentifier() {
        let appURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        var didMutate = false
        let dependencies = makeDependencies(
            fileExists: { $0 == appURL },
            verifiedBundleIdentifier: { _ in "com.example.unrelated" },
            terminateApplications: { _ in didMutate = true; return true },
            moveToTrash: { _ in didMutate = true },
            resetAccessibilityPermission: { _ in didMutate = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: URL(fileURLWithPath: "/tmp/launch-agent.plist"),
                dependencies: dependencies
            ),
            .failure(.identityValidationFailed(appURL))
        )
        XCTAssertFalse(didMutate)
    }

    func testTerminationFailurePreventsAllFilesystemAndTCCChanges() {
        let appURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        var didTrash = false
        var didResetTCC = false
        let dependencies = makeDependencies(
            fileExists: { $0 == appURL },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            terminateApplications: { _ in false },
            moveToTrash: { _ in didTrash = true },
            resetAccessibilityPermission: { _ in didResetTCC = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: URL(fileURLWithPath: "/tmp/launch-agent.plist"),
                dependencies: dependencies
            ),
            .failure(.applicationTerminationFailed)
        )
        XCTAssertFalse(didTrash)
        XCTAssertFalse(didResetTCC)
    }

    func testTrashFailureDoesNotResetAccessibilityPermission() {
        let appURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        var didResetTCC = false
        let dependencies = makeDependencies(
            fileExists: { $0 == appURL },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            terminateApplications: { _ in true },
            moveToTrash: { _ in throw TestError.expected("permission denied") },
            resetAccessibilityPermission: { _ in didResetTCC = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: URL(fileURLWithPath: "/tmp/launch-agent.plist"),
                dependencies: dependencies
            ),
            .failure(.trashFailed(appURL, "permission denied"))
        )
        XCTAssertFalse(didResetTCC)
    }

    func testEmptyUnverifiedInputCannotRemoveLoginItemOrResetTCC() {
        let launchAgentURL = URL(
            fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.openfire.app.plist"
        )
        var didMutate = false
        let dependencies = makeDependencies(
            fileExists: { _ in true },
            verifiedBundleIdentifier: { _ in nil },
            terminateApplications: { _ in didMutate = true; return true },
            moveToTrash: { _ in didMutate = true },
            resetAccessibilityPermission: { _ in didMutate = true }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [],
                launchAgentURL: launchAgentURL,
                dependencies: dependencies
            ),
            .success(trashedItems: [])
        )
        XCTAssertFalse(didMutate)
    }

    func testAccessibilityResetFailureIsReportedAfterItemsReachTrash() {
        let appURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        var trashedURLs: [URL] = []
        let dependencies = makeDependencies(
            fileExists: { $0 == appURL },
            verifiedBundleIdentifier: { _ in "com.openfire.app" },
            terminateApplications: { _ in true },
            moveToTrash: { trashedURLs.append($0) },
            resetAccessibilityPermission: { _ in
                throw TestError.expected("not permitted")
            }
        )

        XCTAssertEqual(
            LegacyInstallationCleanup.performCleanup(
                applications: [appURL],
                launchAgentURL: URL(fileURLWithPath: "/tmp/launch-agent.plist"),
                dependencies: dependencies
            ),
            .failure(.accessibilityResetFailed("not permitted"))
        )
        XCTAssertEqual(trashedURLs, [appURL])
    }

    func testManualInstructionsPreserveUserDataAndGiveExactCleanupSteps() {
        let appURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let launchAgentURL = URL(
            fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.openfire.app.plist"
        )

        let instructions = LegacyInstallationCleanup.manualCleanupInstructions(
            applicationURLs: [appURL],
            launchAgentURL: launchAgentURL
        )

        XCTAssertTrue(instructions.contains("/Applications/OpenFire.app"))
        XCTAssertTrue(instructions.contains(launchAgentURL.path))
        XCTAssertTrue(instructions.contains("tccutil reset Accessibility com.openfire.app"))
        XCTAssertTrue(instructions.contains("does not remove the old Application Support or Preferences"))
    }
}
