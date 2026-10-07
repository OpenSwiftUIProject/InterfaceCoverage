import Foundation

public struct InterfaceInput: Sendable, Codable {
    public let path: String
    public let module: String
    public let target: String?
    public let source: String

    public init(path: String, module: String, target: String? = nil, source: String) {
        self.path = path
        self.module = module
        self.target = target
        self.source = source
    }

    public static func read(path: String) throws -> Self {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let flags = source.split(separator: "\n").first { $0.hasPrefix("// swift-module-flags:") }
        let words = flags?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        func value(after flag: String) -> String? {
            guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
            return words[index + 1]
        }
        guard let module = value(after: "-module-name") else {
            throw CoverageError("\(path): missing -module-name in the swift-module-flags header")
        }
        return Self(path: path, module: module, target: value(after: "-target"), source: source)
    }
}

public struct ScanOptions: Sendable, Codable {
    public var moduleAliases: [String: String]
    public var ignoredNamespaces: [String]
    public var excludeUnderscored: Bool
    public var includeSPI: Bool
    public var platform: String?

    private enum CodingKeys: String, CodingKey {
        case moduleAliases, ignoredNamespaces, excludeUnderscored, includeSPI, platform
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            moduleAliases: try values.decode([String: String].self, forKey: .moduleAliases),
            ignoredNamespaces: try values.decodeIfPresent([String].self, forKey: .ignoredNamespaces) ?? [],
            excludeUnderscored: try values.decode(Bool.self, forKey: .excludeUnderscored),
            includeSPI: try values.decode(Bool.self, forKey: .includeSPI),
            platform: try values.decodeIfPresent(String.self, forKey: .platform)
        )
    }

    public init(
        moduleAliases: [String: String] = [
            "OpenSwiftUI": "SwiftUI",
            "OpenSwiftUICore": "SwiftUICore",
            "OpenCombine": "Combine",
            "OpenCombineFoundation": "Combine",
            "OpenCombineDispatch": "Combine",
        ],
        ignoredNamespaces: [String] = [],
        excludeUnderscored: Bool = false,
        includeSPI: Bool = false,
        platform: String? = nil
    ) {
        self.moduleAliases = moduleAliases
        self.ignoredNamespaces = Array(Set(ignoredNamespaces)).sorted()
        self.excludeUnderscored = excludeUnderscored
        self.includeSPI = includeSPI
        self.platform = platform
    }
}

public enum APIKind: String, Sendable, Codable, CaseIterable {
    case `struct`, `enum`, `class`, `actor`, `protocol`, `typealias`, `associatedtype`
    case function, initializer, variable, `subscript`, enumCase, inheritance, macro, `operator`, precedenceGroup
}

public struct SourceLocation: Sendable, Codable, Hashable {
    public let path: String
    public let line: Int
}

public struct APIEntry: Sendable, Codable {
    public let kind: APIKind
    public let owner: String
    public let name: String
    public let signature: String
    public var locations: [SourceLocation]

    public var id: String { "\(kind.rawValue)|\(owner)|\(signature)" }
}

public struct Inventory: Sendable {
    public let entries: [APIEntry]
}

public struct CoverageCount: Sendable, Codable {
    public let reference: Int
    public let matched: Int
    public let missing: Int
    public let extra: Int

    public let percent: Double?

    init(reference: Int, matched: Int, missing: Int, extra: Int) {
        self.reference = reference
        self.matched = matched
        self.missing = missing
        self.extra = extra
        self.percent = reference == 0 ? nil : Double(matched) / Double(reference) * 100
    }
}

public struct KindCoverage: Sendable, Codable {
    public let kind: APIKind
    public let count: CoverageCount
}

public struct CoverageReport: Sendable, Codable {
    public let schemaVersion: Int
    public let summary: CoverageCount
    public let byKind: [KindCoverage]
    public let matched: [APIEntry]
    public let missing: [APIEntry]
    public let extra: [APIEntry]

    public static func compare(reference: Inventory, candidate: Inventory) -> Self {
        let expected = Dictionary(uniqueKeysWithValues: reference.entries.map { ($0.id, $0) })
        let actual = Dictionary(uniqueKeysWithValues: candidate.entries.map { ($0.id, $0) })
        let matched = reference.entries.filter { actual[$0.id] != nil }
        let missing = reference.entries.filter { actual[$0.id] == nil }
        let extra = candidate.entries.filter { expected[$0.id] == nil }
        func count(_ kind: APIKind? = nil) -> CoverageCount {
            func total(_ entries: [APIEntry]) -> Int {
                entries.filter { kind == nil || $0.kind == kind }.count
            }
            return CoverageCount(
                reference: total(reference.entries), matched: total(matched),
                missing: total(missing), extra: total(extra)
            )
        }
        return Self(
            schemaVersion: 1, summary: count(),
            byKind: APIKind.allCases.compactMap { kind in
                let result = count(kind)
                return result.reference + result.extra == 0 ? nil : KindCoverage(kind: kind, count: result)
            },
            matched: matched, missing: missing, extra: extra
        )
    }
}

public struct CoverageError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
