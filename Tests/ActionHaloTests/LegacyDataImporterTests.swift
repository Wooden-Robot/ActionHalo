import XCTest
@testable import ActionHalo

private final class InMemoryDefaultsDomainStore: LegacyDefaultsDomainStoring {
    enum StoreError: Error {
        case readFailed
        case writeFailed
    }

    var domains: [String: [String: Any]]
    var failingReads: Set<String> = []
    var failingWrites: Set<String> = []

    init(domains: [String: [String: Any]] = [:]) {
        self.domains = domains
    }

    func persistentDomain(forName name: String) throws -> [String: Any] {
        guard !failingReads.contains(name) else { throw StoreError.readFailed }
        return domains[name] ?? [:]
    }

    func setPersistentDomain(_ domain: [String: Any], forName name: String) throws {
        guard !failingWrites.contains(name) else { throw StoreError.writeFailed }
        domains[name] = domain
    }
}

private final class FailOnceCopyFileManager: FileManager, @unchecked Sendable {
    private let failingSourceName: String
    private var hasFailed = false

    init(failingSourceName: String) {
        self.failingSourceName = failingSourceName
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if !hasFailed && srcURL.lastPathComponent == failingSourceName {
            hasFailed = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class FailOnceConvertedInstallFileManager: FileManager, @unchecked Sendable {
    private let destinationName: String
    private var hasFailed = false

    init(destinationName: String) {
        self.destinationName = destinationName
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !hasFailed,
           srcURL.lastPathComponent.contains("install-legacy-import"),
           dstURL.lastPathComponent == destinationName {
            hasFailed = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class LegacyDataImporterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testImportsOnlyAllowlistedPreferencesAndPreservesDestinationValues() throws {
        let store = InMemoryDefaultsDomainStore(
            domains: [
                LegacyDataImporter.sourceDefaultsDomain: [
                    "OpenFireEnabled": false,
                    "ringOpacity": 0.2,
                    "AppLanguage": "zh-Hans",
                    "DefaultOfficeAppsExcludedMigrationVersion": 1,
                    "pluginOrder": [
                        "com.openfire.search",
                        "com.actionhalo.copy",
                        "com.openfire.search",
                    ],
                    "perAppDisabledPlugins": [
                        "com.apple.TextEdit": [
                            "com.openfire.search",
                            "com.test.custom",
                        ],
                    ],
                    "trustedPluginFingerprints": [
                        "com.openfire.script": "old-trust-must-not-migrate",
                    ],
                    "SUEnableAutomaticChecks": true,
                    "LastRunVersion": "0.3.26",
                    "ResetAccessibilityPermissionsOnUpdate": true,
                    LegacyDataImporter.importMarkerKey: 99,
                ],
                LegacyDataImporter.destinationDefaultsDomain: [
                    "ringOpacity": 0.9,
                ],
            ]
        )
        let paths = try makeImportPaths()
        let importer = makeImporter(store: store, paths: paths)

        let result = importer.importIfNeeded()
        let destination = try store.persistentDomain(
            forName: LegacyDataImporter.destinationDefaultsDomain
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.markerWritten)
        XCTAssertEqual(destination["ActionHaloEnabled"] as? Bool, false)
        XCTAssertEqual(destination["ringOpacity"] as? Double, 0.9)
        XCTAssertEqual(destination["AppLanguage"] as? String, "zh-Hans")
        XCTAssertEqual(destination["DefaultOfficeAppsExcludedMigrationVersion"] as? Int, 1)
        XCTAssertEqual(
            destination["pluginOrder"] as? [String],
            ["com.actionhalo.search", "com.actionhalo.copy"]
        )
        XCTAssertEqual(
            (destination["perAppDisabledPlugins"] as? [String: [String]])?["com.apple.TextEdit"],
            ["com.actionhalo.search", "com.test.custom"]
        )
        XCTAssertNil(destination["trustedPluginFingerprints"])
        XCTAssertNil(destination["SUEnableAutomaticChecks"])
        XCTAssertNil(destination["LastRunVersion"])
        XCTAssertNil(destination["ResetAccessibilityPermissionsOnUpdate"])
        XCTAssertEqual(
            destination[LegacyDataImporter.importMarkerKey] as? Int,
            LegacyDataImporter.currentImportVersion
        )
        XCTAssertTrue(result.preservedPreferenceKeys.contains("ringOpacity"))

        let secondResult = importer.importIfNeeded()
        XCTAssertEqual(secondResult.state, .alreadyCompleted)
        XCTAssertFalse(secondResult.markerWritten)
        XCTAssertTrue(secondResult.importedPreferenceKeys.isEmpty)
        XCTAssertTrue(secondResult.importedPlugins.isEmpty)
    }

    func testExistingActionHaloOfficeExclusionMarkerWins() throws {
        let store = InMemoryDefaultsDomainStore(
            domains: [
                LegacyDataImporter.sourceDefaultsDomain: [
                    "DefaultOfficeAppsExcludedMigrationVersion": 1,
                ],
                LegacyDataImporter.destinationDefaultsDomain: [
                    "DefaultOfficeAppsExcludedMigrationVersion": 2,
                ],
            ]
        )
        let paths = try makeImportPaths()

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let destination = try store.persistentDomain(
            forName: LegacyDataImporter.destinationDefaultsDomain
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(destination["DefaultOfficeAppsExcludedMigrationVersion"] as? Int, 2)
        XCTAssertTrue(
            result.preservedPreferenceKeys.contains(
                "DefaultOfficeAppsExcludedMigrationVersion"
            )
        )
    }

    func testImportsPluginByConvertingIdentifierConfigurationAndBundledScript() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createSourceDirectory: true)
        let sourcePackage = try makePackage(
            in: paths.source,
            name: "Legacy Search.openfireext",
            identifier: "com.openfire.legacy-search",
            actionJSON: #"{ "type": "shell-script", "script": "script.sh", "inline": "echo $OPENFIRE_TEXT" }"#,
            extraConfigJSON: #", "author": "Preserved", "description": "Uses OPENFIRE_TEXT_FILE""#,
            script: "printf '%s' \"$OPENFIRE_TEXT\" > \"$OPENFIRE_TEXT_FILE\"\n"
        )
        let sourceScriptURL = sourcePackage.appendingPathComponent("script.sh")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceScriptURL.path
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let imported = try XCTUnwrap(result.importedPlugins.first)
        let destinationPackage = imported.destinationURL
        let destinationConfigURL = destinationPackage.appendingPathComponent("Config.json")
        let destinationScriptURL = destinationPackage.appendingPathComponent("script.sh")
        let configText = try String(contentsOf: destinationConfigURL, encoding: .utf8)
        let scriptText = try String(contentsOf: destinationScriptURL, encoding: .utf8)
        let configObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(configText.utf8)) as? [String: Any]
        )
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destinationScriptURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(imported.identifier, "com.actionhalo.legacy-search")
        XCTAssertEqual(configObject["identifier"] as? String, "com.actionhalo.legacy-search")
        XCTAssertEqual(configObject["author"] as? String, "Preserved")
        XCTAssertFalse(configText.contains("OPENFIRE_TEXT"))
        XCTAssertTrue(configText.contains("ACTIONHALO_TEXT_FILE"))
        XCTAssertFalse(scriptText.contains("OPENFIRE_TEXT"))
        XCTAssertTrue(scriptText.contains("ACTIONHALO_TEXT_FILE"))
        XCTAssertTrue(scriptText.contains("ACTIONHALO_TEXT"))
        XCTAssertEqual(permissions & 0o777, 0o755)
        XCTAssertEqual(
            PluginLoader.load(from: destinationPackage)?.id,
            "com.actionhalo.legacy-search"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertTrue(
            try String(contentsOf: sourceScriptURL, encoding: .utf8).contains("OPENFIRE_TEXT")
        )
    }

    func testExistingActionHaloPluginWinsWithoutBeingOverwritten() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(
            createSourceDirectory: true,
            createDestinationDirectory: true
        )
        _ = try makePackage(
            in: paths.source,
            name: "Legacy.openfireext",
            identifier: "com.openfire.same",
            actionJSON: #"{ "type": "copy" }"#
        )
        let existingPackage = try makePackage(
            in: paths.destination,
            name: "User Chosen.actionhaloext",
            identifier: "com.actionhalo.same",
            actionJSON: #"{ "type": "copy" }"#,
            displayName: "Current"
        )
        let originalConfig = try Data(
            contentsOf: existingPackage.appendingPathComponent("Config.json")
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.importedPlugins.isEmpty)
        XCTAssertEqual(result.skippedPlugins.count, 1)
        XCTAssertEqual(result.skippedPlugins.first?.identifier, "com.actionhalo.same")
        XCTAssertEqual(result.skippedPlugins.first?.reason, .identifierConflict)
        XCTAssertEqual(
            try Data(contentsOf: existingPackage.appendingPathComponent("Config.json")),
            originalConfig
        )
    }

    func testPartialFailureDoesNotWriteMarkerAndRetryFinishesRemainingPlugin() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createSourceDirectory: true)
        _ = try makePackage(
            in: paths.source,
            name: "Good.openfireext",
            identifier: "com.openfire.good",
            actionJSON: #"{ "type": "copy" }"#
        )
        _ = try makePackage(
            in: paths.source,
            name: "Retry.openfireext",
            identifier: "com.openfire.retry",
            actionJSON: #"{ "type": "copy" }"#
        )
        let fileManager = FailOnceCopyFileManager(
            failingSourceName: "Retry.openfireext"
        )
        let importer = makeImporter(
            store: store,
            paths: paths,
            fileManager: fileManager
        )
        let firstResult = importer.importIfNeeded()
        let firstDestination = try store.persistentDomain(
            forName: LegacyDataImporter.destinationDefaultsDomain
        )

        XCTAssertEqual(firstResult.state, .incomplete)
        XCTAssertEqual(firstResult.importedPlugins.map(\.identifier), ["com.actionhalo.good"])
        XCTAssertEqual(firstResult.failedPlugins.count, 1)
        XCTAssertEqual(firstResult.failedPlugins.first?.stage, .copy)
        XCTAssertNil(firstDestination[LegacyDataImporter.importMarkerKey])

        let retryResult = importer.importIfNeeded()
        let finalDestination = try store.persistentDomain(
            forName: LegacyDataImporter.destinationDefaultsDomain
        )

        XCTAssertEqual(retryResult.state, .completed)
        XCTAssertEqual(retryResult.importedPlugins.map(\.identifier), ["com.actionhalo.retry"])
        XCTAssertEqual(retryResult.skippedPlugins.map(\.identifier), ["com.actionhalo.good"])
        XCTAssertTrue(retryResult.failedPlugins.isEmpty)
        XCTAssertEqual(
            finalDestination[LegacyDataImporter.importMarkerKey] as? Int,
            LegacyDataImporter.currentImportVersion
        )
    }

    func testInvalidAndSymlinkedPluginsAreSafelySkippedWithoutBlockingMarker() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createSourceDirectory: true)
        let package = try makePackage(
            in: paths.source,
            name: "Unsafe.openfireext",
            identifier: "com.openfire.unsafe",
            actionJSON: #"{ "type": "copy" }"#
        )
        let outsideFile = paths.root.appendingPathComponent("outside.txt")
        try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("linked.txt"),
            withDestinationURL: outsideFile
        )
        let invalidPackage = paths.source.appendingPathComponent(
            "Invalid.openfireext",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: invalidPackage,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: invalidPackage.appendingPathComponent("Config.json")
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let destinationDomain = try store.persistentDomain(
            forName: LegacyDataImporter.destinationDefaultsDomain
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.failedPlugins.isEmpty)
        XCTAssertEqual(result.skippedPlugins.count, 2)
        XCTAssertTrue(result.skippedPlugins.allSatisfy {
            if case .incompatible = $0.reason { return true }
            return false
        })
        XCTAssertTrue(result.importedPlugins.isEmpty)
        XCTAssertEqual(
            destinationDomain[LegacyDataImporter.importMarkerKey] as? Int,
            LegacyDataImporter.currentImportVersion
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testImportsActionHaloExtensionFromLegacyDirectory() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createSourceDirectory: true)
        let sourcePackage = try makePackage(
            in: paths.source,
            name: "Compatibility.actionhaloext",
            identifier: "com.openfire.compatibility",
            actionJSON: #"{ "type": "copy" }"#
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let imported = try XCTUnwrap(result.importedPlugins.first)

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(imported.identifier, "com.actionhalo.compatibility")
        XCTAssertEqual(imported.origin, .legacyDirectory)
        XCTAssertEqual(
            PluginLoader.load(from: imported.destinationURL)?.id,
            "com.actionhalo.compatibility"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
    }

    func testConvertsOldIdentifierAlreadyCopiedIntoActionHaloDirectory() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let compatibilityPackage = try makePackage(
            in: paths.destination,
            name: "com.actionhalo.copied.actionhaloext",
            identifier: "com.openfire.copied",
            actionJSON: #"{ "type": "shell-script", "script": "script.sh" }"#,
            script: "printf '%s' \"$OPENFIRE_TEXT\"\n"
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let imported = try XCTUnwrap(result.importedPlugins.first)
        let convertedConfig = try String(
            contentsOf: compatibilityPackage.appendingPathComponent("Config.json"),
            encoding: .utf8
        )
        let convertedScript = try String(
            contentsOf: compatibilityPackage.appendingPathComponent("script.sh"),
            encoding: .utf8
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(imported.origin, .existingActionHaloDirectory)
        XCTAssertEqual(imported.destinationURL, compatibilityPackage)
        XCTAssertEqual(imported.identifier, "com.actionhalo.copied")
        XCTAssertFalse(convertedConfig.contains("com.openfire"))
        XCTAssertTrue(convertedConfig.contains("com.actionhalo.copied"))
        XCTAssertFalse(convertedScript.contains("OPENFIRE_TEXT"))
        XCTAssertTrue(convertedScript.contains("ACTIONHALO_TEXT"))
        XCTAssertEqual(
            PluginLoader.load(from: compatibilityPackage)?.id,
            "com.actionhalo.copied"
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: paths.destination.path)
                .allSatisfy { !$0.contains("legacy-import") }
        )
    }

    func testFailedInPlaceConversionRestoresOriginalCompatibilityPackage() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let packageName = "com.actionhalo.rollback.actionhaloext"
        let compatibilityPackage = try makePackage(
            in: paths.destination,
            name: packageName,
            identifier: "com.openfire.rollback",
            actionJSON: #"{ "type": "copy" }"#
        )
        let originalConfig = try Data(
            contentsOf: compatibilityPackage.appendingPathComponent("Config.json")
        )
        let fileManager = FailOnceConvertedInstallFileManager(
            destinationName: packageName
        )

        let result = makeImporter(
            store: store,
            paths: paths,
            fileManager: fileManager
        ).importIfNeeded()

        XCTAssertEqual(result.state, .incomplete)
        XCTAssertEqual(result.failedPlugins.first?.stage, .install)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compatibilityPackage.path))
        XCTAssertEqual(
            try Data(contentsOf: compatibilityPackage.appendingPathComponent("Config.json")),
            originalConfig
        )
        XCTAssertFalse(result.markerWritten)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: paths.destination.path)
                .allSatisfy { !$0.contains("legacy-import") }
        )
    }

    func testRenamesOpenFireExtensionWithCurrentIdentifierInActionHaloDirectory() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let compatibilityPackage = try makePackage(
            in: paths.destination,
            name: "Copied.openfireext",
            identifier: "com.actionhalo.current-id",
            actionJSON: #"{ "type": "copy" }"#
        )
        let expectedDestination = paths.destination.appendingPathComponent(
            "com.actionhalo.current-id.actionhaloext",
            isDirectory: true
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.importedPlugins.first?.origin, .existingActionHaloDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: compatibilityPackage.path))
        XCTAssertEqual(
            PluginLoader.load(from: expectedDestination)?.id,
            "com.actionhalo.current-id"
        )
    }

    func testValidActionHaloPackageWinsOverDestinationCompatibilityDebris() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let validPackage = try makePackage(
            in: paths.destination,
            name: "User Winner.actionhaloext",
            identifier: "com.actionhalo.same",
            actionJSON: #"{ "type": "copy" }"#,
            displayName: "Winner"
        )
        let compatibilityPackage = try makePackage(
            in: paths.destination,
            name: "com.actionhalo.same.actionhaloext",
            identifier: "com.openfire.same",
            actionJSON: #"{ "type": "copy" }"#,
            displayName: "Old"
        )
        let oldConfig = try Data(
            contentsOf: compatibilityPackage.appendingPathComponent("Config.json")
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.importedPlugins.isEmpty)
        XCTAssertEqual(result.skippedPlugins.first?.identifier, "com.actionhalo.same")
        XCTAssertEqual(result.skippedPlugins.first?.reason, .identifierConflict)
        XCTAssertEqual(PluginLoader.load(from: validPackage)?.config.name, "Winner")
        XCTAssertEqual(
            try Data(contentsOf: compatibilityPackage.appendingPathComponent("Config.json")),
            oldConfig
        )
    }

    func testInvalidCanonicalOccupantDoesNotSilentlyStrandCompatibilityPackage() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let compatibilityPackage = try makePackage(
            in: paths.destination,
            name: "Legacy Copy.actionhaloext",
            identifier: "com.openfire.blocked",
            actionJSON: #"{ "type": "copy" }"#
        )
        let occupiedDestination = paths.destination.appendingPathComponent(
            "com.actionhalo.blocked.actionhaloext",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: occupiedDestination,
            withIntermediateDirectories: true
        )
        let invalidData = Data("not-json".utf8)
        try invalidData.write(
            to: occupiedDestination.appendingPathComponent("Config.json")
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let destinationDomain = try store.persistentDomain(
            forName: LegacyDataImporter.destinationDefaultsDomain
        )

        XCTAssertEqual(result.state, .incomplete)
        XCTAssertTrue(result.failedPlugins.contains {
            $0.sourceName == compatibilityPackage.lastPathComponent &&
                $0.stage == .destinationInspection
        })
        XCTAssertFalse(result.markerWritten)
        XCTAssertNil(destinationDomain[LegacyDataImporter.importMarkerKey])
        XCTAssertTrue(FileManager.default.fileExists(atPath: compatibilityPackage.path))
        XCTAssertEqual(
            try Data(contentsOf: occupiedDestination.appendingPathComponent("Config.json")),
            invalidData
        )
    }

    func testRecoversAgedHiddenCompatibilityBackupWhenItIsTheOnlyCopy() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let backupPackage = try makePackage(
            in: paths.destination,
            name: ".backup-t1-test.actionhaloext.pending",
            identifier: "com.openfire.recovered",
            actionJSON: #"{ "type": "copy" }"#
        )
        let expectedDestination = paths.destination.appendingPathComponent(
            "com.actionhalo.recovered.actionhaloext",
            isDirectory: true
        )

        let result = makeImporter(
            store: store,
            paths: paths,
            now: { Date(timeIntervalSince1970: 100) }
        ).importIfNeeded()

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.importedPlugins.first?.origin, .existingActionHaloDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPackage.path))
        XCTAssertEqual(
            PluginLoader.load(from: expectedDestination)?.id,
            "com.actionhalo.recovered"
        )
    }

    func testRecentCompatibilityBackupDefersMarkerAndRetriesWhenOldEnough() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        _ = try makePackage(
            in: paths.destination,
            name: ".backup-t995-test.actionhaloext.pending",
            identifier: "com.openfire.recent",
            actionJSON: #"{ "type": "copy" }"#
        )

        let recentResult = makeImporter(
            store: store,
            paths: paths,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).importIfNeeded()

        XCTAssertEqual(recentResult.state, .incomplete)
        XCTAssertEqual(recentResult.failedPlugins.first?.stage, .destinationInspection)
        XCTAssertFalse(recentResult.markerWritten)

        let retryResult = makeImporter(
            store: store,
            paths: paths,
            now: { Date(timeIntervalSince1970: 1_100) }
        ).importIfNeeded()

        XCTAssertEqual(retryResult.state, .completed)
        XCTAssertEqual(retryResult.importedPlugins.first?.identifier, "com.actionhalo.recent")
        XCTAssertTrue(retryResult.failedPlugins.isEmpty)
    }

    func testDoesNotImportUnconfirmedHiddenInstallStaging() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths(createDestinationDirectory: true)
        let stagingPackage = try makePackage(
            in: paths.destination,
            name: ".install-t1-test.actionhaloext.pending",
            identifier: "com.openfire.unconfirmed",
            actionJSON: #"{ "type": "copy" }"#
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.importedPlugins.isEmpty)
        XCTAssertTrue(result.failedPlugins.isEmpty)
        XCTAssertTrue(result.ignoredPluginEntries.contains(stagingPackage.lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPackage.path))
    }

    func testMigratesStrictLegacyLaunchAgentWithoutDeletingSource() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths()
        try writeLaunchAgent(
            [
                "Label": "com.openfire.app",
                "ProgramArguments": ["/usr/bin/open", "-b", "com.openfire.app"],
                "RunAtLoad": true,
            ],
            to: paths.sourceLaunchAgent
        )

        let result = makeImporter(store: store, paths: paths).importIfNeeded()
        let destinationData = try Data(contentsOf: paths.destinationLaunchAgent)
        let destination = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: destinationData,
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.launchAgentMigration,
            .imported(paths.destinationLaunchAgent)
        )
        XCTAssertEqual(Set(destination.keys), ["Label", "ProgramArguments", "RunAtLoad"])
        XCTAssertEqual(destination["Label"] as? String, "com.actionhalo.app")
        XCTAssertEqual(
            destination["ProgramArguments"] as? [String],
            ["/usr/bin/open", "-b", "com.actionhalo.app"]
        )
        XCTAssertEqual(destination["RunAtLoad"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sourceLaunchAgent.path))
    }

    func testExistingActionHaloLaunchAgentWinsWithoutInspectionOrOverwrite() throws {
        let store = InMemoryDefaultsDomainStore()
        let paths = try makeImportPaths()
        try writeLaunchAgent(
            [
                "Label": "com.openfire.app",
                "ProgramArguments": ["/usr/bin/open", "-b", "com.openfire.app"],
                "RunAtLoad": true,
            ],
            to: paths.sourceLaunchAgent
        )
        let existingData = Data("user-owned-launch-agent".utf8)
        try FileManager.default.createDirectory(
            at: paths.destinationLaunchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try existingData.write(to: paths.destinationLaunchAgent)

        let result = makeImporter(store: store, paths: paths).importIfNeeded()

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.launchAgentMigration,
            .preservedExisting(paths.destinationLaunchAgent)
        )
        XCTAssertEqual(try Data(contentsOf: paths.destinationLaunchAgent), existingData)
    }

    func testInvalidOrSymlinkedLegacyLaunchAgentIsSafelySkipped() throws {
        let store = InMemoryDefaultsDomainStore()
        let invalidPaths = try makeImportPaths()
        try writeLaunchAgent(
            [
                "Label": "com.openfire.app",
                "ProgramArguments": ["/usr/bin/open", "-b", "com.openfire.app"],
                "RunAtLoad": true,
                "Unexpected": "must reject",
            ],
            to: invalidPaths.sourceLaunchAgent
        )

        let invalidResult = makeImporter(
            store: store,
            paths: invalidPaths
        ).importIfNeeded()

        XCTAssertEqual(invalidResult.state, .completed)
        if case .skippedInvalid = invalidResult.launchAgentMigration {
            // Expected safe skip.
        } else {
            XCTFail("Expected strict launch-agent validation to skip the source")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invalidPaths.destinationLaunchAgent.path)
        )

        let symlinkStore = InMemoryDefaultsDomainStore()
        let symlinkPaths = try makeImportPaths()
        let outside = symlinkPaths.root.appendingPathComponent("outside.plist")
        try writeLaunchAgent(
            [
                "Label": "com.openfire.app",
                "ProgramArguments": ["/usr/bin/open", "-b", "com.openfire.app"],
                "RunAtLoad": true,
            ],
            to: outside
        )
        try FileManager.default.createDirectory(
            at: symlinkPaths.sourceLaunchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkPaths.sourceLaunchAgent,
            withDestinationURL: outside
        )

        let symlinkResult = makeImporter(
            store: symlinkStore,
            paths: symlinkPaths
        ).importIfNeeded()

        XCTAssertEqual(symlinkResult.state, .completed)
        if case .skippedInvalid = symlinkResult.launchAgentMigration {
            // Expected safe skip.
        } else {
            XCTFail("Expected a symbolic-link launch agent to be skipped")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    private typealias ImportPaths = (
        root: URL,
        source: URL,
        destination: URL,
        sourceLaunchAgent: URL,
        destinationLaunchAgent: URL
    )

    private func makeImportPaths(
        createSourceDirectory: Bool = false,
        createDestinationDirectory: Bool = false
    ) throws -> ImportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectories.append(root)
        let source = root.appendingPathComponent("OpenFire/Plugins", isDirectory: true)
        let destination = root.appendingPathComponent("ActionHalo/Plugins", isDirectory: true)
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createSourceDirectory {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }
        if createDestinationDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        return (
            root,
            source,
            destination,
            launchAgents.appendingPathComponent("com.openfire.app.plist"),
            launchAgents.appendingPathComponent("com.actionhalo.app.plist")
        )
    }

    private func makeImporter(
        store: InMemoryDefaultsDomainStore,
        paths: ImportPaths,
        fileManager: FileManager = .default,
        pendingPackageMinimumAge: TimeInterval =
            PluginManager.pendingOperationRecoveryMinimumAge,
        now: @escaping () -> Date = Date.init
    ) -> LegacyDataImporter {
        LegacyDataImporter(
            defaultsStore: store,
            fileManager: fileManager,
            sourcePluginsURL: paths.source,
            destinationPluginsURL: paths.destination,
            sourceLaunchAgentURL: paths.sourceLaunchAgent,
            destinationLaunchAgentURL: paths.destinationLaunchAgent,
            pendingPackageMinimumAge: pendingPackageMinimumAge,
            now: now
        )
    }

    @discardableResult
    private func makePackage(
        in directory: URL,
        name: String,
        identifier: String,
        actionJSON: String,
        extraConfigJSON: String = "",
        script: String? = nil,
        displayName: String = "Legacy"
    ) throws -> URL {
        let package = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try validConfig(
            identifier: identifier,
            actionJSON: actionJSON,
            extraConfigJSON: extraConfigJSON,
            displayName: displayName
        ).write(
            to: package.appendingPathComponent("Config.json"),
            atomically: true,
            encoding: .utf8
        )
        if let script {
            try script.write(
                to: package.appendingPathComponent("script.sh"),
                atomically: true,
                encoding: .utf8
            )
        }
        return package
    }

    private func writeLaunchAgent(
        _ propertyList: [String: Any],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func validConfig(
        identifier: String,
        actionJSON: String,
        extraConfigJSON: String = "",
        displayName: String
    ) -> String {
        """
        {
          "name": "\(displayName)",
          "identifier": "\(identifier)",
          "action": \(actionJSON)\(extraConfigJSON)
        }
        """
    }
}
