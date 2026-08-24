import XCTest
@testable import ActionHalo

final class InstalledAppNameMigrationTests: XCTestCase {
    private let fileManager = FileManager.default

    func testAssessmentPlansExactLegacyBundleRename() {
        let sourceURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let destinationURL = URL(fileURLWithPath: "/Applications/ActionHalo.app", isDirectory: true)

        XCTAssertEqual(
            InstalledAppNameMigration.assessment(
                bundleURL: sourceURL,
                bundleIdentifier: "com.openfire.app",
                bundleName: "ActionHalo",
                bundlePackageType: "APPL",
                bundleExecutable: "ActionHalo",
                destinationEntryExists: false
            ),
            .ready(.init(sourceURL: sourceURL, destinationURL: destinationURL))
        )
    }

    func testAssessmentIgnoresCurrentAndUserRenamedBundles() {
        for path in ["/Applications/ActionHalo.app", "/Applications/ActionHalo Beta.app"] {
            XCTAssertEqual(
                InstalledAppNameMigration.assessment(
                    bundleURL: URL(fileURLWithPath: path, isDirectory: true),
                    bundleIdentifier: "com.openfire.app",
                    bundleName: "ActionHalo",
                    bundlePackageType: "APPL",
                    bundleExecutable: "ActionHalo",
                    destinationEntryExists: false
                ),
                .notNeeded
            )
        }
    }

    func testAssessmentRequiresStableIdentityAndCurrentMetadata() {
        let sourceURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let variants: [(String?, String?, String?, String?)] = [
            ("com.example.other", "ActionHalo", "APPL", "ActionHalo"),
            ("com.openfire.app", "OpenFire", "APPL", "ActionHalo"),
            ("com.openfire.app", "ActionHalo", "BNDL", "ActionHalo"),
            ("com.openfire.app", "ActionHalo", "APPL", "OpenFire")
        ]

        for (identifier, name, packageType, executable) in variants {
            XCTAssertEqual(
                InstalledAppNameMigration.assessment(
                    bundleURL: sourceURL,
                    bundleIdentifier: identifier,
                    bundleName: name,
                    bundlePackageType: packageType,
                    bundleExecutable: executable,
                    destinationEntryExists: false
                ),
                .notNeeded
            )
        }
    }

    func testAssessmentNeverOverwritesExistingActionHaloBundle() {
        let sourceURL = URL(fileURLWithPath: "/Applications/OpenFire.app", isDirectory: true)
        let destinationURL = URL(fileURLWithPath: "/Applications/ActionHalo.app", isDirectory: true)

        XCTAssertEqual(
            InstalledAppNameMigration.assessment(
                bundleURL: sourceURL,
                bundleIdentifier: "com.openfire.app",
                bundleName: "ActionHalo",
                bundlePackageType: "APPL",
                bundleExecutable: "ActionHalo",
                destinationEntryExists: true
            ),
            .destinationExists(destinationURL)
        )
    }

    func testExclusiveRenameMovesDirectoryWithoutChangingIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let originalIdentity = try XCTUnwrap(InstalledAppNameMigration.directoryIdentity(at: sourceURL))

        XCTAssertTrue(InstalledAppNameMigration.renameExclusively(from: sourceURL, to: destinationURL))
        XCTAssertFalse(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
        XCTAssertEqual(InstalledAppNameMigration.directoryIdentity(at: destinationURL), originalIdentity)
    }

    func testExclusiveRenameRefusesExistingDestination() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        XCTAssertFalse(InstalledAppNameMigration.renameExclusively(from: sourceURL, to: destinationURL))
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: destinationURL))
    }

    func testMigrationSchedulesHelperBeforeRenaming() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        var helperArguments: [String]?

        let migrated = InstalledAppNameMigration.renameAndScheduleRelaunchIfNeeded(
            bundleURL: sourceURL,
            bundleIdentifier: "com.openfire.app",
            bundleName: "ActionHalo",
            bundlePackageType: "APPL",
            bundleExecutable: "ActionHalo",
            processIdentifier: 123,
            launchArguments: [
                "/tmp/Plugin with spaces.actionhaloext",
                "/tmp/Legacy;Plugin.openfireext"
            ],
            fileManager: fileManager,
            launcherURL: URL(fileURLWithPath: "/usr/bin/true"),
            launchHelper: {
                XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
                XCTAssertFalse(InstalledAppNameMigration.pathEntryExists(at: destinationURL))
                helperArguments = $0.arguments
            }
        )

        XCTAssertTrue(migrated)
        XCTAssertFalse(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: destinationURL))
        let capturedArguments = try XCTUnwrap(helperArguments)
        XCTAssertEqual(capturedArguments[3], "123")
        XCTAssertEqual(capturedArguments[4], destinationURL.path)
        XCTAssertEqual(
            Array(capturedArguments.dropFirst(7)),
            ["/tmp/Plugin with spaces.actionhaloext", "/tmp/Legacy;Plugin.openfireext"]
        )
        XCTAssertFalse(capturedArguments[1].contains(destinationURL.path))
        XCTAssertFalse(capturedArguments[1].contains("Legacy;Plugin.openfireext"))
    }

    func testMigrationDoesNotRenameWhenHelperCannotStart() throws {
        struct HelperError: Error {}

        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let migrated = InstalledAppNameMigration.renameAndScheduleRelaunchIfNeeded(
            bundleURL: sourceURL,
            bundleIdentifier: "com.openfire.app",
            bundleName: "ActionHalo",
            bundlePackageType: "APPL",
            bundleExecutable: "ActionHalo",
            fileManager: fileManager,
            launchHelper: { _ in throw HelperError() }
        )

        XCTAssertFalse(migrated)
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
        XCTAssertFalse(InstalledAppNameMigration.pathEntryExists(at: destinationURL))
    }

    func testMigrationRejectsSourceReplacementAfterHelperLaunch() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let migrated = InstalledAppNameMigration.renameAndScheduleRelaunchIfNeeded(
            bundleURL: sourceURL,
            bundleIdentifier: "com.openfire.app",
            bundleName: "ActionHalo",
            bundlePackageType: "APPL",
            bundleExecutable: "ActionHalo",
            fileManager: fileManager,
            launchHelper: { _ in
                try self.fileManager.removeItem(at: sourceURL)
                try self.fileManager.createDirectory(
                    at: sourceURL,
                    withIntermediateDirectories: true
                )
            }
        )

        XCTAssertFalse(migrated)
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
        XCTAssertFalse(InstalledAppNameMigration.pathEntryExists(at: destinationURL))
    }

    func testMigrationRejectsLegacyBundleSymlink() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let realURL = rootURL.appendingPathComponent("Real.app", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        try fileManager.createDirectory(at: realURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: sourceURL, withDestinationURL: realURL)
        var helperStarted = false

        let migrated = InstalledAppNameMigration.renameAndScheduleRelaunchIfNeeded(
            bundleURL: sourceURL,
            bundleIdentifier: "com.openfire.app",
            bundleName: "ActionHalo",
            bundlePackageType: "APPL",
            bundleExecutable: "ActionHalo",
            fileManager: fileManager,
            launchHelper: { _ in helperStarted = true }
        )

        XCTAssertFalse(migrated)
        XCTAssertFalse(helperStarted)
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
    }

    func testMigrationTreatsDanglingDestinationSymlinkAsConflict() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("OpenFire.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: destinationURL,
            withDestinationURL: rootURL.appendingPathComponent("Missing.app", isDirectory: true)
        )
        var helperStarted = false

        let migrated = InstalledAppNameMigration.renameAndScheduleRelaunchIfNeeded(
            bundleURL: sourceURL,
            bundleIdentifier: "com.openfire.app",
            bundleName: "ActionHalo",
            bundlePackageType: "APPL",
            bundleExecutable: "ActionHalo",
            fileManager: fileManager,
            launchHelper: { _ in helperStarted = true }
        )

        XCTAssertFalse(migrated)
        XCTAssertFalse(helperStarted)
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: sourceURL))
        XCTAssertTrue(InstalledAppNameMigration.pathEntryExists(at: destinationURL))
    }

    func testRelaunchHelperValidatesRenamedBundleBeforeOpening() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try makeValidBundle(at: destinationURL)
        let identity = try XCTUnwrap(InstalledAppNameMigration.directoryIdentity(at: destinationURL))
        let plan = InstalledAppNameMigration.Plan(
            sourceURL: rootURL.appendingPathComponent("OpenFire.app", isDirectory: true),
            destinationURL: destinationURL
        )
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = InstalledAppNameMigration.relaunchHelperArguments(
            plan: plan,
            processIdentifier: Int32.max,
            identity: identity,
            launcherURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        try helper.run()
        helper.waitUntilExit()

        XCTAssertEqual(helper.terminationStatus, 0)
    }

    func testRelaunchHelperWaitsForPreviousProcessToExit() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try makeValidBundle(at: destinationURL)
        let identity = try XCTUnwrap(InstalledAppNameMigration.directoryIdentity(at: destinationURL))
        let plan = InstalledAppNameMigration.Plan(
            sourceURL: rootURL.appendingPathComponent("OpenFire.app", isDirectory: true),
            destinationURL: destinationURL
        )
        let previousProcess = Process()
        previousProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        previousProcess.arguments = ["5"]
        try previousProcess.run()
        defer {
            if previousProcess.isRunning {
                previousProcess.terminate()
            }
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = InstalledAppNameMigration.relaunchHelperArguments(
            plan: plan,
            processIdentifier: previousProcess.processIdentifier,
            identity: identity,
            launcherURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        try helper.run()
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertTrue(helper.isRunning)
        previousProcess.terminate()
        previousProcess.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
    }

    func testRelaunchHelperRejectsChangedBundleIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }
        let destinationURL = rootURL.appendingPathComponent("ActionHalo.app", isDirectory: true)
        try makeValidBundle(at: destinationURL)
        let identity = try XCTUnwrap(InstalledAppNameMigration.directoryIdentity(at: destinationURL))
        let wrongIdentity = InstalledAppNameMigration.DirectoryIdentity(
            device: identity.device,
            inode: identity.inode &+ 1
        )
        let plan = InstalledAppNameMigration.Plan(
            sourceURL: rootURL.appendingPathComponent("OpenFire.app", isDirectory: true),
            destinationURL: destinationURL
        )
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = InstalledAppNameMigration.relaunchHelperArguments(
            plan: plan,
            processIdentifier: Int32.max,
            identity: wrongIdentity,
            launcherURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        try helper.run()
        helper.waitUntilExit()

        XCTAssertNotEqual(helper.terminationStatus, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "ActionHalo App Name Tests \(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func makeValidBundle(at bundleURL: URL) throws {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.openfire.app",
            "CFBundleName": "ActionHalo",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "ActionHalo"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
