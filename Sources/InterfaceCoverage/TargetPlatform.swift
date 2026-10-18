public struct TargetPlatform: Sendable, Equatable {
    public let platform: String
    public let environment: String
    public let architecture: String

    public init?(triple: String) {
        let parts = triple.split(separator: "-").map(String.init)
        guard parts.count >= 3 else { return nil }
        let names = ["macosx": "macOS", "macos": "macOS", "ios": "iOS", "tvos": "tvOS", "watchos": "watchOS", "xros": "visionOS", "linux": "Linux"]
        guard let key = names.keys.sorted().first(where: { parts[2].hasPrefix($0) }) else { return nil }
        architecture = parts[0]
        environment = parts.dropFirst(3).joined(separator: "-")
        platform = environment == "macabi" ? "macCatalyst" : names[key]!
    }

    public var comparisonKey: String { "\(platform)/\(environment)" }

    /// The architecture without its variant. arm64e and arm64 interfaces declare the same APIs.
    public var architectureFamily: String { architecture == "arm64e" ? "arm64" : architecture }
}
