import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

public struct InterfaceScanner {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public func scan(_ inputs: [InterfaceInput]) throws -> Inventory {
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
        guard let first = parsed.first else { return Inventory(entries: []) }
        let collector = DeclarationCollector(options: options, input: first.0, tree: first.1)
        // Index nominal types before resolving extensions in other input files.
        for pass in 0..<3 {
            collector.indexOnly = pass < 2
            collector.indexExtensions = pass > 0
            for (input, tree) in parsed {
                collector.input = input
                collector.converter = SourceLocationConverter(fileName: input.path, tree: tree)
                let context = DeclarationContext(owner: collector.normalization.module(input.module))
                try collector.collect(tree.statements.compactMap { $0.item.as(DeclSyntax.self) }, context: context)
            }
        }
        let entries = collector.entries.values.map { entry in
            var entry = entry
            entry.locations.sort { ($0.path, $0.line) < ($1.path, $1.line) }
            return entry
        }.sorted { $0.id < $1.id }
        return Inventory(entries: entries)
    }
}
