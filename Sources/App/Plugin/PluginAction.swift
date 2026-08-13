import Cocoa
import CryptoKit

/// Represents a single plugin action type and its execution parameters
enum PluginActionType: String, Codable, Sendable {
    case url = "url"
    case shellScript = "shell-script"
    case applescript = "applescript"
    case keyCombo = "key-combo"
    case copy = "copy"
    case paste = "paste"
    case revealPath = "reveal-path"
}

struct PluginActionConfig: Codable, Equatable, Sendable {
    let type: PluginActionType
    var url: String?
    var script: String?
    var inline: String?
    var key: String?
    var modifiers: [String]?
}

/// Plugin filter configuration
struct PluginFilter: Codable, Equatable, Sendable {
    var minLength: Int?
    var maxLength: Int?
    var regex: String?
    var apps: [String]?
    var excludeApps: [String]?
}

/// Plugin configuration decoded from Config.json
struct PluginConfig: Codable, Equatable, Sendable {
    let name: String
    var localizedNames: [String: String]?
    let identifier: String
    let action: PluginActionConfig
    var icon: String?
    var description: String?
    var localizedDescriptions: [String: String]?
    var filter: PluginFilter?
    var order: Int?
    var isDefaultDisabled: Bool?
}

enum PluginVisibilityReason: Equatable, Sendable {
    case disabled
    case disabledForApp(String)
    case textTooShort(min: Int, actual: Int)
    case textTooLong(max: Int, actual: Int)
    case invalidRegex(String)
    case regexNoMatch(String)
    case appNotAllowed(current: String?, allowed: [String])
    case appExcluded(String)
}

struct PluginVisibilityDiagnostic {
    let plugin: Plugin
    let reasons: [PluginVisibilityReason]

    var isVisible: Bool {
        reasons.isEmpty
    }
}

/// A restricted, non-backtracking regular-expression engine for plugin filters.
///
/// Plugin configuration is untrusted and filtering happens on the UI path. A blacklist cannot
/// make Foundation's backtracking matcher safe because there are many ambiguous expressions
/// beyond nested quantifiers. This parser accepts the regular subset used by OpenFire plugins
/// (groups, alternation, character classes, anchors and quantifiers), then compiles it to a
/// Thompson NFA. Matching has no backtracking and stops at a fixed work budget. Lookarounds,
/// backreferences, mode modifiers, lazy quantifiers and possessive quantifiers are rejected.
private struct LinearRegex: Sendable {
    private static let maximumStateCount = 512
    private static let maximumGroupDepth = 32
    private static let maximumFiniteRepetition = 64
    private static let maximumEvaluationSteps = 200_000

    private indirect enum Node: Sendable {
        case empty
        case scalar(ScalarMatcher)
        case startAnchor
        case endAnchor
        case concatenation([Node])
        case alternation([Node])
        case repetition(Node, minimum: Int, maximum: Int?)
    }

    private enum CharacterCategory: Sendable {
        case whitespace
        case nonWhitespace
        case decimalDigit
        case nonDecimalDigit
        case word
        case nonWord

        func matches(_ scalar: Unicode.Scalar) -> Bool {
            switch self {
            case .whitespace:
                return CharacterSet.whitespacesAndNewlines.contains(scalar)
            case .nonWhitespace:
                return !CharacterSet.whitespacesAndNewlines.contains(scalar)
            case .decimalDigit:
                return CharacterSet.decimalDigits.contains(scalar)
            case .nonDecimalDigit:
                return !CharacterSet.decimalDigits.contains(scalar)
            case .word:
                return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
            case .nonWord:
                return scalar != "_" && !CharacterSet.alphanumerics.contains(scalar)
            }
        }
    }

    private enum CharacterClassElement: Sendable {
        case literal(Unicode.Scalar)
        case range(ClosedRange<UInt32>)
        case category(CharacterCategory)

        func matches(_ scalar: Unicode.Scalar) -> Bool {
            switch self {
            case .literal(let expected):
                return scalar == expected
            case .range(let range):
                return range.contains(scalar.value)
            case .category(let category):
                return category.matches(scalar)
            }
        }
    }

    private enum ScalarMatcher: Sendable {
        case literal(Unicode.Scalar)
        case anyNonNewline
        case category(CharacterCategory)
        case characterClass(elements: [CharacterClassElement], inverted: Bool)

        func matches(_ scalar: Unicode.Scalar, remainingSteps: inout Int) -> Bool? {
            guard remainingSteps > 0 else { return nil }
            remainingSteps -= 1

            switch self {
            case .literal(let expected):
                return scalar == expected
            case .anyNonNewline:
                return !CharacterSet.newlines.contains(scalar)
            case .category(let category):
                return category.matches(scalar)
            case .characterClass(let elements, let inverted):
                var contains = false
                for element in elements {
                    guard remainingSteps > 0 else { return nil }
                    remainingSteps -= 1
                    if element.matches(scalar) {
                        contains = true
                        break
                    }
                }
                return inverted ? !contains : contains
            }
        }
    }

    private enum Edge: Sendable {
        case epsilon(Int)
        case scalar(ScalarMatcher, Int)
        case startAnchor(Int)
        case endAnchor(Int)
    }

    private struct State: Sendable {
        var edges: [Edge] = []
        var isAccepting = false
    }

    private struct Fragment: Sendable {
        let start: Int
        let end: Int
    }

    private enum ParseError: Error {
        case invalidSyntax
        case limitExceeded
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var groupDepth = 0

        mutating func parse() throws -> Node {
            let node = try parseAlternation()
            guard index == scalars.count else { throw ParseError.invalidSyntax }
            return node
        }

        private mutating func parseAlternation() throws -> Node {
            var branches = [try parseConcatenation()]
            while consume("|") {
                branches.append(try parseConcatenation())
            }
            return branches.count == 1 ? branches[0] : .alternation(branches)
        }

        private mutating func parseConcatenation() throws -> Node {
            var nodes: [Node] = []
            while let scalar = peek(), scalar != ")", scalar != "|" {
                let atom = try parseAtom()
                nodes.append(try parseQuantifier(for: atom))
            }

            if nodes.isEmpty {
                return .empty
            }
            return nodes.count == 1 ? nodes[0] : .concatenation(nodes)
        }

        private mutating func parseAtom() throws -> Node {
            guard let scalar = advance() else { throw ParseError.invalidSyntax }
            switch scalar {
            case "^":
                return .startAnchor
            case "$":
                return .endAnchor
            case ".":
                return .scalar(.anyNonNewline)
            case "[":
                return .scalar(try parseCharacterClass())
            case "(":
                groupDepth += 1
                guard groupDepth <= LinearRegex.maximumGroupDepth else {
                    throw ParseError.limitExceeded
                }
                if consume("?") {
                    guard consume(":") else { throw ParseError.invalidSyntax }
                }
                let node = try parseAlternation()
                guard consume(")") else { throw ParseError.invalidSyntax }
                groupDepth -= 1
                return node
            case "\\":
                return .scalar(try parseEscapedMatcher())
            case "*", "+", "?", "{", "}", ")":
                throw ParseError.invalidSyntax
            default:
                return .scalar(.literal(scalar))
            }
        }

        private mutating func parseQuantifier(for node: Node) throws -> Node {
            let quantified: Node
            switch peek() {
            case "*":
                _ = advance()
                quantified = .repetition(node, minimum: 0, maximum: nil)
            case "+":
                _ = advance()
                quantified = .repetition(node, minimum: 1, maximum: nil)
            case "?":
                _ = advance()
                quantified = .repetition(node, minimum: 0, maximum: 1)
            case "{":
                _ = advance()
                let minimum = try parseDecimalInteger()
                let maximum: Int?
                if consume("}") {
                    maximum = minimum
                } else {
                    guard consume(",") else { throw ParseError.invalidSyntax }
                    if consume("}") {
                        maximum = nil
                    } else {
                        maximum = try parseDecimalInteger()
                        guard consume("}") else { throw ParseError.invalidSyntax }
                    }
                }

                guard minimum <= LinearRegex.maximumFiniteRepetition,
                      maximum.map({
                          $0 <= LinearRegex.maximumFiniteRepetition && $0 >= minimum
                      }) ?? true else {
                    throw ParseError.limitExceeded
                }
                quantified = .repetition(node, minimum: minimum, maximum: maximum)
            default:
                return node
            }

            switch node {
            case .startAnchor, .endAnchor:
                throw ParseError.invalidSyntax
            default:
                break
            }

            if let next = peek(), next == "?" || next == "+" || next == "*"
                || next == "{" {
                throw ParseError.invalidSyntax
            }
            return quantified
        }

        private mutating func parseDecimalInteger() throws -> Int {
            let start = index
            var value = 0
            while let scalar = peek(), scalar.value >= 48, scalar.value <= 57 {
                let digit = Int(scalar.value - 48)
                guard value <= (LinearRegex.maximumFiniteRepetition - digit) / 10 else {
                    throw ParseError.limitExceeded
                }
                value = value * 10 + digit
                _ = advance()
            }
            guard index > start else { throw ParseError.invalidSyntax }
            return value
        }

        private mutating func parseEscapedMatcher() throws -> ScalarMatcher {
            guard let escaped = advance() else { throw ParseError.invalidSyntax }
            switch escaped {
            case "s":
                return .category(.whitespace)
            case "S":
                return .category(.nonWhitespace)
            case "d":
                return .category(.decimalDigit)
            case "D":
                return .category(.nonDecimalDigit)
            case "w":
                return .category(.word)
            case "W":
                return .category(.nonWord)
            case "n":
                return .literal("\n")
            case "r":
                return .literal("\r")
            case "t":
                return .literal("\t")
            case "f":
                return .literal("\u{000C}")
            case "v":
                return .literal("\u{000B}")
            default:
                guard !CharacterSet.alphanumerics.contains(escaped) else {
                    throw ParseError.invalidSyntax
                }
                return .literal(escaped)
            }
        }

        private mutating func parseCharacterClass() throws -> ScalarMatcher {
            let inverted = consume("^")
            var elements: [CharacterClassElement] = []

            while let scalar = peek(), scalar != "]" {
                let first = try parseCharacterClassElement()
                if peek() == "-" {
                    _ = advance()
                    if peek() == "]" {
                        elements.append(first)
                        elements.append(.literal("-"))
                        continue
                    }
                    let second = try parseCharacterClassElement()
                    guard case .literal(let lower) = first,
                          case .literal(let upper) = second,
                          lower.value <= upper.value else {
                        throw ParseError.invalidSyntax
                    }
                    elements.append(.range(lower.value...upper.value))
                } else {
                    elements.append(first)
                }
            }

            guard !elements.isEmpty, consume("]") else {
                throw ParseError.invalidSyntax
            }
            return .characterClass(elements: elements, inverted: inverted)
        }

        private mutating func parseCharacterClassElement() throws -> CharacterClassElement {
            guard let scalar = advance() else { throw ParseError.invalidSyntax }
            guard scalar == "\\" else { return .literal(scalar) }
            guard let escaped = advance() else { throw ParseError.invalidSyntax }
            switch escaped {
            case "s":
                return .category(.whitespace)
            case "S":
                return .category(.nonWhitespace)
            case "d":
                return .category(.decimalDigit)
            case "D":
                return .category(.nonDecimalDigit)
            case "w":
                return .category(.word)
            case "W":
                return .category(.nonWord)
            case "n":
                return .literal("\n")
            case "r":
                return .literal("\r")
            case "t":
                return .literal("\t")
            case "f":
                return .literal("\u{000C}")
            case "v":
                return .literal("\u{000B}")
            default:
                guard !CharacterSet.alphanumerics.contains(escaped) else {
                    throw ParseError.invalidSyntax
                }
                return .literal(escaped)
            }
        }

        private func peek() -> Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        @discardableResult
        private mutating func advance() -> Unicode.Scalar? {
            guard index < scalars.count else { return nil }
            defer { index += 1 }
            return scalars[index]
        }

        private mutating func consume(_ expected: Unicode.Scalar) -> Bool {
            guard peek() == expected else { return false }
            index += 1
            return true
        }
    }

    private struct Compiler {
        var states: [State] = []

        mutating func compile(_ node: Node) throws -> (states: [State], start: Int) {
            let fragment = try compileNode(node)
            states[fragment.end].isAccepting = true
            return (states, fragment.start)
        }

        private mutating func compileNode(_ node: Node) throws -> Fragment {
            switch node {
            case .empty:
                let start = try makeState()
                let end = try makeState()
                states[start].edges.append(.epsilon(end))
                return Fragment(start: start, end: end)
            case .scalar(let matcher):
                let start = try makeState()
                let end = try makeState()
                states[start].edges.append(.scalar(matcher, end))
                return Fragment(start: start, end: end)
            case .startAnchor:
                let start = try makeState()
                let end = try makeState()
                states[start].edges.append(.startAnchor(end))
                return Fragment(start: start, end: end)
            case .endAnchor:
                let start = try makeState()
                let end = try makeState()
                states[start].edges.append(.endAnchor(end))
                return Fragment(start: start, end: end)
            case .concatenation(let nodes):
                guard let first = nodes.first else { return try compileNode(.empty) }
                var result = try compileNode(first)
                for child in nodes.dropFirst() {
                    let next = try compileNode(child)
                    states[result.end].edges.append(.epsilon(next.start))
                    result = Fragment(start: result.start, end: next.end)
                }
                return result
            case .alternation(let nodes):
                let start = try makeState()
                let end = try makeState()
                for child in nodes {
                    let fragment = try compileNode(child)
                    states[start].edges.append(.epsilon(fragment.start))
                    states[fragment.end].edges.append(.epsilon(end))
                }
                return Fragment(start: start, end: end)
            case .repetition(let child, let minimum, let maximum):
                return try compileRepetition(
                    child,
                    minimum: minimum,
                    maximum: maximum
                )
            }
        }

        private mutating func compileRepetition(
            _ child: Node,
            minimum: Int,
            maximum: Int?
        ) throws -> Fragment {
            let start = try makeState()
            var current = start

            for _ in 0..<minimum {
                let required = try compileNode(child)
                states[current].edges.append(.epsilon(required.start))
                current = required.end
            }

            if let maximum {
                for _ in minimum..<maximum {
                    let next = try makeState()
                    let optional = try compileNode(child)
                    states[current].edges.append(.epsilon(next))
                    states[current].edges.append(.epsilon(optional.start))
                    states[optional.end].edges.append(.epsilon(next))
                    current = next
                }
                let end = try makeState()
                states[current].edges.append(.epsilon(end))
                return Fragment(start: start, end: end)
            }

            let end = try makeState()
            states[current].edges.append(.epsilon(end))
            let repeated = try compileNode(child)
            states[current].edges.append(.epsilon(repeated.start))
            states[repeated.end].edges.append(.epsilon(current))
            return Fragment(start: start, end: end)
        }

        private mutating func makeState() throws -> Int {
            guard states.count < LinearRegex.maximumStateCount else {
                throw ParseError.limitExceeded
            }
            states.append(State())
            return states.count - 1
        }
    }

    private let states: [State]
    private let start: Int

    init?(_ pattern: String) {
        guard !pattern.isEmpty else { return nil }
        var parser = Parser(scalars: Array(pattern.unicodeScalars))
        guard let node = try? parser.parse() else { return nil }
        var compiler = Compiler()
        guard let compiled = try? compiler.compile(node) else { return nil }
        states = compiled.states
        start = compiled.start
    }

    func firstMatch(in text: String) -> Bool {
        let input = Array(text.unicodeScalars)
        var remainingSteps = Self.maximumEvaluationSteps
        guard var active = epsilonClosure(
            from: [start],
            position: 0,
            inputCount: input.count,
            remainingSteps: &remainingSteps
        ) else {
            return false
        }
        if active.contains(where: { states[$0].isAccepting }) {
            return true
        }

        for (position, scalar) in input.enumerated() {
            var seeds = [start]
            for stateIndex in active {
                for edge in states[stateIndex].edges {
                    guard case .scalar(let matcher, let target) = edge else { continue }
                    guard let matches = matcher.matches(
                        scalar,
                        remainingSteps: &remainingSteps
                    ) else {
                        return false
                    }
                    if matches {
                        seeds.append(target)
                    }
                }
            }

            guard let next = epsilonClosure(
                from: seeds,
                position: position + 1,
                inputCount: input.count,
                remainingSteps: &remainingSteps
            ) else {
                return false
            }
            active = next
            if active.contains(where: { states[$0].isAccepting }) {
                return true
            }
        }

        return false
    }

    private func epsilonClosure(
        from seeds: [Int],
        position: Int,
        inputCount: Int,
        remainingSteps: inout Int
    ) -> [Int]? {
        var stack = seeds
        var visited = Array(repeating: false, count: states.count)
        var active: [Int] = []

        while let stateIndex = stack.popLast() {
            guard !visited[stateIndex] else { continue }
            guard remainingSteps > 0 else { return nil }
            remainingSteps -= 1
            visited[stateIndex] = true

            let state = states[stateIndex]
            var hasScalarEdge = false
            for edge in state.edges {
                guard remainingSteps > 0 else { return nil }
                remainingSteps -= 1
                switch edge {
                case .epsilon(let target):
                    stack.append(target)
                case .scalar:
                    hasScalarEdge = true
                case .startAnchor(let target) where position == 0:
                    stack.append(target)
                case .endAnchor(let target) where position == inputCount:
                    stack.append(target)
                case .startAnchor, .endAnchor:
                    break
                }
            }

            if state.isAccepting || hasScalarEdge {
                active.append(stateIndex)
            }
        }

        return active
    }
}

/// Represents a loaded plugin with its configuration and resources
/// Loaded plugin metadata is immutable and safe to inspect on worker queues.
/// The only mutable cross-thread value (`isEnabled`) is lock-protected, while
/// AppKit icon caching remains isolated to the main actor.
final class Plugin: Identifiable, Sendable {
    static let maximumTrustedPackageFileCount = 1_024
    static let maximumTrustedPackageBytes = 32 * 1024 * 1024
    static let maximumPackageTreeDepth = 32
    static let maximumRegexPatternBytes = 1_024
    static let maximumRegexInputUTF16Length = 4_096

    private struct TrustedPackageEntry {
        let url: URL
        let relativePath: String
        let size: Int
        let posixPermissions: Int
        let isDirectory: Bool
    }

    private enum FilterRegex: Sendable {
        case none
        case valid(LinearRegex)
        case invalid
    }

    let id: String
    let config: PluginConfig
    let directoryURL: URL
    private let filterRegex: FilterRegex
    private let enabledState = LockedState(initialState: true)

    var isEnabled: Bool {
        get { enabledState.withLock { $0 } }
        set { enabledState.withLock { $0 = newValue } }
    }
    
    init(config: PluginConfig, directoryURL: URL) {
        self.id = config.identifier
        self.config = config
        self.directoryURL = directoryURL

        if let pattern = config.filter?.regex {
            if pattern.utf8.count <= Self.maximumRegexPatternBytes,
               let expression = LinearRegex(pattern) {
                self.filterRegex = .valid(expression)
            } else {
                self.filterRegex = .invalid
            }
        } else {
            self.filterRegex = .none
        }
    }
    
    /// The display name of the plugin (localized if translation exists)
    var name: String {
        let preferredLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        let targetLang: String
        
        if preferredLanguage != "auto" {
            targetLang = preferredLanguage
        } else {
            let sysLang = Locale.preferredLanguages.first ?? "en"
            targetLang = sysLang.hasPrefix("zh") ? "zh-Hans" : "en"
        }
        
        if let locNames = config.localizedNames, let locName = locNames[targetLang] {
            return locName
        }
        
        return config.name.localized
    }
    
    /// The localized description of the plugin
    var localizedDescription: String? {
        let preferredLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        let targetLang: String
        
        if preferredLanguage != "auto" {
            targetLang = preferredLanguage
        } else {
            let sysLang = Locale.preferredLanguages.first ?? "en"
            targetLang = sysLang.hasPrefix("zh") ? "zh-Hans" : "en"
        }
        
        if let locDescs = config.localizedDescriptions, let locDesc = locDescs[targetLang] {
            return locDesc
        }
        
        return config.description?.localized
    }
    
    // MARK: - Lazy Icon Caching
    @MainActor private var _cachedCustomIcon: NSImage?
    @MainActor private var _didLoadCustomIcon = false
    
    /// Lazily load and cache the custom icon from disk to prevent main-thread IO
    @MainActor var customIcon: NSImage? {
        if _didLoadCustomIcon {
            return _cachedCustomIcon
        }
        let iconPath = directoryURL.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: iconPath.path) {
            _cachedCustomIcon = NSImage(contentsOf: iconPath)
        }
        _didLoadCustomIcon = true
        return _cachedCustomIcon
    }
    
    /// The SF Symbol icon name
    var iconName: String { config.icon ?? "puzzlepiece" }
    
    /// Sort order (lower = earlier, default 100)
    var order: Int { config.order ?? 100 }

    var requiresExecutionTrust: Bool {
        switch config.action.type {
        case .shellScript, .applescript:
            return true
        case .keyCombo:
            return !PluginManager.coreDefaultPluginIDs.contains(id) &&
                !PluginManager.isBuiltInPluginDirectory(directoryURL)
        default:
            return false
        }
    }

    var executionTrustFingerprint: String? {
        guard requiresExecutionTrust else { return nil }
        return packageFingerprint
    }

    /// Fingerprint of package content and execution-relevant filesystem metadata.
    ///
    /// This is available for every plugin, not only executable plugins, so install
    /// confirmation can be bound to the exact package that was previewed.
    var packageFingerprint: String? {
        guard let entries = trustedPackageEntries() else { return nil }

        var hasher = SHA256()
        Self.updateFingerprint(&hasher, with: Data("openfire-plugin-package-v3".utf8))

        for entry in entries {
            Self.updateFingerprint(&hasher, with: Data(entry.relativePath.utf8))
            Self.updateFingerprint(
                &hasher,
                with: Data(entry.isDirectory ? "directory".utf8 : "file".utf8)
            )
            Self.updateFingerprint(&hasher, with: Self.fingerprintLengthData(entry.posixPermissions))
            Self.updateFingerprint(&hasher, with: Self.fingerprintLengthData(entry.size))

            guard !entry.isDirectory else { continue }
            guard let handle = try? FileHandle(forReadingFrom: entry.url) else { return nil }
            var bytesRead = 0
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    bytesRead += chunk.count
                    hasher.update(data: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                return nil
            }

            guard bytesRead == entry.size else { return nil }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var canCreateProtectedExecutionSnapshot: Bool {
        requiresExecutionTrust && trustedPackageEntries() != nil
    }

    private func trustedPackageEntries() -> [TrustedPackageEntry]? {
        let fileManager = FileManager.default
        let rootKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let rootValues = try? directoryURL.resourceValues(forKeys: rootKeys),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let rootPermissions = Self.posixPermissions(
                at: directoryURL,
                fileManager: fileManager
              ) else {
            return nil
        }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                enumerationFailed = true
                NSLog("[OpenFire] Failed to enumerate trusted plugin file at \(url.path): \(error.localizedDescription)")
                return false
            }
        ) else {
            return nil
        }

        let rootPath = directoryURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var entries: [TrustedPackageEntry] = [
            TrustedPackageEntry(
                url: directoryURL,
                relativePath: ".",
                size: 0,
                posixPermissions: rootPermissions,
                isDirectory: true
            )
        ]
        var totalBytes = 0

        for case let entryURL as URL in enumerator {
            guard let values = try? entryURL.resourceValues(forKeys: Set(resourceKeys)) else {
                return nil
            }
            // A symlink can redirect execution to mutable content outside the trusted package.
            guard values.isSymbolicLink != true else { return nil }

            let standardizedPath = entryURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPrefix) else { return nil }
            let relativePath = String(standardizedPath.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty,
                  relativePath.split(separator: "/").count <= Self.maximumPackageTreeDepth,
                  entries.count - 1 < Self.maximumTrustedPackageFileCount,
                  let permissions = Self.posixPermissions(
                    at: entryURL,
                    fileManager: fileManager
                  ) else {
                return nil
            }

            if values.isDirectory == true {
                entries.append(
                    TrustedPackageEntry(
                        url: entryURL,
                        relativePath: relativePath,
                        size: 0,
                        posixPermissions: permissions,
                        isDirectory: true
                    )
                )
                continue
            }

            guard values.isRegularFile == true, let size = values.fileSize else { return nil }
            guard size >= 0,
                  size <= Self.maximumTrustedPackageBytes - totalBytes else {
                return nil
            }
            totalBytes += size
            entries.append(
                TrustedPackageEntry(
                    url: entryURL,
                    relativePath: relativePath,
                    size: size,
                    posixPermissions: permissions,
                    isDirectory: false
                )
            )
        }

        guard !enumerationFailed, entries.count > 1 else { return nil }
        return entries.sorted(by: { $0.relativePath < $1.relativePath })
    }

    private static func posixPermissions(
        at url: URL,
        fileManager: FileManager
    ) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let value = attributes[.posixPermissions] as? NSNumber {
            return value.intValue
        }
        return attributes[.posixPermissions] as? Int
    }

    private static func updateFingerprint(_ hasher: inout SHA256, with data: Data) {
        hasher.update(data: fingerprintLengthData(data.count))
        hasher.update(data: data)
    }

    private static func fingerprintLengthData(_ length: Int) -> Data {
        var value = UInt64(length).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    /// Check if this plugin should be shown for the given context
    func shouldShow(text: String, appBundleID: String?) -> Bool {
        visibilityDiagnostic(text: text, appBundleID: appBundleID).isVisible
    }

    func visibilityDiagnostic(text: String, appBundleID: String?) -> PluginVisibilityDiagnostic {
        var reasons: [PluginVisibilityReason] = []

        if !isEnabled {
            reasons.append(.disabled)
        }

        if let filter = config.filter {
            if let min = filter.minLength, text.count < min {
                reasons.append(.textTooShort(min: min, actual: text.count))
            }
            if let max = filter.maxLength, text.count > max {
                reasons.append(.textTooLong(max: max, actual: text.count))
            }

            if let pattern = filter.regex {
                switch filterRegex {
                case .valid(let regex)
                    where text.utf16.count <= Self.maximumRegexInputUTF16Length:
                    if !regex.firstMatch(in: text) {
                        reasons.append(.regexNoMatch(pattern))
                    }
                case .valid:
                    // Avoid evaluating untrusted expressions against unbounded text.
                    reasons.append(.regexNoMatch(pattern))
                case .invalid:
                    reasons.append(.invalidRegex(pattern))
                case .none:
                    break
                }
            }

            if let allowedApps = filter.apps, !allowedApps.isEmpty {
                if let bundleID = appBundleID {
                    if !AppExclusionStore.contains(bundleID, in: allowedApps) {
                        reasons.append(.appNotAllowed(current: bundleID, allowed: allowedApps))
                    }
                } else {
                    reasons.append(.appNotAllowed(current: nil, allowed: allowedApps))
                }
            }

            if let excludedApps = filter.excludeApps,
               !excludedApps.isEmpty,
               let bundleID = appBundleID,
               AppExclusionStore.contains(bundleID, in: excludedApps) {
                reasons.append(.appExcluded(bundleID))
            }
        }

        return PluginVisibilityDiagnostic(plugin: self, reasons: reasons)
    }
}
