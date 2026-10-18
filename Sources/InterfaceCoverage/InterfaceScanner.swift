import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

public struct InterfaceScanner {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scans one side. Its member typealiases are expanded.
    public func scan(_ inputs: [InterfaceInput]) throws -> Inventory {
        let collector = try index(inputs)
        return try emit(collector, typealiases: nil)
    }

    /// Scans both sides. A member typealias is expanded only when both sides
    /// declare it, so a typealias that stands in for a type on the other side
    /// does not change the spelling of declarations that use it.
    public func compare(reference: [InterfaceInput], candidate: [InterfaceInput]) throws -> CoverageReport {
        let references = try index(reference)
        let candidates = try index(candidate)
        let shared = Set(references.normalization.typealiases.keys).intersection(candidates.normalization.typealiases.keys)
        return CoverageReport.compare(
            reference: try emit(references, typealiases: shared),
            candidate: try emit(candidates, typealiases: shared)
        )
    }

    private func index(_ inputs: [InterfaceInput]) throws -> DeclarationCollector {
        try Normalization(options: options).validate()
        let parsed = try inputs.map { input in
            let tree = Parser.parse(source: input.source)
            if tree.hasError {
                let converter = SourceLocationConverter(fileName: input.path, tree: tree)
                let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
                    .filter { $0.diagMessage.severity == .error }
                let messages = diagnostics.prefix(5).map { diagnostic in
                    let location = converter.location(for: diagnostic.position)
                    return "\(input.path):\(location.line):\(location.column): \(diagnostic.message)"
                }
                throw CoverageError(messages.joined(separator: "\n"))
            }
            return (input, tree)
        }
        let collector = DeclarationCollector(options: options, parsed: parsed)
        // Index nominal types before resolving extensions in other input files.
        for pass in 0..<2 {
            try collector.run(indexExtensions: pass > 0)
        }
        return collector
    }

    private func emit(_ collector: DeclarationCollector, typealiases: Set<String>?) throws -> Inventory {
        collector.normalization.expandedTypealiases = typealiases
        collector.indexOnly = false
        try collector.run(indexExtensions: true)
        let entries = collector.entries.values.map { entry in
            var entry = entry
            entry.locations.sort { ($0.path, $0.line) < ($1.path, $1.line) }
            return entry
        }.sorted { $0.id < $1.id }
        return Inventory(entries: entries)
    }
}
