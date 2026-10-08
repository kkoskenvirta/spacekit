import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Analysis results kept current after cleanups")
struct AnalysisResultTests {
    func setUp() throws -> (TempTree, [Rule], ScanTree) {
        let tree = try TempTree()
        try tree.file("cache/a/blob", bytes: 300_000)
        try tree.file("cache/b/blob", bytes: 100_000)
        try tree.file("models/m1/weights", bytes: 200_000)
        let cache = Rule(id: "cache", name: "Cache", paths: [tree.path("cache")], granularity: .children, action: ActionSpec(remove: true))
        let models = Rule(
            id: "models", name: "Models", paths: [tree.path("models")], ai: AISpec(tool: "Tool", layout: "children"))
        return (tree, [cache, models], try scan(tree.root))
    }

    func result(_ rules: [Rule], _ scanned: ScanTree) -> AnalysisResult {
        AnalysisResult(Analysis(findings: RuleEngine(rules: rules).evaluate(scanned), tree: scanned), rules: rules, activeModelWindow: .days(90))
    }

    @Test("Removals shrink findings, the index and (for AI rules) the AI report; a shared tree is left to the caller")
    func applyRemovals() throws {
        let (tree, rules, scanned) = try setUp()
        var current = result(rules, scanned)
        #expect(current.ruleIndex.rule(for: tree.path("cache/a"))?.id == "cache")
        #expect(current.aiReport.total > 0)

        let gone = Removal(path: tree.path("cache/a"), kind: .directory, bytes: tree.allocated("cache/a/blob"))
        #expect(current.apply([gone], exploreTree: scanned) == ["cache"])
        #expect(current.analysis.finding(ruleID: "cache")?.items.map(\.path) == [tree.path("cache/b")])
        // The explore tree is the analysis tree here, and the caller hadn't applied the removal to it.
        #expect(scanned.node(at: tree.path("cache/a")) != nil)

        let model = Removal(path: tree.path("models/m1"), kind: .directory, bytes: tree.allocated("models/m1/weights"))
        #expect(Removal.apply([model], to: scanned))
        #expect(current.apply([model], exploreTree: scanned) == ["models"])
        #expect(current.aiReport.total == 0)
    }

    @Test("A separate analysis tree is shrunk along with the findings")
    func separateTree() throws {
        let (tree, rules, scanned) = try setUp()
        var current = result(rules, scanned)
        let explore = try scan(tree.path("cache"))
        let gone = Removal(path: tree.path("cache/a"), kind: .directory, bytes: tree.allocated("cache/a/blob"))
        current.apply([gone], exploreTree: explore)
        #expect(current.analysis.tree.node(at: tree.path("cache/a")) == nil)
    }

    @Test("A targeted re-evaluation replaces only its rules' findings and models")
    func merge() throws {
        let (tree, rules, scanned) = try setUp()
        var current = result(rules, scanned)
        try FileManager.default.removeItem(atPath: tree.path("models/m1"))
        let rescanned = try scan(tree.root)
        current.merge(result(rules, rescanned), for: ["models"])
        #expect(current.analysis.finding(ruleID: "models") == nil)
        #expect(current.aiReport.total == 0)
        #expect(current.analysis.finding(ruleID: "cache")?.items.count == 2)
    }

    @Test("An analysis is dated by the scan it read, which is newer than Explore's when it had to rescan")
    func scanStarted() throws {
        let (tree, rules, _) = try setUp()
        let analyzer = StorageAnalyzer(library: RuleLibrary(rules: rules))
        let beforeScan = Date()
        let explore = try scan(tree.root)
        #expect(explore.scanStarted >= beforeScan && explore.scanStarted <= Date())
        let reused = AnalysisResult(try analyzer.analyzeSync(reusing: explore), rules: rules, activeModelWindow: .days(90))
        #expect(reused.analysis.scanStarted == explore.scanStarted)

        let partial = try scan(tree.path("models"))
        let beforeAnalysis = Date()
        let rescanned = AnalysisResult(try analyzer.analyzeSync(reusing: partial), rules: rules, activeModelWindow: .days(90))
        #expect(rescanned.analysis.scanStarted >= beforeAnalysis)
    }

    @Test("Only rules whose command removed something are re-evaluated")
    func rulesToReevaluate() {
        var report = CleanupReport(dryRun: false)
        report.commands = [
            (PlannedCommand(ruleID: "ran", arguments: ["x"], estimatedBytes: 1), .removed(bytes: 1, trashedTo: nil), ""),
            (PlannedCommand(ruleID: "skipped", arguments: ["y"], estimatedBytes: 1), .skipped(reason: "no", kind: .refused), ""),
        ]
        #expect(report.rulesToReevaluate == ["ran"])
    }

    @Test("A stopped analysis isn't recorded in History")
    func cancelledSnapshot() throws {
        let tree = try TempTree()
        try tree.file("data/a", bytes: 10_000)
        let progress = ScanProgress()
        progress.cancel()
        let stopped = try Scanner(options: ScanOptions()).scan(tree.path("data"), progress: progress)
        try #require(stopped.stats.cancelled)
        let history = HistoryStore(file: tree.path("history.jsonl"))
        try history.recordSnapshot(analysis: Analysis(findings: [], tree: stopped))
        #expect(history.records().isEmpty)
    }
}
