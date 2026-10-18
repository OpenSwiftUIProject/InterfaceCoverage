import CryptoKit
import Foundation

/// Builds a static site from reports. It does not fetch or build candidate projects.
public enum CoverageSite {
    public static func generate(manifest: URL, output: URL) throws {
        let decoder = JSONDecoder()
        let specification = try decoder.decode(SiteManifest.self, from: Data(contentsOf: manifest))
        guard specification.schemaVersion == 1, !specification.reports.isEmpty else {
            throw CoverageError("Expected a version 1 manifest with at least one report.")
        }
        let output = output.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        let marker = output.appendingPathComponent(".interface-coverage-site")
        if manager.fileExists(atPath: output.path) {
            let contents = try manager.contentsOfDirectory(atPath: output.path)
            guard contents.isEmpty || (try? String(contentsOf: marker, encoding: .utf8)) == "1\n" else {
                throw CoverageError("The output directory contains files not owned by InterfaceCoverage.")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var records: [SiteRecord] = []
        var files: [String: Data] = [:]
        var cells = Set<[String]>()
        var rules: [String: Data] = [:]
        for item in specification.reports {
            let labels = [item.project, item.target, item.scope, item.profile, item.version, item.baseline]
            guard labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CoverageError("Project, target, scope, profile, version, and baseline must not be empty.")
            }
            guard cells.insert(labels).inserted else {
                throw CoverageError("Duplicate matrix cell: \(labels.joined(separator: " / ")).")
            }
            let source = URL(fileURLWithPath: item.report, relativeTo: manifest.deletingLastPathComponent())
                .resolvingSymlinksInPath().standardizedFileURL
            for input in [manifest.resolvingSymlinksInPath().standardizedFileURL, source] {
                guard input.path != output.path, !input.path.hasPrefix(output.path + "/") else {
                    throw CoverageError("The output directory must not contain the manifest or input reports.")
                }
            }
            var document = try decoder.decode(SiteDocument.self, from: Data(contentsOf: source))
            try document.validate()
            let group = digest(try encoder.encode(Array(labels.prefix(4))))
            let options = try encoder.encode(document.options)
            if let previous = rules[group], previous != options {
                throw CoverageError("The '\(item.profile)' profile contains different matching rules. Use separate profile names.")
            }
            rules[group] = options
            document.removeLocalPaths()
            let detail = try encoder.encode(document)
            // Use the published content so moving the manifest does not change report URLs.
            let id = digest(try encoder.encode(item.identity) + detail)
            files["reports/\(id).json"] = detail
            records.append(SiteRecord(
                id: id, group: group, project: item.project, version: item.version,
                baseline: item.baseline, target: item.target, scope: item.scope, profile: item.profile,
                notes: item.notes ?? [], metadata: item.metadata ?? [:], summary: document.coverage.summary,
                nearMisses: document.coverage.nearMisses.reduce(0) { $0 + $1.missing.count },
                warnings: document.warnings, report: "reports/\(id).json"
            ))
        }
        let catalog = SiteCatalog(schemaVersion: 1, title: specification.title ?? "InterfaceCoverage", reports: records)
        let catalogData = try encoder.encode(catalog)
        files["catalog.json"] = catalogData
        let embedded = String(decoding: catalogData, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let template = try asset("index.html")
        let page = template.replacingOccurrences(of: "__TITLE__", with: escape(catalog.title))
        for (path, mode) in [("index.html", "false"), ("embed.html", "true")] {
            files[path] = Data(page.replacingOccurrences(of: "__EMBED__", with: mode)
                .replacingOccurrences(of: "__CATALOG__", with: embedded).utf8)
        }
        files["assets/site.css"] = Data(try asset("site.css").utf8)
        files["assets/site.js"] = Data(try asset("site.js").utf8)
        for group in ordered(records.map(\.group)) {
            let rows = records.filter { $0.group == group }
            files["tables/\(group).md"] = Data(markdown(rows).utf8)
            files["tables/\(group).svg"] = Data(svg(rows).utf8)
        }
        // Validate every input and prepare every output before writing any files.
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        for (path, data) in files {
            let destination = output.appendingPathComponent(path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        try "1\n".write(to: marker, atomically: true, encoding: .utf8)
        // Report and table names are content hashes. The catalog no longer refers
        // to files from earlier runs, so remove them.
        for directory in ["reports", "tables"] {
            let url = output.appendingPathComponent(directory)
            for name in (try? manager.contentsOfDirectory(atPath: url.path)) ?? [] where files["\(directory)/\(name)"] == nil {
                try manager.removeItem(at: url.appendingPathComponent(name))
            }
        }
    }

    private static func asset(_ name: String) throws -> String {
        guard let root = Bundle.module.url(forResource: "SiteAssets", withExtension: nil) else {
            throw CoverageError("The site resources are missing from the tool bundle.")
        }
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func ordered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func percentage(_ count: CoverageCount) -> String {
        count.reference == 0 ? "n/a" : String(format: "%.2f%%", Double(count.matched) / Double(count.reference) * 100)
    }

    private static func markdown(_ rows: [SiteRecord]) -> String {
        func cell(_ text: String) -> String {
            escape(text).replacingOccurrences(of: "|", with: "&#124;")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        let first = rows[0]
        let baselines = ordered(rows.map(\.baseline))
        var result = "# \(cell(first.project)) interface coverage\n\n\(cell(first.target)) · \(cell(first.scope)) · \(cell(first.profile))\n\n"
        result += "| Candidate | " + baselines.map(cell).joined(separator: " | ") + " |\n"
        result += "| --- | " + baselines.map { _ in "---:" }.joined(separator: " | ") + " |\n"
        for version in ordered(rows.map(\.version)) {
            let values = baselines.map { baseline in
                guard let row = rows.first(where: { $0.version == version && $0.baseline == baseline }) else { return "—" }
                return "\(percentage(row.summary)) (\(row.summary.matched)/\(row.summary.reference))"
            }
            result += "| \(cell(version)) | " + values.joined(separator: " | ") + " |\n"
        }
        result += "\nCoverage measures declaration signatures. Matching declarations can include stubs.\n"
        let notes = ordered(rows.flatMap { $0.notes + $0.warnings })
        for note in notes { result += "\n- \(cell(note))\n" }
        return result
    }

    private static func svg(_ rows: [SiteRecord]) -> String {
        let first = rows[0]
        let baselines = ordered(rows.map(\.baseline))
        let versions = ordered(rows.map(\.version))
        let labelWidth = max(240, versions.map { $0.count * 9 + 32 }.max() ?? 240)
        let columnWidth = max(176, baselines.map { $0.count * 9 + 32 }.max() ?? 176)
        let title = "\(first.project) · \(first.target) · \(first.scope) · \(first.profile)"
        let width = max(labelWidth + baselines.count * columnWidth, title.count * 9 + 32)
        let height = 140 + versions.count * 56 + (rows.contains { !$0.notes.isEmpty || !$0.warnings.isEmpty } ? 24 : 0)
        var result = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" role="img" aria-labelledby="title desc">
        <title id="title">\(escape(title))</title><desc id="desc">Public interface declaration coverage by candidate and SDK baseline.</desc>
        <rect width="100%" height="100%" fill="white"/>
        <g font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="14" fill="#182329">
        <text x="16" y="30" font-size="17" font-weight="600">\(escape(title))</text>
        <path d="M0 52H\(width)" stroke="#dde3e7"/><text x="16" y="80" font-weight="600">Candidate</text>
        """
        for (index, baseline) in baselines.enumerated() {
            result += "<text x=\"\(labelWidth + index * columnWidth + 16)\" y=\"80\" font-weight=\"600\">\(escape(baseline))</text>"
        }
        for (index, version) in versions.enumerated() {
            let y = 108 + index * 56
            result += "<path d=\"M0 \(y - 12)H\(width)\" stroke=\"#dde3e7\"/><text x=\"16\" y=\"\(y + 10)\">\(escape(version))</text>"
            for (column, baseline) in baselines.enumerated() {
                let x = labelWidth + column * columnWidth + 16
                if let row = rows.first(where: { $0.version == version && $0.baseline == baseline }) {
                    result += "<text x=\"\(x)\" y=\"\(y + 6)\" fill=\"#087d4c\" font-weight=\"600\">\(percentage(row.summary))</text>"
                    result += "<text x=\"\(x)\" y=\"\(y + 24)\" fill=\"#647280\" font-size=\"12\">\(row.summary.matched) / \(row.summary.reference)</text>"
                } else {
                    result += "<text x=\"\(x)\" y=\"\(y + 6)\">—</text>"
                }
            }
        }
        result += "<text x=\"16\" y=\"\(116 + versions.count * 56)\" font-size=\"12\" fill=\"#647280\">Declaration signatures only. Matching declarations can include stubs.</text>"
        if rows.contains(where: { !$0.notes.isEmpty || !$0.warnings.isEmpty }) {
            result += "<text x=\"16\" y=\"\(140 + versions.count * 56)\" font-size=\"12\" fill=\"#647280\">Input notes apply. See the linked report for provenance and warnings.</text>"
        }
        return result + "</g></svg>\n"
    }
}

private struct SiteManifest: Decodable {
    let schemaVersion: Int
    let title: String?
    let reports: [SiteReportInput]
}

private struct SiteReportInput: Decodable {
    let project: String
    let version: String
    let baseline: String
    let target: String
    let scope: String
    let profile: String
    let report: String
    let notes: [String]?
    let metadata: [String: String]?

    var identity: [String: String] {
        ["project": project, "version": version, "baseline": baseline, "target": target,
         "scope": scope, "profile": profile, "notes": (notes ?? []).joined(separator: "\n")]
            .merging((metadata ?? [:]).map { ("metadata." + $0.key, $0.value) }, uniquingKeysWith: { _, new in new })
    }
}

private struct SiteCatalog: Encodable {
    let schemaVersion: Int
    let title: String
    let reports: [SiteRecord]
}

private struct SiteRecord: Encodable {
    let id: String
    let group: String
    let project: String
    let version: String
    let baseline: String
    let target: String
    let scope: String
    let profile: String
    let notes: [String]
    let metadata: [String: String]
    let summary: CoverageCount
    let nearMisses: Int
    let warnings: [String]
    let report: String
}

private struct SiteInterface: Codable {
    var path: String
    let module: String
    let target: String?
    let sha256: String?
    let compiler: String?
}

private struct SiteDocument: Codable {
    let options: ScanOptions
    var reference: [SiteInterface]
    var candidate: [SiteInterface]
    var warnings: [String]
    var coverage: CoverageReport

    func validate() throws {
        let summary = coverage.summary
        let groups = [coverage.matched, coverage.missing, coverage.extra]
        guard coverage.schemaVersion == 1,
              summary.reference == summary.matched + summary.missing,
              summary.matched == coverage.matched.count,
              summary.missing == coverage.missing.count,
              summary.extra == coverage.extra.count,
              Set(groups.flatMap { $0.map(\.id) }).count == groups.flatMap({ $0 }).count else {
            throw CoverageError("The report has an unsupported schema or inconsistent declaration counts.")
        }
        guard !reference.isEmpty, !candidate.isEmpty else {
            throw CoverageError("The report must describe its reference and candidate inputs.")
        }
        let kinds = Set(groups.flatMap { $0.map(\.kind) })
        guard Set(coverage.byKind.map(\.kind)) == kinds,
              coverage.byKind.count == kinds.count else {
            throw CoverageError("The report has inconsistent declaration kinds.")
        }
        for row in coverage.byKind {
            let matched = coverage.matched.filter { $0.kind == row.kind }.count
            let missing = coverage.missing.filter { $0.kind == row.kind }.count
            let extra = coverage.extra.filter { $0.kind == row.kind }.count
            guard row.count.reference == matched + missing, row.count.matched == matched,
                  row.count.missing == missing, row.count.extra == extra else {
                throw CoverageError("The report has inconsistent counts for '\(row.kind.rawValue)'.")
            }
        }
    }

    mutating func removeLocalPaths() {
        func portable(_ inputs: [SiteInterface], side: String) -> ([SiteInterface], [String: String]) {
            var paths: [String: String] = [:]
            let result = inputs.enumerated().map { index, input in
                var input = input
                let path = "\(side)/\(index)/\(input.module).swiftinterface"
                paths[input.path] = path
                input.path = path
                return input
            }
            return (result, paths)
        }
        let (referenceInputs, referencePaths) = portable(reference, side: "reference")
        let (candidateInputs, candidatePaths) = portable(candidate, side: "candidate")
        reference = referenceInputs
        candidate = candidateInputs
        func entries(_ values: [APIEntry], paths: [String: String]) -> [APIEntry] {
            values.map { entry in
                var entry = entry
                entry.locations = entry.locations.map {
                    SourceLocation(path: paths[$0.path] ?? URL(fileURLWithPath: $0.path).lastPathComponent, line: $0.line)
                }
                return entry
            }
        }
        coverage = CoverageReport(
            schemaVersion: coverage.schemaVersion,
            summary: CoverageCount(reference: coverage.summary.reference, matched: coverage.summary.matched,
                                   missing: coverage.summary.missing, extra: coverage.summary.extra),
            byKind: coverage.byKind,
            matched: entries(coverage.matched, paths: referencePaths),
            missing: entries(coverage.missing, paths: referencePaths),
            extra: entries(coverage.extra, paths: candidatePaths)
        )
        let paths = referencePaths.merging(candidatePaths, uniquingKeysWith: { reference, _ in reference })
        warnings = warnings.map { warning in
            paths.reduce(warning) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
    }
}
