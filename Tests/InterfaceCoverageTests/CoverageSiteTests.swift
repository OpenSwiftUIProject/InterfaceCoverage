import Foundation
import Testing
@testable import InterfaceCoverage

struct CoverageSiteTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ root: URL, empty: Bool = false) throws -> [String: Any] {
        let count = empty ? 0 : 1
        let entry: [String: Any] = [
            "kind": "struct", "owner": "Example", "name": "Value",
            "signature": "struct Value",
            "locations": [["path": "/private/build/SDK.swiftinterface", "line": 4]],
        ]
        let counts: [String: Any] = ["reference": count, "matched": 0, "missing": count, "extra": 0]
        let document: [String: Any] = [
            "options": ["moduleAliases": [:], "ignoredNamespaces": [], "excludeUnderscored": false, "includeSPI": false, "platform": "macOS"],
            "reference": [["module": "Example", "path": "/private/build/SDK.swiftinterface", "target": "arm64-apple-macos15.0"]],
            "candidate": [["module": "OpenExample", "path": "/private/build/Candidate.swiftinterface", "target": "arm64-apple-macos15.0"]],
            "warnings": [],
            "coverage": ["schemaVersion": 1, "summary": counts, "byKind": empty ? [] : [["kind": "struct", "count": counts]],
                         "matched": [], "missing": empty ? [] : [entry], "extra": []],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("report.json"))
        return ["project": "Example", "version": "1.0", "baseline": "SDK 1", "target": "macOS",
                "scope": "Example", "profile": "Default", "report": "report.json",
                "metadata": ["candidateCommit": "abc123"], "notes": ["A local snapshot."]]
    }

    private func generate(_ root: URL, rows: [[String: Any]]) throws -> URL {
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "reports": rows]).write(to: manifest)
        let output = root.appendingPathComponent("site")
        try CoverageSite.generate(manifest: manifest, output: output)
        return output
    }

    @Test func generatesPortableReportsAndEscapesEmbeddedData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var row = try fixture(root)
        row["version"] = "</script><img src=x onerror=alert(1)>"
        let output = try generate(root, rows: [row])
        let html = try String(contentsOf: output.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(!html.contains("</script><img"))
        #expect(html.contains("\\u003C/script>"))
        let files = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("reports"), includingPropertiesForKeys: nil)
        let report = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!report.contains("/private/build"))
        #expect(report.contains("reference/0/Example.swiftinterface"))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("embed.html").path))
        let tables = try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("tables").path)
        #expect(tables.contains { $0.hasSuffix(".md") })
        #expect(tables.contains { $0.hasSuffix(".svg") })
    }

    @Test func rejectsDuplicateCellsBeforeWriting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        #expect(throws: CoverageError.self) { try generate(root, rows: [row, row]) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("site").path))
    }

    @Test func rejectsDifferentRulesInOneProfile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        var other = row
        other["baseline"] = "SDK 2"
        other["report"] = "other.json"
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("report.json"))) as? [String: Any])
        var options = try #require(document["options"] as? [String: Any])
        options["ignoredNamespaces"] = ["Wrapper"]
        document["options"] = options
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("other.json"))
        #expect(throws: CoverageError.self) { try generate(root, rows: [row, other]) }
    }

    @Test func emptyReferenceHasNoPercentage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try generate(root, rows: [fixture(root, empty: true)])
        let tables = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("tables"), includingPropertiesForKeys: nil)
        let markdown = try String(contentsOf: #require(tables.first { $0.pathExtension == "md" }), encoding: .utf8)
        #expect(markdown.contains("n/a"))
        #expect(!markdown.contains("0.00%"))
    }

    @Test func readsReportsBeforeNamespaceOptionsWereAdded() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        let path = root.appendingPathComponent("report.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var options = try #require(document["options"] as? [String: Any])
        options.removeValue(forKey: "ignoredNamespaces")
        document["options"] = options
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        _ = try generate(root, rows: [row])
    }

    @Test func preservesReferenceLocationsWhenBothSidesUseTheSameFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        let path = root.appendingPathComponent("report.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        document["candidate"] = document["reference"]
        var originalCoverage = try #require(document["coverage"] as? [String: Any])
        let counts = ["reference": 1, "matched": 1, "missing": 0, "extra": 0]
        originalCoverage["summary"] = counts
        originalCoverage["byKind"] = [["kind": "struct", "count": counts]]
        originalCoverage["matched"] = originalCoverage["missing"]
        originalCoverage["missing"] = []
        document["coverage"] = originalCoverage
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        let output = try generate(root, rows: [row])
        let files = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("reports"), includingPropertiesForKeys: nil)
        let publishedFile = try #require(files.first)
        let published = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: publishedFile)) as? [String: Any])
        let coverage = try #require(published["coverage"] as? [String: Any])
        let matched = try #require(coverage["matched"] as? [[String: Any]])
        let locations = try #require(matched.first?["locations"] as? [[String: Any]])
        #expect(locations.first?["path"] as? String == "reference/0/Example.swiftinterface")
    }

    @Test func catalogCountsNearMisses() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        let path = root.appendingPathComponent("report.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var coverage = try #require(document["coverage"] as? [String: Any])
        var extra = try #require((coverage["missing"] as? [[String: Any]])?.first)
        extra["signature"] = "struct Value<T0>"
        extra["locations"] = [["path": "/private/build/Candidate.swiftinterface", "line": 2]]
        let counts = ["reference": 1, "matched": 0, "missing": 1, "extra": 1]
        coverage["summary"] = counts
        coverage["byKind"] = [["kind": "struct", "count": counts]]
        coverage["extra"] = [extra]
        document["coverage"] = coverage
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        let output = try generate(root, rows: [row])
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("catalog.json"))) as? [String: Any])
        let reports = try #require(catalog["reports"] as? [[String: Any]])
        #expect(reports.first?["nearMisses"] as? Int == 1)
    }

    @Test func rejectsInconsistentCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        let path = root.appendingPathComponent("report.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var coverage = try #require(document["coverage"] as? [String: Any])
        coverage["missing"] = []
        document["coverage"] = coverage
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        #expect(throws: CoverageError.self) { try generate(root, rows: [row]) }
    }

    @Test func preservesUnrelatedOutputDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try fixture(root)
        let output = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("index.html")
        try "User content".write(to: existing, atomically: true, encoding: .utf8)
        #expect(throws: CoverageError.self) { try generate(root, rows: [row]) }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "User content")
    }
}
