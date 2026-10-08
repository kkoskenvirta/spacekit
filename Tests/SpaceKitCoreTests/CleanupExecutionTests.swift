import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// An executor whose home, Trash and journal all live inside `tree`, so nothing reaches the real Trash.
func sandboxExecutor(
    _ tree: TempTree, rules: [Rule] = [], budget: ByteCount = .gb(100), allowed: Set<String> = [], configError: String? = nil,
    root: Bool = false, protectedPaths: [String] = [], protectedRules: [Rule] = []
) -> CleanupExecutor {
    let home = tree.path("home")
    let guardian = SafetyGuard(
        home: home, userProtectedPaths: protectedPaths, protectedRules: protectedRules, volumes: emptyVolumes, isRunningAsRoot: root)
    var executor = CleanupExecutor(
        safety: guardian, journal: Journal(file: tree.path("state/journal.jsonl")), rules: rules, allowedCommands: allowed,
        maxBytesPerAutomaticRun: budget.bytes, configError: configError)
    executor.trash = sandboxTrash(home: home)
    return executor
}

func journalEntries(_ tree: TempTree) -> [JournalEntry] {
    Journal(file: tree.path("state/journal.jsonl")).entries()
}

func onDisk(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

/// Lets file times move past a scan's start time.
func waitForClockTick() { usleep(20_000) }

func cacheRule(_ tree: TempTree, id: String = "cache", level: SafetyLevel, paths: [String]) -> Rule {
    Rule(
        id: id, name: id, paths: paths.map { tree.path($0) }, granularity: .children,
        safety: SafetySpec(level: level, trash: level != .safe), action: ActionSpec(remove: true))
}

@Suite("Cleanup execution: automatic runs")
struct AutomaticCleanupTests {
    /// `jobs preview --json` totals what the verdicts allow, so the verdict must refuse what the run would skip.
    @Test("An automatic preview blocks Trash entries no regenerable rule covers, as the run skips them")
    func trashEntriesNeedRegenerableRule() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4_000)
        waitForClockTick()
        let automatic = CleanupContext.automatic(AutomationContext(jobID: "j"))
        for level in [SafetyLevel.review, .safe] {
            let rule = cacheRule(tree, level: level, paths: ["home/.Trash"])
            let item = CleanupItem(path: tree.path("home/.Trash/old"), size: 4_000, ruleID: rule.id, scanStarted: Date())
            let executor = sandboxExecutor(tree, rules: [rule])
            let verdict = executor.verdict(for: item, context: automatic)
            let refused = verdict.reasons.contains(CleanupExecutor.trashedNotRegenerable)
            #expect(refused == (level != .safe), "\(level): \(verdict.reasons)")
            let report = executor.execute(
                AutomaticPlan(CleanupPlan(items: [item], useTrash: false), automation: AutomationContext(jobID: "j")), dryRun: true)
            #expect((report.skipped.first?.reason == CleanupExecutor.trashedNotRegenerable) == refused)
            // A person may always delete from the Trash by hand.
            #expect(!executor.verdict(for: item, context: .manual).reasons.contains(CleanupExecutor.trashedNotRegenerable))
        }
    }

    @Test("Non-safe rule items in an automatic delete plan go to the Trash instead of being skipped")
    func reviewItemsAreTrashed() throws {
        let tree = try TempTree()
        try tree.file("home/archives/a/x", bytes: 4000)
        let rule = cacheRule(tree, level: .review, paths: ["home/archives"])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/archives/a"), size: 4000, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule])
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j", allowReview: true)), dryRun: false)
        let outcome = try #require(report.items.first?.outcome)
        #expect(outcome.isRemoved)
        #expect(outcome.trashedTo != nil)
        #expect(onDisk(tree.path("home/.Trash/a/x")))
        #expect(journalEntries(tree).first?.method == .trash)
    }

    @Test("Job folders without a rule are trashed, never deleted permanently, by automatic runs")
    func customPathsAreTrashed() throws {
        let tree = try TempTree()
        try tree.file("home/Scratch/old/x", bytes: 4000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Scratch/old"), size: 4000)], useTrash: false)
        let context = AutomationContext(jobID: "j", customPaths: [tree.path("home/Scratch")], usesTrash: false)
        let report = sandboxExecutor(tree).execute(AutomaticPlan(plan, automation: context), dryRun: false)
        #expect(report.items.first?.outcome.trashedTo != nil)
        #expect(onDisk(tree.path("home/.Trash/old/x")))
    }

    @Test("Safe rule items in an automatic delete plan are deleted")
    func safeItemsAreDeleted() throws {
        let tree = try TempTree()
        try tree.file("home/dd/a/x", bytes: 4000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/dd"])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/dd/a"), size: 4000, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule])
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.items.first?.outcome.trashedTo == nil)
        #expect(!onDisk(tree.path("home/dd/a")))
        #expect(!onDisk(tree.path("home/.Trash/a")))
    }

    @Test("Items already in the Trash: automatic runs delete them only for safe rules")
    func trashContentsInAutomaticRuns() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4000)
        try tree.file("home/.Trash/older/y", bytes: 4000)
        let review = cacheRule(tree, id: "review", level: .review, paths: ["home/.Trash"])
        let safe = cacheRule(tree, id: "safe", level: .safe, paths: ["home/.Trash"])
        let context = AutomationContext(jobID: "j", allowReview: true)

        let old = CleanupItem(path: tree.path("home/.Trash/old"), size: 4000, ruleID: "review", scanStarted: Date())
        let reviewPlan = CleanupPlan(items: [old])
        let skipped = sandboxExecutor(tree, rules: [review]).execute(AutomaticPlan(reviewPlan, automation: context), dryRun: false)
        #expect(skipped.skipped.count == 1)
        #expect(onDisk(tree.path("home/.Trash/old/x")))

        let older = CleanupItem(path: tree.path("home/.Trash/older"), size: 4000, ruleID: "safe", scanStarted: Date())
        let safePlan = CleanupPlan(items: [older])
        let deleted = sandboxExecutor(tree, rules: [safe]).execute(AutomaticPlan(safePlan, automation: context), dryRun: false)
        #expect(deleted.items.first?.outcome.isRemoved == true)
        #expect(!onDisk(tree.path("home/.Trash/older")))
        #expect(journalEntries(tree).map(\.method) == [.delete])
    }

    @Test("The budget is charged with the size measured at removal time, not the plan's")
    func budgetUsesMeasuredSize() throws {
        let tree = try TempTree()
        try tree.file("home/dd/a/x", bytes: 64_000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/dd"])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/dd/a"), size: 1, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule], budget: ByteCount(10_000))
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.skipped.count == 1)
        #expect(onDisk(tree.path("home/dd/a/x")))
    }

    @Test("A repository that appeared after the scan blocks automatic removal")
    func repositoryRecheckedAtRemoval() throws {
        let tree = try TempTree()
        try tree.file("home/dd/a/x", bytes: 4000)
        try tree.directory("home/dd/a/.git")
        try tree.file("home/dd/b/deep/er/y", bytes: 4000)
        try tree.directory("home/dd/b/deep/er/.git")
        let rule = cacheRule(tree, level: .review, paths: ["home/dd"])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/dd/a"), size: 4000, ruleID: "cache"),
                CleanupItem(path: tree.path("home/dd/b"), size: 4000, ruleID: "cache"),
            ], useTrash: true)
        let report = sandboxExecutor(tree, rules: [rule])
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j", allowReview: true)), dryRun: false)
        #expect(report.skipped.count == 2)
        #expect(onDisk(tree.path("home/dd/a/x")))
        #expect(onDisk(tree.path("home/dd/b/deep/er/y")))
    }
}

@Suite("Cleanup execution: Trash and journal")
struct TrashAndJournalTests {
    @Test("Items already in the Trash are deleted and journaled as deletions")
    func trashContentsAreDeleted() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/.Trash/old"), size: 4000, scanStarted: Date())], useTrash: true)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.items.first?.outcome.trashedTo == nil)
        #expect(!onDisk(tree.path("home/.Trash/old")))
        #expect(journalEntries(tree).map(\.method) == [.delete])
    }

    @Test("safety.trash: always trashes what a plan says to delete, and still empties the Trash")
    func alwaysTrash() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a/x", bytes: 4000)
        try tree.file("home/.Trash/old/x", bytes: 4000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/cache/a"), size: 4000, ruleID: "cache"),
                CleanupItem(path: tree.path("home/.Trash/old"), size: 4000, scanStarted: Date()),
            ], useTrash: false)
        var executor = sandboxExecutor(tree, rules: [rule])
        executor.alwaysTrash = true
        let report = manualRun(plan, with: executor)
        #expect(report.items.map(\.outcome.isRemoved) == [true, true])
        #expect(onDisk(tree.path("home/.Trash/a/x")))
        #expect(!onDisk(tree.path("home/.Trash/old")))
        #expect(journalEntries(tree).map(\.method) == [.trash, .delete])
    }

    @Test("The Trash is recognised whatever the case of the path")
    func trashCaseFolded() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/.TRASH/old"), size: 4000, scanStarted: Date())], useTrash: true)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.items.first?.outcome.trashedTo == nil)
        #expect(journalEntries(tree).map(\.method) == [.delete])
    }

    @Test("Each removal is journaled as it happens")
    func journalPerRemoval() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/build/x", bytes: 1000)
        try tree.file("home/Projects/b/build/y", bytes: 1000)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/a/build"), size: 1000),
                CleanupItem(path: tree.path("home/Projects/b/build"), size: 1000),
            ], useTrash: false)
        let journal = Journal(file: tree.path("state/journal.jsonl"))
        let seen = Mutex<[Int]>([])
        _ = manualRun(plan, with: sandboxExecutor(tree)) { completed, _, _ in
            let count = journal.entries().count
            seen.withLock { $0.append(count) }
            _ = completed
        }
        #expect(seen.withLock { $0 } == [0, 1, 2])
    }

    @Test("A failed journal write is reported, not swallowed")
    func journalFailureSurfaces() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/build/x", bytes: 1000)
        try tree.directory("state/journal.jsonl")
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a/build"), size: 1000)], useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.warnings.contains { $0.contains("journal") })
    }

    @Test("Trashed loose files each record where they went")
    func looseFilesRecordTrashLocation() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a.tmp", bytes: 1000)
        try tree.file("home/cache/b.tmp", bytes: 1000)
        waitForClockTick()
        let plan = CleanupPlan(
            items: [
                CleanupItem(
                    path: tree.path("home/cache"), kind: .looseFiles, size: 2000, looseFileNames: ["a.tmp", "b.tmp"], scanStarted: Date())
            ],
            useTrash: true)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.trashedBytes > 0)
        #expect(report.deletedBytes == 0)
        let entries = journalEntries(tree)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.method == .trash)
            #expect(entry.trashedTo.map(onDisk) == true)
        }
        // The report says where each went, so a scan tree can show them in the Trash.
        #expect(report.trashedLooseFiles[tree.path("home/cache")]?.sorted() == entries.compactMap(\.trashedTo).sorted())
    }

    @Test("A partly failed loose-file removal journals what went and charges the budget")
    func partialLooseFiles() throws {
        let tree = try TempTree()
        let stuck = try tree.file("home/cache/a.tmp", bytes: 8000)
        try tree.file("home/cache/b.tmp", bytes: 8000)
        try tree.file("home/cache2/c.tmp", bytes: 8000)
        #expect(chflags(stuck, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(stuck, 0) }
        waitForClockTick()
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache", "home/cache2"])
        let plan = CleanupPlan(
            items: [
                CleanupItem(
                    path: tree.path("home/cache"), kind: .looseFiles, size: 16_000, ruleID: "cache", looseFileNames: ["a.tmp", "b.tmp"],
                    scanStarted: Date()),
                CleanupItem(path: tree.path("home/cache2/c.tmp"), kind: .file, size: 8000, ruleID: "cache"),
            ], useTrash: false)
        let budget = ByteCount(tree.allocated("home/cache/b.tmp") + 1)
        let report = sandboxExecutor(tree, rules: [rule], budget: budget)
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(!onDisk(tree.path("home/cache/b.tmp")))
        #expect(onDisk(stuck))
        #expect(journalEntries(tree).map(\.path) == [tree.path("home/cache/b.tmp")])
        #expect(!report.warnings.isEmpty)
        #expect(onDisk(tree.path("home/cache2/c.tmp")), "the budget was spent on b.tmp")
    }
}

@Suite("Cleanup execution: each item's scan start")
struct ScanStartTests {
    @Test("Scans record when they started, and so do the analyses and items made from them")
    func scansRecordTheirStart() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a.tmp", bytes: 1000)
        let before = Date()
        let scanned = try scan(tree.path("home"))
        #expect(scanned.scanStarted >= before && scanned.scanStarted <= Date())
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let analysis = Analysis(findings: RuleEngine(rules: [rule]).evaluate(scanned), tree: scanned)
        #expect(analysis.scanStarted == scanned.scanStarted)
        let plan = CleanupPlan.make(findings: analysis.findings, scanStarted: analysis.scanStarted)
        #expect(!plan.items.isEmpty)
        #expect(plan.items.allSatisfy { $0.scanStarted == scanned.scanStarted })
    }

    @Test("A loose file created after the item's scan started stays; one from before is removed")
    func newLooseFilesSkipped() throws {
        let tree = try TempTree()
        try tree.file("home/cache/old.tmp", bytes: 1000)
        waitForClockTick()
        let scanned = try scan(tree.path("home/cache"))
        // A file named in the plan but created again after the scan is a different file, so it stays too.
        let item = CleanupItem(
            path: tree.path("home/cache"), kind: .looseFiles, size: 1000, looseFileNames: ["new.tmp", "old.tmp"],
            scanStarted: scanned.scanStarted)
        waitForClockTick()
        try tree.file("home/cache/new.tmp", bytes: 1000)
        _ = manualRun(CleanupPlan(items: [item], useTrash: false), with: sandboxExecutor(tree))
        #expect(!onDisk(tree.path("home/cache/old.tmp")))
        #expect(onDisk(tree.path("home/cache/new.tmp")))
    }

    @Test("A plan mixing items from two scans checks each item against its own scan's start")
    func mixedScans() throws {
        let tree = try TempTree()
        try tree.file("home/early/old.tmp", bytes: 1000)
        try tree.file("home/late/old.tmp", bytes: 1000)
        waitForClockTick()
        let early = try scan(tree.path("home/early"))
        waitForClockTick()
        // Created between the two scans: after the early scan started, before the late one.
        try tree.file("home/early/between.tmp", bytes: 1000)
        try tree.file("home/late/between.tmp", bytes: 1000)
        waitForClockTick()
        let late = try scan(tree.path("home/late"))
        let names = ["between.tmp", "old.tmp"]
        let plan = CleanupPlan(
            items: [
                CleanupItem(
                    path: tree.path("home/early"), kind: .looseFiles, size: 2000, looseFileNames: names, scanStarted: early.scanStarted),
                CleanupItem(
                    path: tree.path("home/late"), kind: .looseFiles, size: 2000, looseFileNames: names, scanStarted: late.scanStarted),
            ], useTrash: false)
        _ = manualRun(plan, with: sandboxExecutor(tree))
        #expect(!onDisk(tree.path("home/early/old.tmp")))
        #expect(onDisk(tree.path("home/early/between.tmp")), "the early scan never saw it")
        #expect(!onDisk(tree.path("home/late/old.tmp")))
        #expect(!onDisk(tree.path("home/late/between.tmp")), "the late scan saw it")
    }

    @Test("An item without a scan start can't remove loose files")
    func undatedItemRefusesLooseFiles() throws {
        let tree = try TempTree()
        try tree.file("home/cache/old.tmp", bytes: 1000)
        let plan = CleanupPlan(
            items: [CleanupItem(path: tree.path("home/cache"), kind: .looseFiles, size: 1000, looseFileNames: ["old.tmp"])],
            useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.skipped.first?.reason.contains("refresh") == true)
        #expect(onDisk(tree.path("home/cache/old.tmp")))
    }

    @Test("Items saved before scan starts were recorded decode without one")
    func decodesOldItems() throws {
        let item = #"{"path":"/tmp/a","kind":"looseFiles","name":"a","size":1,"isRepository":false,"containsRepository":false}"#
        let json = #"{"items":["# + item + #"],"commands":[],"manualSteps":[],"useTrash":true,"created":"2026-01-01T00:00:00Z"}"#
        let plan = try JSONDecoder.spaceKit.decode(CleanupPlan.self, from: Data(json.utf8))
        #expect(plan.items.first?.scanStarted == nil)
    }

    @Test("Emptying the Trash leaves what was trashed after the scan started")
    func lateTrashSkipped() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/early/x", bytes: 1000)
        waitForClockTick()
        let scanned = try scan(tree.path("home/.Trash"))
        waitForClockTick()
        try tree.file("home/.Trash/late/y", bytes: 1000)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/.Trash/early"), size: 1000, scanStarted: scanned.scanStarted),
                CleanupItem(path: tree.path("home/.Trash/late"), size: 1000, scanStarted: scanned.scanStarted),
            ], useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(!onDisk(tree.path("home/.Trash/early")))
        #expect(onDisk(tree.path("home/.Trash/late/y")))
        #expect(report.skipped.count == 1)
    }
}

@Suite("Cleanup execution: config and removal mechanics")
struct ExecutionMechanicsTests {
    @Test("An invalid config refuses every removal")
    func invalidConfigRefuses() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/build/x", bytes: 1000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a/build"), size: 1000)], useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree, configError: "config.yaml: bad"))
        #expect(report.skipped.first?.reason.contains("Config file is invalid") == true)
        #expect(onDisk(tree.path("home/Projects/a/build/x")))
    }

    @Test("A context loaded from an unreadable config refuses removals")
    func contextFailsClosed() throws {
        let tree = try TempTree()
        try tree.directory("config")
        try "safety:\n  maxBytesPerRun: lots\n".write(toFile: tree.path("config/config.yaml"), atomically: true, encoding: .utf8)
        try tree.file("work/build/x", bytes: 1000)
        let paths = SpaceKitPaths(configFile: tree.path("config/config.yaml"), stateDirectory: tree.path("state"))
        let context = SpaceKitContext.load(paths: paths)
        #expect(context.configError != nil)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("work/build"), size: 1000)], useTrash: false)
        var executor = context.executor
        executor.trash = sandboxTrash(home: tree.root)
        let report = manualRun(plan, with: executor)
        #expect(report.skipped.first?.reason.contains("Config file is invalid") == true)
        #expect(onDisk(tree.path("work/build/x")))
    }

    @Test("A symlink is removed as a link; its target stays")
    func symlinkRemovedAsLink() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/target/keep", bytes: 1000)
        try tree.directory("home/Projects/links")
        try FileManager.default.createSymbolicLink(
            atPath: tree.path("home/Projects/links/l"), withDestinationPath: tree.path("home/Projects/target"))
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/links/l"), size: 0)], useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(!onDisk(tree.path("home/Projects/links/l")))
        #expect(onDisk(tree.path("home/Projects/target/keep")))
    }

    @Test("Removal refuses a parent folder reached through a symlink")
    func handleRefusesSymlinkedParent() throws {
        let tree = try TempTree()
        try tree.directory("real")
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real"))
        let real = identity(tree.path("real"))
        #expect(throws: (any Error).self) { _ = try SafeRemoval.openDirectory(tree.path("link"), pinned: real) }
        let fd = try SafeRemoval.openDirectory(tree.path("real"), pinned: real)
        close(fd)
    }

    @Test("Removal refuses when the opened folder isn't the one that was checked")
    func handleRefusesMismatch() throws {
        let tree = try TempTree()
        try tree.directory("a")
        try tree.directory("b")
        #expect(throws: (any Error).self) { _ = try SafeRemoval.openDirectory(tree.path("a"), pinned: identity(tree.path("b"))) }
    }
}

final class CallCounter: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

@Suite("Cleanup execution: what the guard checked is what changes")
struct CheckedLocationTests {
    static func point(_ link: String, at destination: String) {
        unlink(link)
        symlink(destination, link)
    }

    @Test("A parent swapped to a harmless folder for the guard and back for the removal is still checked where it removes")
    func swapAroundTheGuard() throws {
        let tree = try TempTree()
        try tree.file("home/Protected/target/keep", bytes: 1_000)
        try tree.file("home/Harmless/target/x", bytes: 1_000)
        let link = tree.path("home/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("home/Harmless"))
        var executor = sandboxExecutor(tree, protectedPaths: [tree.path("home/Protected")])
        let calls = CallCounter()
        let harmless = tree.path("home/Harmless")
        let protected = tree.path("home/Protected")
        // The attacker's timing: resolving sees the protected folder, the guard the harmless one, the re-check the protected one.
        executor.resolve = { path in
            let first = calls.next() == 1
            if !first { CheckedLocationTests.point(link, at: protected) }
            let resolved = PathUtil.realpath(path)
            if first { CheckedLocationTests.point(link, at: harmless) }
            return resolved
        }
        let plan = CleanupPlan(items: [CleanupItem(path: link + "/target", size: 1_000)], useTrash: false)
        // The person reviews while the link points somewhere harmless; it points at the protected folder again by the run.
        let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
        CheckedLocationTests.point(link, at: protected)
        let report = executor.execute(reviewed, dryRun: false)
        #expect(report.items.count == 1)
        #expect(!report.items.contains { $0.outcome.isRemoved })
        #expect(onDisk(tree.path("home/Protected/target/keep")))
    }

    @Test("A warning that wasn't in the reviewed plan skips the item even when the person confirmed")
    func newWarningSkips() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000)], useTrash: false)
        let executor = sandboxExecutor(tree)
        let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
        try tree.directory("home/Projects/old/.git")
        let report = executor.execute(reviewed, dryRun: false)
        #expect(report.skipped.first?.reason.hasPrefix("Changed since you reviewed it: ") == true)
        #expect(report.skipped.first?.reason.contains("git repository") == true)
        #expect(onDisk(tree.path("home/Projects/old/x")))

        // The same warning shown in the review (the plan recorded the repository) is one the person accepted.
        var known = plan
        known.items[0].isRepository = true
        let confirmed = manualRun(known, with: executor)
        #expect(confirmed.items.first?.outcome.isRemoved == true)
    }

    /// The review judges the folder's files as a whole, so it can't show a reason that belongs to one file: a file
    /// refused at removal time is left like a refused item, reported and never dropped quietly, and isn't a problem,
    /// or every run of that folder would fail for good.
    @Test("A loose file refused at removal time is reported and left like a refused item, not as changed since the review")
    func refusedLooseFileReported() throws {
        let tree = try TempTree()
        try tree.file("home/stuff/a.log", bytes: 1_000)
        let secret = try tree.file("home/stuff/secret.log", bytes: 1_000)
        waitForClockTick()
        let executor = sandboxExecutor(tree, protectedPaths: [secret])
        func plan(_ names: [String]) -> CleanupPlan {
            CleanupPlan(
                items: [
                    CleanupItem(
                        path: tree.path("home/stuff"), kind: .looseFiles, size: 2_000, looseFileNames: names, scanStarted: Date())
                ], useTrash: false)
        }

        let alone = manualRun(plan(["secret.log"]), with: executor)
        guard case .skipped(let reason, let kind)? = alone.items.first?.outcome else {
            Issue.record("\(String(describing: alone.items.first?.outcome))")
            return
        }
        #expect(kind == .refused && !reason.hasPrefix(CleanupExecutor.changedSinceReview))
        #expect(reason.contains("secret.log") && reason.contains("Protected in your configuration"))
        #expect(!alone.hasProblems)

        let both = manualRun(plan(["a.log", "secret.log"]), with: executor)
        #expect(both.items.first?.outcome.isRemoved == true)
        #expect(both.notes.contains { $0.contains("secret.log") && !$0.contains(CleanupExecutor.changedSinceReview) })
        #expect(both.warnings.isEmpty && !both.hasProblems)
        #expect(!onDisk(tree.path("home/stuff/a.log")))
        #expect(onDisk(secret))
    }

    @Test("In an automatic run too, a protected loose file is left and reported without failing the run")
    func refusedLooseFileAutomatic() throws {
        let tree = try TempTree()
        try tree.file("home/stuff/a.log", bytes: 1_000)
        let secret = try tree.file("home/stuff/secret.log", bytes: 1_000)
        try tree.file("home/stuff/big.log", bytes: 64_000)
        waitForClockTick()
        let rule = cacheRule(tree, level: .safe, paths: ["home/stuff"])
        func plan(_ names: [String]) -> AutomaticPlan {
            let item = CleanupItem(
                path: tree.path("home/stuff"), kind: .looseFiles, size: 66_000, ruleID: rule.id, looseFileNames: names,
                scanStarted: Date())
            return AutomaticPlan(CleanupPlan(items: [item], useTrash: false), automation: AutomationContext(jobID: "j"))
        }
        let executor = sandboxExecutor(tree, rules: [rule], protectedPaths: [secret])
        let report = executor.execute(plan(["a.log", "secret.log"]), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.notes.contains { $0.contains("secret.log") }, "\(report.notes)")
        #expect(!report.hasProblems)
        #expect(!onDisk(tree.path("home/stuff/a.log")) && onDisk(secret))

        // Nothing removed: one file refused, another over the budget. The outcome names both, each path once.
        let small = sandboxExecutor(tree, rules: [rule], budget: ByteCount(8_000), protectedPaths: [secret])
        let left = small.execute(plan(["secret.log", "big.log"]), dryRun: false)
        guard case .skipped(let reason, let kind)? = left.items.first?.outcome else {
            Issue.record("\(String(describing: left.items.first?.outcome))")
            return
        }
        #expect(kind == .refused && !left.hasProblems)
        #expect(reason.contains("Protected in your configuration") && reason.contains("1 loose files over this run's budget"), "\(reason)")
        #expect(reason.components(separatedBy: "secret.log").count == 2, "\(reason)")
        #expect(onDisk(secret) && onDisk(tree.path("home/stuff/big.log")))
    }
}

@Suite("Cleanup execution: bytes a removal actually frees")
struct HardLinkFreedBytesTests {
    @Test("A file with another hard link outside the item frees nothing; the report and journal say so")
    func linkedOutside() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a/linked.bin", bytes: 40_000)
        try tree.file("home/cache/a/own.bin", bytes: 8_000)
        try tree.file("home/cache/single.bin", bytes: 30_000)
        try tree.file("home/cache/loose/plain.tmp", bytes: 4_000)
        try tree.directory("home/keep")
        try FileManager.default.linkItem(atPath: tree.path("home/cache/a/linked.bin"), toPath: tree.path("home/keep/linked.bin"))
        try FileManager.default.linkItem(atPath: tree.path("home/cache/single.bin"), toPath: tree.path("home/keep/single.bin"))
        try FileManager.default.linkItem(atPath: tree.path("home/cache/loose/plain.tmp"), toPath: tree.path("home/keep/plain.tmp"))
        try tree.file("home/cache/loose/own.tmp", bytes: 4_000)
        waitForClockTick()
        let scanned = Date()
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/cache/a"), size: 48_000, ruleID: "cache"),
                CleanupItem(path: tree.path("home/cache/single.bin"), kind: .file, size: 30_000, ruleID: "cache"),
                CleanupItem(
                    path: tree.path("home/cache/loose"), kind: .looseFiles, size: 8_000, ruleID: "cache",
                    looseFileNames: ["own.tmp", "plain.tmp"], scanStarted: scanned),
            ], useTrash: false)
        let own = tree.allocated("home/cache/a/own.bin")
        let ownLoose = tree.allocated("home/cache/loose/own.tmp")
        let report = manualRun(plan, with: sandboxExecutor(tree, rules: [rule]))
        #expect(report.items.map(\.outcome.freedBytes) == [own, 0, ownLoose])
        #expect(journalEntries(tree).reduce(UInt64(0)) { $0 + $1.bytes } == own + ownLoose)
        #expect(onDisk(tree.path("home/keep/linked.bin")))
    }
}
