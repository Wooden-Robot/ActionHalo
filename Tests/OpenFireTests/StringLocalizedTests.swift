import XCTest
@testable import OpenFire

final class StringLocalizedTests: XCTestCase {
    func testFallbackToEnglishWhenNoZhLanguage() {
        XCTAssertFalse(
            "Max Items in Menu".localized(preferredLanguage: "auto").isEmpty
        )
    }
    
    func testExplicitLanguageOverride() {
        let enString = "Copy".localized(preferredLanguage: "en")
        XCTAssertEqual(enString, "Copy")

        let zhString = "Copy".localized(preferredLanguage: "zh-Hans")
        XCTAssertEqual(zhString, "复制")
    }

    func testEveryStaticLocalizedKeyExistsInAllSupportedResources() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/App", isDirectory: true)
        let resourceURLs = [
            "en": repositoryRoot.appendingPathComponent(
                "Sources/App/Resources/en.lproj/Localizable.strings"
            ),
            "zh-Hans": repositoryRoot.appendingPathComponent(
                "Sources/App/Resources/zh-Hans.lproj/Localizable.strings"
            )
        ]

        let sourceKeys = try Self.staticLocalizedKeys(in: sourceRoot)
        XCTAssertFalse(sourceKeys.isEmpty, "Expected to discover static .localized keys in Sources/App")

        for (language, resourceURL) in resourceURLs {
            let resourceKeys = try Self.localizationKeys(in: resourceURL)
            let missingKeys = sourceKeys.subtracting(resourceKeys).sorted()
            XCTAssertTrue(
                missingKeys.isEmpty,
                "\(language) Localizable.strings is missing keys used by source:\n"
                    + missingKeys.joined(separator: "\n")
            )
        }
    }

    func testStaticLocalizedKeyDiscoveryIgnoresInterpolatedStrings() throws {
        let source = #"""
        "Static key".localized
        "\(dynamicValue)".localized
        "Prefix \(dynamicValue)".localized
        "\\(literal text)".localized
        """#

        XCTAssertEqual(
            try Self.staticLocalizedKeys(inSource: source),
            ["Static key", "\\(literal text)"]
        )
    }

    private static func staticLocalizedKeys(in sourceRoot: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Unable to enumerate source files at \(sourceRoot.path)")
            return []
        }

        var keys = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            keys.formUnion(try staticLocalizedKeys(inSource: source))
        }
        return keys
    }

    private static func staticLocalizedKeys(inSource source: String) throws -> Set<String> {
        let expression = try NSRegularExpression(
            pattern: #""((?:\\.|[^"\\])*)"\s*\.localized\b"#
        )
        let sourceRange = NSRange(source.startIndex..., in: source)

        return try Set(expression.matches(in: source, range: sourceRange).compactMap { match in
            guard let captureRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            let rawKey = String(source[captureRange])
            guard !containsUnescapedInterpolation(rawKey) else {
                return nil
            }
            return try decodeSwiftStringLiteralContents(rawKey)
        })
    }

    private static func containsUnescapedInterpolation(_ rawValue: String) -> Bool {
        let characters = Array(rawValue)
        for index in characters.indices where characters[index] == "(" {
            var precedingBackslashes = 0
            var cursor = index
            while cursor > characters.startIndex {
                cursor -= 1
                guard characters[cursor] == "\\" else { break }
                precedingBackslashes += 1
            }
            if precedingBackslashes % 2 == 1 {
                return true
            }
        }
        return false
    }

    private static func decodeSwiftStringLiteralContents(_ rawValue: String) throws -> String {
        var result = ""
        var index = rawValue.startIndex

        while index < rawValue.endIndex {
            let character = rawValue[index]
            guard character == "\\" else {
                result.append(character)
                index = rawValue.index(after: index)
                continue
            }

            let escapedIndex = rawValue.index(after: index)
            guard escapedIndex < rawValue.endIndex else {
                throw LocalizationTestError.invalidStringLiteral(rawValue)
            }

            switch rawValue[escapedIndex] {
            case "\\":
                result.append("\\")
            case "\"":
                result.append("\"")
            case "n":
                result.append("\n")
            case "r":
                result.append("\r")
            case "t":
                result.append("\t")
            case "0":
                result.append("\0")
            default:
                throw LocalizationTestError.unsupportedEscape(rawValue)
            }
            index = rawValue.index(after: escapedIndex)
        }

        return result
    }

    private static func localizationKeys(in resourceURL: URL) throws -> Set<String> {
        let data = try Data(contentsOf: resourceURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let localizations = propertyList as? [String: String] else {
            throw LocalizationTestError.invalidStringsFile(resourceURL.path)
        }
        return Set(localizations.keys)
    }

    private enum LocalizationTestError: Error {
        case invalidStringLiteral(String)
        case unsupportedEscape(String)
        case invalidStringsFile(String)
    }
}
