import Foundation
import Testing

@testable import SpaceKitCore

/// A deletion that can't remove everything still removes what it can, and the report, the journal and the
/// budget count exactly what left the disk.
@Suite("Cleanup execution: items removed only in part")
struct PartialRemovalTests {
    /// `home/cache/<name>` with files `a`, `b`, `c`; `b` is made immutable when `locked`.
    static func item(_ tree: TempTree, _ name: String, locked: Bool) throws -> CleanupItem {
        for file in ["a", "b", "c"] { try tree.file("home/cache/\(name)/\(file)", bytes: 4_000) }
        if locked { #expect(chflags(tree.path("home/cache/\(name)/b"), UInt32(UF_IMMUTABLE)) == 0) }
        let size = ["a", "b", "c"].reduce(0) { $0 + tree.allocated("home/cache/\(name)/\($1)") }
        return CleanupItem(path: tree.path("home/cache/\(name)"), size: size, ruleID: "cache")
    }

    static func unlock(_ tree: TempTree, _ name: String) {
        chflags(tree.path("home/cache/\(name)/b"), 0)
    }

    @Test("A partly deleted item fails with the entry it couldn't remove, and what did go is reported and journaled")
    func reportsWhatWentAway() throws {
        let tree = try TempTree()
        let item = try PartialRemovalTests.item(tree, "item", locked: true)
        defer { PartialRemovalTests.unlock(tree, "item") }
        let gone = tree.allocated("home/cache/item/a") + tree.allocated("home/cache/item/c")
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])

        let report = manualRun(CleanupPlan(items: [item], useTrash: false), with: sandboxExecutor(tree, rules: [rule]))

        let outcome = try #require(report.items.first?.outcome)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(reason.contains(tree.path("home/cache/item/b")))
        #expect(reason.contains("\(ByteCount.format(gone)) of it was deleted"))
        #expect(report.partiallyFreed == [item.path: gone])
        #expect(report.freedBytes == gone)
        #expect(report.hasProblems)
        let entries = journalEntries(tree)
        #expect(entries.map(\.bytes) == [gone])
        #expect(entries.first?.method == .delete)
        #expect(!onDisk(tree.path("home/cache/item/a")))
        #expect(onDisk(tree.path("home/cache/item/b")))
    }

    @Test("What a partly deleted item freed counts against an automatic run's budget")
    func chargesTheBudget() throws {
        let tree = try TempTree()
        let first = try PartialRemovalTests.item(tree, "first", locked: true)
        defer { PartialRemovalTests.unlock(tree, "first") }
        let second = try PartialRemovalTests.item(tree, "second", locked: false)
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        // Room for the first item and for what's left after its partial removal, but not for the second one too.
        let budget = first.size + second.size / 2
        let gone = first.size - tree.allocated("home/cache/first/b")
        #expect(budget - gone < second.size)

        let plan = AutomaticPlan(CleanupPlan(items: [first, second], useTrash: false), automation: AutomationContext(jobID: "j"))
        let report = sandboxExecutor(tree, rules: [rule], budget: ByteCount(budget)).execute(plan, dryRun: false)

        #expect(report.items.first?.outcome.isFailed == true)
        #expect(report.skipped.first?.reason.hasPrefix("Over this run's budget") == true)
        #expect(onDisk(tree.path("home/cache/second/a")))
    }

    @Test("After a partial deletion the tree matches a rescan and the finding shrinks by what went")
    func treeMatchesDisk() throws {
        let tree = try TempTree()
        let item = try PartialRemovalTests.item(tree, "item", locked: true)
        defer { PartialRemovalTests.unlock(tree, "item") }
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let scanned = try scan(tree.path("home"))
        var analysis = Analysis(findings: RuleEngine(rules: [rule]).evaluate(scanned), tree: scanned)
        let before = try #require(analysis.finding(ruleID: "cache")?.items.first { $0.path == item.path }?.size)

        let report = manualRun(CleanupPlan(items: [item], useTrash: false), with: sandboxExecutor(tree, rules: [rule]))
        let freed = try #require(report.partiallyFreed[item.path])
        let removals = Removal.from(report)
        #expect(removals == [Removal(path: item.path, kind: .directory, bytes: freed, partial: true)])

        #expect(Removal.apply(removals, to: scanned))
        let fresh = try scan(tree.path("home"))
        #expect(scanned.inconsistencies().isEmpty)
        #expect(scanned.root.size == fresh.root.size)
        #expect(scanned.node(at: item.path)?.fileCount == 1)
        analysis.apply(removals)
        #expect(analysis.finding(ruleID: "cache")?.items.first { $0.path == item.path }?.size == before - freed)
    }
}
