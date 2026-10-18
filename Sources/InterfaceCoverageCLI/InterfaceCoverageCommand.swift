import ArgumentParser
import CryptoKit
import Foundation
import InterfaceCoverage

@main
struct InterfaceCoverageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interface-coverage",
        abstract: "Compare Swift interfaces and generate coverage sites.",
        subcommands: [CompareInterfaces.self, GenerateSite.self],
        defaultSubcommand: CompareInterfaces.self
    )
}

struct GenerateSite: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "site", abstract: "Generate a static coverage site from a report manifest."
    )

    @Option(help: "JSON manifest. Report paths are relative to this file.")
    var manifest: String

    @Option(help: "Output directory. It must be empty or contain a site made by this tool.")
    var output: String

    func run() throws {
        try CoverageSite.generate(manifest: URL(fileURLWithPath: manifest), output: URL(fileURLWithPath: output))
        print("Coverage site: \(URL(fileURLWithPath: output).appendingPathComponent("index.html").path)")
    }
}

struct CompareInterfaces: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare declarations in Swift module interfaces.",
        discussion: "Repeat --reference and --candidate to combine interfaces. Imports are not followed. Coverage measures declaration signatures, not implementation behavior."
    )

    @Option(help: "Reference .swiftinterface file. Repeat to combine files.")
    var reference: [String] = []

    @Option(help: "Candidate .swiftinterface file. Repeat to combine files.")
    var candidate: [String] = []

    @Option(help: "Map a module name: Source=Target. Repeat for more mappings.")
    var moduleAlias: [String] = []

    @Option(help: "Ignore a namespace container in owners and type paths on both sides. Repeat for more names.")
    var ignoreNamespace: [String] = []

    @Flag(help: "Disable the built-in OpenSwiftUI, OpenCombine, and OpenObservation module aliases.")
    var noDefaultAliases = false

    @Flag(help: "Exclude declarations whose name or enclosing type starts with '_'.")
    var excludeUnderscored = false

    @Flag(help: "Include declarations with @_spi attributes.")
    var includeSPI = false

    @Flag(help: "Allow inputs for different platforms or target environments.")
    var allowTargetMismatch = false

    @Option(help: "Output format: text or json.")
    var format: OutputFormat = .text

    @Option(help: "Write the report to a file. The default is standard output.")
    var output: String?

    @Flag(help: "List missing declarations in the text report. JSON always includes them.")
    var showMissing = false

    @Flag(help: "List missing declarations that have an extra declaration with the same kind, owner, and name. JSON always includes them.")
    var showNearMisses = false

    mutating func validate() throws {
        guard !reference.isEmpty, !candidate.isEmpty else {
            throw ValidationError("Provide at least one --reference and one --candidate file.")
        }
        for path in reference + candidate where !path.hasSuffix(".swiftinterface") {
            throw ValidationError("Expected a .swiftinterface file: \(path)")
        }
        if let output {
            let destination = URL(fileURLWithPath: output).resolvingSymlinksInPath().standardizedFileURL
            guard !(reference + candidate).contains(where: {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == destination
            }) else {
                throw ValidationError("The output path must not replace an input file.")
            }
        }
    }

    func run() throws {
        let references = try reference.map { try InterfaceInput.read(path: $0) }
        let candidates = try candidate.map { try InterfaceInput.read(path: $0) }
        let inputs = references + candidates
        let targets = inputs.compactMap { $0.target.flatMap(TargetPlatform.init(triple:)) }
        var warnings: [String] = []
        if Set(targets.map(\.comparisonKey)).count > 1 {
            let message = "Input target platforms or environments differ: \(Set(targets.map(\.comparisonKey)).sorted().joined(separator: ", "))."
            guard allowTargetMismatch else {
                throw ValidationError(message + " Use matching inputs, or pass --allow-target-mismatch for an approximate comparison.")
            }
            warnings.append(message + " Coverage is approximate.")
        }
        if targets.count != inputs.count {
            warnings.append("Some target headers are missing or unknown. Target compatibility could not be verified for all inputs.")
        }
        if Set(targets.map(\.architectureFamily)).count > 1 {
            warnings.append("Input architectures differ. Declarations can depend on the architecture.")
        }
        var options = ScanOptions(
            ignoredNamespaces: ignoreNamespace,
            excludeUnderscored: excludeUnderscored, includeSPI: includeSPI,
            platform: references.first?.target.flatMap(TargetPlatform.init(triple:))?.platform
        )
        if noDefaultAliases { options.moduleAliases = [:] }
        for alias in moduleAlias {
            let parts = alias.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy({ value in
                !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }) else {
                throw ValidationError("Invalid module alias '\(alias)'. Use Source=Target.")
            }
            options.moduleAliases[parts[0]] = parts[1]
        }
        let scanner = InterfaceScanner(options: options)
        let report = try scanner.compare(reference: references, candidate: candidates)
        if report.summary.reference == 0 {
            warnings.append("The reference contains no declarations in the selected scope. Coverage is undefined.")
        }
        let content: String
        switch format {
        case .text:
            content = textReport(report, warnings: warnings, ignoredNamespaces: options.ignoredNamespaces)
        case .json:
            let document = ReportDocument(
                options: options, reference: references.map(InputDescription.init),
                candidate: candidates.map(InputDescription.init), warnings: warnings, coverage: report,
                nearMisses: report.nearMisses
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            content = String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
        }
        if let output {
            try content.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            print(content, terminator: "")
        }
    }

    private func textReport(_ report: CoverageReport, warnings: [String], ignoredNamespaces: [String]) -> String {
        func percent(_ count: CoverageCount) -> String {
            count.percent.map { String(format: "%.2f%%", $0) } ?? "n/a"
        }
        var lines = [
            "Interface declaration coverage: \(report.summary.matched)/\(report.summary.reference) (\(percent(report.summary)))",
            "Missing: \(report.summary.missing) | Extra: \(report.summary.extra) | Near misses: \(report.nearMisses.reduce(0) { $0 + $1.missing.count })",
            "Scope: supplied files; all conditional branches; declaration signatures.",
        ]
        if !ignoredNamespaces.isEmpty {
            lines.append("Ignored namespaces: \(ignoredNamespaces.joined(separator: ", ")).")
        }
        lines += ["", "Kind                 Reference  Matched  Missing  Extra  Coverage"]
        for row in report.byKind {
            let name = row.kind.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
            lines.append(name + String(format: " %9d %8d %8d %6d  %@", row.count.reference, row.count.matched, row.count.missing, row.count.extra, percent(row.count)))
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if showMissing {
            lines.append("\nMissing declarations:")
            for entry in report.missing {
                let location = entry.locations.first.map { " [\($0.path):\($0.line)]" } ?? ""
                lines.append("\(entry.owner): \(entry.signature)\(location)")
            }
        }
        if showNearMisses {
            lines.append("\nNear misses:")
            for group in report.nearMisses {
                lines.append("\(group.owner): \(group.kind.rawValue) \(group.name)")
                lines += group.missing.map { "  - \($0.signature)" }
                lines += group.extra.map { "  + \($0.signature)" }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum OutputFormat: String, ExpressibleByArgument {
    case text, json
}

private struct InputDescription: Encodable {
    let path: String
    let module: String
    let target: String?
    let sha256: String
    let compiler: String?

    init(_ input: InterfaceInput) {
        path = input.path
        module = input.module
        target = input.target
        sha256 = SHA256.hash(data: Data(input.source.utf8)).map { String(format: "%02x", $0) }.joined()
        compiler = input.source.split(separator: "\n").first { $0.hasPrefix("// swift-compiler-version:") }
            .map { String($0.dropFirst("// swift-compiler-version: ".count)) }
    }
}

private struct ReportDocument: Encodable {
    let options: ScanOptions
    let reference: [InputDescription]
    let candidate: [InputDescription]
    let warnings: [String]
    let coverage: CoverageReport
    let nearMisses: [NearMiss]
}
