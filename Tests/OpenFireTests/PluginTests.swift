import XCTest
@testable import OpenFire

final class PluginTests: XCTestCase {
    
    // MARK: - Decoding Tests
    
    func testDecodeCompletePluginJSON() throws {
        let json = """
        {
            "identifier": "com.test.plugin",
            "name": "Test Plugin",
            "description": "A detailed test plugin",
            "icon": "star.fill",
            "author": "OpenFire",
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
}
