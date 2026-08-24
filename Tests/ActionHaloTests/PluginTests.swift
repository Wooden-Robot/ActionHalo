import XCTest
@testable import ActionHalo

final class PluginTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }
    
    // MARK: - Decoding Tests
    
    func testDecodeCompletePluginJSON() throws {
        let json = """
        {
            "identifier": "com.test.plugin",
            "name": "Test Plugin",
            "description": "A detailed test plugin",
            "icon": "star.fill",
            "author": "ActionHalo",
            "version": "1.0",
            "filter": {
                "regex": "^http"
            },
            "action": {
                "type": "shell-script",
                "script": "run.sh",
                "key": "c",
                "modifiers": ["cmd", "shift"]
            }
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let config = try decoder.decode(PluginConfig.self, from: json)
        
        XCTAssertEqual(config.identifier, "com.test.plugin")
        XCTAssertEqual(config.name, "Test Plugin")
        XCTAssertEqual(config.description, "A detailed test plugin")
        XCTAssertEqual(config.icon, "star.fill")
        
        XCTAssertEqual(config.filter?.regex, "^http")
        
        XCTAssertEqual(config.action.script, "run.sh")
        XCTAssertEqual(config.action.key, "c")
        XCTAssertEqual(config.action.modifiers, ["cmd", "shift"])
        
        // Test Plugin initialization from config
        let url = URL(fileURLWithPath: "/tmp/fakeplugin")
        let plugin = Plugin(config: config, directoryURL: url)
        
        XCTAssertEqual(plugin.id, "com.test.plugin")
        XCTAssertEqual(plugin.name, "Test Plugin")
        XCTAssertEqual(plugin.iconName, "star.fill")
    }
    
    func testDecodeMinimalPluginJSON() throws {
        let json = """
        {
            "name": "Minimal",
            "identifier": "com.test.minimal",
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let config = try decoder.decode(PluginConfig.self, from: json)
        
        XCTAssertEqual(config.name, "Minimal")
        XCTAssertEqual(config.identifier, "com.test.minimal")
        XCTAssertNil(config.icon)
        XCTAssertNil(config.filter)
        XCTAssertNil(config.action.script)
    }
    
    // MARK: - Matcher Tests
    
    func testPluginRegexMatcher() throws {
        let json = """
        {
            "name": "Regex Matcher",
            "identifier": "com.test.regex",
            "filter": {
                "regex": "^[a-zA-Z0-9]+$"
            },
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!
        
        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/"))
        
        // Should match pure alphanumeric
        XCTAssertTrue(plugin.shouldShow(text: "HelloWorld123", appBundleID: nil as String?))
        XCTAssertTrue(plugin.shouldShow(text: "test", appBundleID: nil as String?))
        
        // Should reject symbols
        XCTAssertFalse(plugin.shouldShow(text: "Hello World", appBundleID: nil as String?)) // space
        XCTAssertFalse(plugin.shouldShow(text: "test@domain.com", appBundleID: nil as String?)) // @ and .
    }
    
    func testPluginEmptyRegexAllowsEverything() throws {
        let json = """
        {
            "name": "Omni Matcher",
            "identifier": "com.test.omni",
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!
        
        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/"))
        
        XCTAssertTrue(plugin.shouldShow(text: "", appBundleID: nil as String?))
        XCTAssertTrue(plugin.shouldShow(text: "Any text", appBundleID: nil as String?))
        XCTAssertTrue(plugin.shouldShow(text: "https://apple.com", appBundleID: nil as String?))
    }
    
    func testPluginTypeMatcher() throws {
        let json = """
        {
            "name": "URL Matcher",
            "identifier": "com.test.url",
            "filter": {},
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!
        
        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/"))
        
        // Types no longer implemented strictly as "URL" validation inside Plugin object 
        // We now rely purely on NSDataDetector outside, but if the plugin config exists we just test it parses without crashing.
        // Should Show will just return true if there's no regex/length constraints.
        XCTAssertTrue(plugin.shouldShow(text: "https://github.com", appBundleID: nil as String?))
        XCTAssertTrue(plugin.shouldShow(text: "just some text", appBundleID: nil as String?))
    }

    func testDecodeRevealPathPluginJSON() throws {
        let json = """
        {
            "name": "Reveal Path",
            "identifier": "com.test.reveal",
            "action": { "type": "reveal-path" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)

        XCTAssertEqual(config.action.type, .revealPath)
    }

    func testPluginRespectsLengthAndAppFilters() throws {
        let json = """
        {
            "name": "Scoped",
            "identifier": "com.test.scoped",
            "filter": {
                "minLength": 3,
                "maxLength": 5,
                "apps": ["com.apple.Safari"],
                "excludeApps": ["com.apple.finder"]
            },
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/"))

        XCTAssertFalse(plugin.shouldShow(text: "hi", appBundleID: "com.apple.Safari"))
        XCTAssertTrue(plugin.shouldShow(text: "hello", appBundleID: " COM.APPLE.SAFARI "))
        XCTAssertFalse(plugin.shouldShow(text: "toolong", appBundleID: "com.apple.Safari"))
        XCTAssertFalse(plugin.shouldShow(text: "test", appBundleID: "COM.APPLE.FINDER"))
        XCTAssertFalse(plugin.shouldShow(text: "test", appBundleID: nil))
    }

    func testScriptPluginRequiresExecutionTrust() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.test.shell",
            actionType: "shell-script",
            scriptName: "script.sh",
            scriptContent: "echo test"
        )
        let plugin = try XCTUnwrap(PluginLoader.load(from: bundleURL))

        XCTAssertTrue(plugin.requiresExecutionTrust)
        XCTAssertNotNil(plugin.executionTrustFingerprint)
    }

    func testExternalKeyComboPluginRequiresExecutionTrust() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.test.quit",
            actionJSON: #"{ "type": "key-combo", "key": "q", "modifiers": ["cmd"] }"#
        )
        let plugin = try XCTUnwrap(PluginLoader.load(from: bundleURL))

        XCTAssertTrue(plugin.requiresExecutionTrust)
        XCTAssertNotNil(plugin.executionTrustFingerprint)
    }

    func testPluginLoaderRejectsPackageAboveExecutionLimit() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.test.oversized",
            actionType: "shell-script",
            scriptName: "script.sh",
            scriptContent: "echo test"
        )
        let oversizedURL = bundleURL.appendingPathComponent("oversized.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(Plugin.maximumTrustedPackageBytes + 1))
        try handle.close()

        XCTAssertNil(PluginLoader.load(from: bundleURL))
    }

    func testPluginLoaderRejectsOversizedConfig() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".actionhaloext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let configURL = bundleURL.appendingPathComponent("Config.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: configURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: configURL)
        try handle.truncate(atOffset: UInt64(PluginLoader.maximumConfigBytes + 1))
        try handle.close()

        XCTAssertNil(PluginLoader.load(from: bundleURL))
    }

    func testPluginLoaderRejectsSymbolicLinkConfig() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".actionhaloext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let outsideConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        temporaryDirectories.append(outsideConfigURL)
        try """
        {
            "name": "Outside",
            "identifier": "com.test.outside",
            "action": { "type": "copy" }
        }
        """.write(to: outsideConfigURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: bundleURL.appendingPathComponent("Config.json"),
            withDestinationURL: outsideConfigURL
        )

        XCTAssertNil(PluginLoader.load(from: bundleURL))
    }

    func testPluginLoaderRejectsSymbolicLinkPackageRoot() throws {
        let realBundleURL = try makePluginBundle(
            identifier: "com.test.symlink-root",
            actionJSON: #"{ "type": "copy" }"#
        )
        let symbolicLinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".actionhaloext")
        temporaryDirectories.append(symbolicLinkURL)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: realBundleURL
        )

        XCTAssertNil(PluginLoader.load(from: symbolicLinkURL))
    }

    func testPluginLoaderRejectsUnsafeIdentifier() throws {
        let bundleURL = try makePluginBundle(
            identifier: "../../victim",
            actionJSON: #"{ "type": "copy" }"#
        )

        XCTAssertNil(PluginLoader.load(from: bundleURL))
    }

    func testPluginLoaderOnlyAllowsReservedCoreIdentifierForBuiltInScan() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.actionhalo.copy",
            actionJSON: #"{ "type": "copy" }"#
        )

        XCTAssertNil(PluginLoader.load(from: bundleURL))
        XCTAssertNotNil(
            PluginLoader.load(
                from: bundleURL,
                allowReservedCoreIdentifier: true
            )
        )
    }

    func testPluginLoaderScansLegacyPackageAndCanonicalizesIdentifier() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectories.append(directoryURL)
        let legacyBundleURL = directoryURL.appendingPathComponent(
            "Legacy.openfireext",
            isDirectory: true
        )
        let currentBundleURL = directoryURL.appendingPathComponent(
            "Current.actionhaloext",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyBundleURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentBundleURL,
            withIntermediateDirectories: true
        )
        try """
        {
            "name": "Legacy",
            "identifier": "com.openfire.legacy-search",
            "action": { "type": "copy" }
        }
        """.write(
            to: legacyBundleURL.appendingPathComponent("Config.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
            "name": "Current",
            "identifier": "com.actionhalo.current-search",
            "action": { "type": "copy" }
        }
        """.write(
            to: currentBundleURL.appendingPathComponent("Config.json"),
            atomically: true,
            encoding: .utf8
        )

        let plugins = PluginLoader.scanDirectory(directoryURL)

        XCTAssertEqual(
            Set(plugins.map(\.id)),
            ["com.actionhalo.legacy-search", "com.actionhalo.current-search"]
        )
        XCTAssertTrue(PluginLoader.isSupportedPackageURL(legacyBundleURL))
        XCTAssertTrue(PluginLoader.isSupportedPackageURL(currentBundleURL))
    }

    func testCoreDefaultKeyComboPluginDoesNotRequireExecutionTrust() throws {
        let json = """
        {
            "name": "Delete",
            "identifier": "com.actionhalo.delete",
            "action": { "type": "key-combo", "key": "delete" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/plugin"))

        XCTAssertFalse(plugin.requiresExecutionTrust)
        XCTAssertNil(plugin.executionTrustFingerprint)
    }

    func testCoreDefaultKeyComboUsesDirectExecutionPolicy() throws {
        let json = """
        {
            "name": "Delete",
            "identifier": "com.actionhalo.delete",
            "action": { "type": "key-combo", "key": "delete" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/plugin"))

        XCTAssertEqual(PluginManager.executionPolicy(for: plugin), .directKeyCombo)
    }

    func testExternalKeyComboUsesProtectedExecutionPolicy() throws {
        let json = """
        {
            "name": "Quit App",
            "identifier": "com.example.quit",
            "action": {
                "type": "key-combo",
                "key": "q",
                "modifiers": ["command"]
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/plugin"))

        XCTAssertEqual(PluginManager.executionPolicy(for: plugin), .protected)
    }

    func testScriptPluginUsesProtectedExecutionPolicy() throws {
        let json = """
        {
            "name": "Script",
            "identifier": "com.example.script",
            "action": {
                "type": "shell-script",
                "inline": "printf test"
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/plugin"))

        XCTAssertEqual(PluginManager.executionPolicy(for: plugin), .protected)
    }

    func testVisibilityDiagnosticExplainsWhyPluginIsHidden() throws {
        let json = """
        {
            "name": "Scoped",
            "identifier": "com.test.hidden-reasons",
            "filter": {
                "minLength": 5,
                "regex": "^https://",
                "apps": ["com.apple.Safari"]
            },
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/"))
        plugin.isEnabled = false

        let diagnostic = plugin.visibilityDiagnostic(text: "abc", appBundleID: "com.apple.TextEdit")

        XCTAssertFalse(diagnostic.isVisible)
        XCTAssertEqual(diagnostic.reasons.count, 4)
        XCTAssertTrue(diagnostic.reasons.contains(.disabled))
        XCTAssertTrue(diagnostic.reasons.contains(.textTooShort(min: 5, actual: 3)))
        XCTAssertTrue(diagnostic.reasons.contains(.regexNoMatch("^https://")))
        XCTAssertTrue(diagnostic.reasons.contains(.appNotAllowed(current: "com.apple.TextEdit", allowed: ["com.apple.Safari"])))
    }

    func testVisibilityDiagnosticIsVisibleWhenPluginMatchesContext() throws {
        let json = """
        {
            "name": "Visible",
            "identifier": "com.test.visible",
            "filter": {
                "minLength": 3,
                "regex": "^https://",
                "apps": ["com.apple.Safari"]
            },
            "action": { "type": "copy" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: "/"))

        let diagnostic = plugin.visibilityDiagnostic(text: "https://openai.com", appBundleID: "com.apple.Safari")

        XCTAssertTrue(diagnostic.isVisible)
        XCTAssertTrue(diagnostic.reasons.isEmpty)
    }

    func testExecutionTrustFingerprintChangesWhenScriptContentChanges() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.test.fingerprint",
            actionType: "shell-script",
            scriptName: "script.sh",
            scriptContent: "echo first"
        )

        let pluginA = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        let fingerprintA = try XCTUnwrap(pluginA.executionTrustFingerprint)

        try "echo second".write(to: bundleURL.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)

        let pluginB = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        let fingerprintB = try XCTUnwrap(pluginB.executionTrustFingerprint)

        XCTAssertNotEqual(fingerprintA, fingerprintB)
    }

    func testExecutionTrustFingerprintChangesWhenHelperFileChanges() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.test.fingerprint-helper",
            actionType: "shell-script",
            scriptName: "script.sh",
            scriptContent: "source helper.sh"
        )
        let helperURL = bundleURL.appendingPathComponent("helper.sh")
        try "echo first".write(to: helperURL, atomically: true, encoding: .utf8)

        let pluginA = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        let fingerprintA = try XCTUnwrap(pluginA.executionTrustFingerprint)

        try "echo second".write(to: helperURL, atomically: true, encoding: .utf8)

        let pluginB = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        let fingerprintB = try XCTUnwrap(pluginB.executionTrustFingerprint)

        XCTAssertNotEqual(fingerprintA, fingerprintB)
    }

    func testExecutionTrustFingerprintChangesWhenExecutableModeChanges() throws {
        let bundleURL = try makePluginBundle(
            identifier: "com.test.fingerprint-mode",
            actionType: "shell-script",
            scriptName: "script.sh",
            scriptContent: "echo first"
        )
        let scriptURL = bundleURL.appendingPathComponent("script.sh")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: scriptURL.path
        )
        let first = try XCTUnwrap(
            PluginLoader.load(from: bundleURL)?.executionTrustFingerprint
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let second = try XCTUnwrap(
            PluginLoader.load(from: bundleURL)?.executionTrustFingerprint
        )

        XCTAssertNotEqual(first, second)
    }

    func testAmbiguousQuantifiersAreMatchedWithoutBacktracking() throws {
        for pattern in ["(a+)+$", "(a|aa)+$", "(a|a?)+$"] {
            let config = PluginConfig(
                name: "Ambiguous Regex",
                localizedNames: nil,
                identifier: "com.test.ambiguous-regex",
                action: PluginActionConfig(
                    type: .copy,
                    url: nil,
                    script: nil,
                    inline: nil,
                    key: nil,
                    modifiers: nil
                ),
                icon: nil,
                description: nil,
                localizedDescriptions: nil,
                filter: PluginFilter(
                    minLength: nil,
                    maxLength: nil,
                    regex: pattern,
                    apps: nil,
                    excludeApps: nil
                ),
                order: nil,
                isDefaultDisabled: nil
            )
            let plugin = Plugin(
                config: config,
                directoryURL: URL(fileURLWithPath: "/")
            )

            XCTAssertTrue(
                plugin.shouldShow(text: "aaaa", appBundleID: nil),
                "Expected \(pattern) to preserve normal matching semantics"
            )

            let diagnostic = plugin.visibilityDiagnostic(
                text: String(repeating: "a", count: 2_047) + "!",
                appBundleID: nil
            )
            if pattern == "(a|a?)+$" {
                // `a?` can match an empty branch, so an unanchored search
                // correctly finds an empty match immediately before `$`.
                XCTAssertFalse(
                    diagnostic.reasons.contains(.regexNoMatch(pattern)),
                    "Expected \(pattern) to finish safely and preserve its empty-match semantics"
                )
            } else {
                XCTAssertTrue(
                    diagnostic.reasons.contains(.regexNoMatch(pattern)),
                    "Expected \(pattern) to finish safely with no match"
                )
            }
            XCTAssertFalse(diagnostic.reasons.contains(.invalidRegex(pattern)))
        }
    }

    func testPluginRejectsRegexFeaturesOutsideLinearSubset() {
        for pattern in [#"(a)\1"#, #"a(?=b)"#, #"(?i)abc"#, #"a+?"#] {
            let config = PluginConfig(
                name: "Unsupported Regex",
                localizedNames: nil,
                identifier: "com.test.unsupported-regex",
                action: PluginActionConfig(
                    type: .copy,
                    url: nil,
                    script: nil,
                    inline: nil,
                    key: nil,
                    modifiers: nil
                ),
                icon: nil,
                description: nil,
                localizedDescriptions: nil,
                filter: PluginFilter(
                    minLength: nil,
                    maxLength: nil,
                    regex: pattern,
                    apps: nil,
                    excludeApps: nil
                ),
                order: nil,
                isDefaultDisabled: nil
            )
            let plugin = Plugin(
                config: config,
                directoryURL: URL(fileURLWithPath: "/")
            )

            let diagnostic = plugin.visibilityDiagnostic(text: "abc", appBundleID: nil)

            XCTAssertTrue(diagnostic.reasons.contains(.invalidRegex(pattern)))
        }
    }

    func testBuiltInPluginRegexesRemainCompatibleWithLinearMatcher() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let openURL = try XCTUnwrap(
            PluginLoader.load(
                from: repositoryRoot.appendingPathComponent("Plugins/OpenURL.actionhaloext"),
                allowReservedCoreIdentifier: true
            )
        )
        let revealPath = try XCTUnwrap(
            PluginLoader.load(
                from: repositoryRoot.appendingPathComponent("Plugins/RevealPath.actionhaloext"),
                allowReservedCoreIdentifier: true
            )
        )

        XCTAssertTrue(openURL.shouldShow(text: "https://openai.com/docs", appBundleID: nil))
        XCTAssertTrue(openURL.shouldShow(text: "www.example.com", appBundleID: nil))
        XCTAssertFalse(openURL.shouldShow(text: "plain text", appBundleID: nil))

        XCTAssertTrue(revealPath.shouldShow(text: "  ~/Documents/file.txt  ", appBundleID: nil))
        XCTAssertTrue(revealPath.shouldShow(text: "file:///tmp/example.txt", appBundleID: nil))
        XCTAssertFalse(revealPath.shouldShow(text: "relative/path", appBundleID: nil))
    }

    func testDeleteBuiltInPluginUsesDeleteKeyCombo() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repositoryRoot.appendingPathComponent(
            "Plugins/Delete.actionhaloext"
        )
        let plugin = try XCTUnwrap(
            PluginLoader.load(
                from: pluginURL,
                allowReservedCoreIdentifier: true
            )
        )

        XCTAssertEqual(plugin.id, "com.actionhalo.delete")
        XCTAssertEqual(plugin.config.action.type, .keyCombo)
        XCTAssertEqual(plugin.config.action.key, "delete")
        XCTAssertTrue(PluginManager.coreDefaultPluginIDs.contains(plugin.id))
    }

    private func makePluginBundle(identifier: String, actionType: String, scriptName: String, scriptContent: String) throws -> URL {
        let actionJSON = #"{ "type": "\#(actionType)", "script": "\#(scriptName)" }"#
        let bundleURL = try makePluginBundle(identifier: identifier, actionJSON: actionJSON)
        try scriptContent.write(to: bundleURL.appendingPathComponent(scriptName), atomically: true, encoding: .utf8)
        return bundleURL
    }

    private func makePluginBundle(identifier: String, actionJSON: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".actionhaloext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let config = """
        {
            "name": "Temp Plugin",
            "identifier": "\(identifier)",
            "action": \(actionJSON)
        }
        """
        try config.write(to: bundleURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        return bundleURL
    }
}

final class PluginTrustStateTests: GlobalStateTestCase {
    func testProtectedPluginWithoutReadablePackageFailsClosed() throws {
        let json = """
        {
            "name": "Missing",
            "identifier": "com.test.missing",
            "action": { "type": "shell-script", "script": "script.sh" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".actionhaloext")
        let plugin = Plugin(config: config, directoryURL: missingURL)

        XCTAssertTrue(plugin.requiresExecutionTrust)
        XCTAssertNil(plugin.executionTrustFingerprint)
        XCTAssertFalse(PluginManager.shared.isExecutionTrusted(for: plugin))
    }
}
