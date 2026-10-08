import Foundation
import Testing

@testable import SpaceKitCore

/// Evaluating some rules (`spacekit clean <rule>`, a job's rules) gives each of them exactly what a full analysis
/// would: never something another enabled rule claims.
@Suite("Evaluating a subset of rules")
struct SubsetEvaluationTests {
    static func rule(_ tree: TempTree, _ id: String, _ relative: String, level: SafetyLevel, granularity: Granularity = .children)
        -> Rule
    {
        Rule(
            id: id, name: id, paths: [tree.path(relative)], granularity: granularity,
            safety: SafetySpec(level: level, trash: false), action: ActionSpec(remove: true))
    }

    /// `home/outer` holds a small file, a folder and `big.log`, which a review rule of its own claims.
    static func outerAndInner(_ tree: TempTree) throws -> (outer: Rule, inner: Rule) {
        try tree.file("home/outer/small.txt", bytes: 1_000)
        try tree.file("home/outer/sub/x", bytes: 10_000)
        try tree.file("home/outer/big.log", bytes: 250_000)
        return (rule(tree, "t.outer", "home/outer", level: .safe), rule(tree, "t.inner", "home/outer/big.log", level: .review))
    }

    func analyzer(_ tree: TempTree, rules: [Rule]) -> StorageAnalyzer {
        var options = ScanOptions()
        options.minFileSize = 0
        return StorageAnalyzer(library: RuleLibrary(rules: rules), scanOptions: options, devRoots: [tree.path("home")])
    }

    @Test("A rule evaluated on its own leaves out a file another rule claims")
    func otherRulesFiles() throws {
        let tree = try TempTree()
        let (outer, inner) = try SubsetEvaluationTests.outerAndInner(tree)
        let analysis = try analyzer(tree, rules: [outer, inner]).analyzeSync(rules: [outer])

        #expect(analysis.findings.map(\.rule.id) == ["t.outer"])
        let items = analysis.finding(ruleID: "t.outer")?.items ?? []
        #expect(!items.contains { $0.looseFileNames?.contains("big.log") == true })
        #expect((analysis.finding(ruleID: "t.outer")?.size ?? 0) < 250_000)
    }

    @Test("A whole-folder rule evaluated on its own leaves out what a pattern rule claims inside it")
    func patternRuleInside() throws {
        let tree = try TempTree()
        try tree.file("home/work/a/x", bytes: 10_000)
        try tree.file("home/work/app/node_modules/m", bytes: 100_000)
        let work = SubsetEvaluationTests.rule(tree, "t.work", "home/work", level: .safe, granularity: .whole)
        let modules = Rule(
            id: "t.modules", name: "modules", match: PatternSpec(names: ["node_modules"]),
            safety: SafetySpec(level: .review), action: ActionSpec(remove: true))

        let analysis = try analyzer(tree, rules: [work, modules]).analyzeSync(rules: [work])

        let paths = analysis.finding(ruleID: "t.work")?.items.map(\.path) ?? []
        #expect(!paths.isEmpty)
        #expect(!paths.contains { PathUtil.isAncestorOrEqual($0, of: tree.path("home/work/app/node_modules")) })
    }

    @Test("A pattern rule's claim doesn't count when an enclosing folder matched it first, as in a full analysis")
    func patternStopsAtEnclosingMatch() throws {
        let tree = try TempTree()
        try tree.file("home/app/node_modules/pkg/cache/node_modules/m", bytes: 10_000)
        let cache = SubsetEvaluationTests.rule(tree, "t.cache", "home/app/node_modules/pkg/cache", level: .safe, granularity: .whole)
        let modules = Rule(
            id: "t.modules", name: "modules", match: PatternSpec(names: ["node_modules"]),
            safety: SafetySpec(level: .review), action: ActionSpec(remove: true))
        let rules = [cache, modules]

        let full = try analyzer(tree, rules: rules).analyzeSync().finding(ruleID: "t.cache")?.items.map(\.path)
        let subset = try analyzer(tree, rules: rules).analyzeSync(rules: [cache]).finding(ruleID: "t.cache")?.items.map(\.path)
        #expect(full == [tree.path("home/app/node_modules/pkg/cache")])
        #expect(subset == full)
    }

    @Test("A job with one rule doesn't remove a file another rule claims")
    func jobLeavesOtherRulesFiles() throws {
        var fixture = try RunnerFixture()
        let (outer, inner) = try SubsetEvaluationTests.outerAndInner(fixture.tree)
        fixture.rules = [outer, inner]
        let job = Job(id: "outer", name: "Outer", rules: ["t.outer"], mode: .automatic, action: .delete)

        let result = fixture.runner.run(job)

        guard case .cleaned(let report) = result.action else {
            Issue.record("expected a cleanup, got \(result.action)")
            return
        }
        #expect(report.removedAnything)
        #expect(onDisk(fixture.tree.path("home/outer/big.log")))
        #expect(!onDisk(fixture.tree.path("home/outer/small.txt")))
    }
}
