// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "InterfaceCoverage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "interface-coverage", targets: ["InterfaceCoverageCLI"]),
        .library(name: "InterfaceCoverage", targets: ["InterfaceCoverage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "InterfaceCoverage",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            resources: [.copy("SiteAssets")]
        ),
        .executableTarget(
            name: "InterfaceCoverageCLI",
            dependencies: [
                "InterfaceCoverage",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "InterfaceCoverageTests", dependencies: ["InterfaceCoverage"]),
    ]
)
