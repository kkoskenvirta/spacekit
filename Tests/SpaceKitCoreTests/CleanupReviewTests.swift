import Foundation
import Testing

@testable import SpaceKitCore

/// Runs `plan` the way a front end does once a person said go: through a review, with every warning it showed
/// accepted unless `acceptingWarnings` is false. Rows the review blocked never reach the executor; they are added to
/// the report as skipped with the guard's reasons, so tests of a gate see its refusal whichever step makes it.
func manualRun(
    _ plan: CleanupPlan, with executor: CleanupExecutor, acceptingWarnings: Bool = true, dryRun: Bool = false,
    onProgress: CleanupExecutor.ProgressHandler? = nil
) -> CleanupReport {
    let review = CleanupReview(plan, executor: executor)
    var report = executor.execute(review.acknowledge(acceptingWarnings: acceptingWarnings), dryRun: dryRun, onProgress: onProgress)
    func refusal(_ verdict: SafetyVerdict) -> CleanupOutcome {
        .skipped(reason: "Blocked: " + verdict.reasons.joined(separator: "; "), kind: .refused)
    }
    report.items += review.items.filter(\.verdict.isBlocked).map { ($0.subject, refusal($0.verdict)) }
    report.commands += review.commands.filter(\.verdict.isBlocked).map { ($0.subject, refusal($0.verdict), "") }
    return report
}

@Suite("Cleanup review")
struct CleanupReviewTests {
    @Test("Nothing that needs confirmation runs without the person's acknowledgement")
    func acknowledgementRequired() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let review = CleanupReview(
            CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000)], useTrash: false), executor: executor)
        #expect(review.items.first?.verdict.decision == .confirm)
        #expect(review.needsAcknowledgement)
        #expect(review.warningCount == 1)

        let unacknowledged = executor.execute(review.acknowledge(acceptingWarnings: false), dryRun: false)
        #expect(unacknowledged.skipped.first?.reason.hasPrefix(CleanupExecutor.notAccepted) == true)
        #expect(unacknowledged.hasProblems, "a selected row left undone counts")
        #expect(onDisk(tree.path("home/Projects/old/x")))

        let acknowledged = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(acknowledged.items.first?.outcome.isRemoved == true)
    }

    @Test("Items and commands left because their warnings weren't accepted are reported alike, as problems")
    func notAcceptedRowsAreProblems() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        try tree.file("home/cache/a/y", bytes: 1_000)
        var tool = Rule(
            id: "tool", name: "Tool", paths: [], safety: SafetySpec(level: .review), action: ActionSpec(command: ["swift", "--version"]))
        tool.isBuiltin = true
        let cache = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let executor = sandboxExecutor(tree, rules: [tool, cache])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/old"), size: 1_000),
                CleanupItem(path: tree.path("home/cache/a"), size: 1_000, ruleID: "cache"),
            ],
            commands: [PlannedCommand(ruleID: "tool", arguments: ["swift", "--version"], estimatedBytes: 1)], useTrash: false)

        let report = executor.execute(CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: false), dryRun: true)

        let item = try #require(report.items.first { $0.item.path.hasSuffix("old") })
        let command = try #require(report.commands.first)
        let unknown = "No SpaceKit rule recognises this; make sure you don't need it"
        #expect(item.outcome == .notAccepted(unknown))
        #expect(command.outcome.isSkipped)
        if case .skipped(let reason, _) = command.outcome { #expect(reason.hasPrefix(CleanupExecutor.notAccepted)) }
        #expect(report.items.contains { $0.item.ruleID == "cache" && $0.outcome.isWouldRemove })
        #expect(report.hasProblems)

        let allowed = CleanupPlan(items: [CleanupItem(path: tree.path("home/cache/a"), size: 1_000, ruleID: "cache")], useTrash: false)
        let allowedReview = CleanupReview(allowed, executor: executor)
        #expect(!executor.execute(allowedReview.acknowledge(acceptingWarnings: false), dryRun: true).hasProblems)
    }

    @Test("Commands that need confirmation run only once acknowledged")
    func commandsNeedAcknowledgement() throws {
        let tree = try TempTree()
        var rule = Rule(
            id: "tool", name: "Tool", paths: [], safety: SafetySpec(level: .review), action: ActionSpec(command: ["swift", "--version"]))
        rule.isBuiltin = true
        let executor = sandboxExecutor(tree, rules: [rule])
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: ["swift", "--version"], estimatedBytes: 1)])
        let review = CleanupReview(plan, executor: executor)
        #expect(review.commands.first?.needsAcknowledgement == true)
        let refused = executor.execute(review.acknowledge(acceptingWarnings: false), dryRun: true)
        #expect(refused.unfinishedCommands.first?.reason.hasPrefix(CleanupExecutor.notAccepted) == true)
        let accepted = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: true)
        #expect(accepted.unfinishedCommands.isEmpty)
        #expect(accepted.commands.map(\.outcome) == [.wouldRemove(bytes: 1)])
    }

    @Test("A warning the review didn't show for a row is refused, even when another row showed it")
    func unshownWarningRefused() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/repo/x", bytes: 1_000)
        try tree.directory("home/Projects/repo/.git")
        try tree.file("home/Projects/plain/y", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/repo"), size: 1_000, isRepository: true),
                CleanupItem(path: tree.path("home/Projects/plain"), size: 1_000),
            ], useTrash: false)
        let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
        // After the review, the plain folder becomes a repository: the person accepted that warning for the other row only.
        try tree.directory("home/Projects/plain/.git")
        let report = executor.execute(reviewed, dryRun: false)
        #expect(!onDisk(tree.path("home/Projects/repo")))
        let skipped = try #require(report.skipped.first)
        #expect(skipped.item.path == tree.path("home/Projects/plain"))
        #expect(skipped.reason.hasPrefix("Changed since you reviewed it: "))
        #expect(skipped.reason.contains("git repository"))
        #expect(onDisk(tree.path("home/Projects/plain/y")))
    }

    @Test("A row the review allowed outright that gains a warning before the run is reported as changed")
    func allowedRowGainsWarning() throws {
        let tree = try TempTree()
        try tree.file("home/cache/app/x", bytes: 1_000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let executor = sandboxExecutor(tree, rules: [rule])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/cache/app"), size: 1_000, ruleID: "cache")], useTrash: false)
        let review = CleanupReview(plan, executor: executor)
        #expect(review.items.first?.verdict.decision == .allow)
        let reviewed = review.acknowledge(acceptingWarnings: false)

        try tree.directory("home/cache/app/.git")
        let report = executor.execute(reviewed, dryRun: false)
        let skipped = try #require(report.skipped.first)
        #expect(skipped.reason.hasPrefix(CleanupExecutor.changedSinceReview))
        #expect(skipped.reason.contains("git repository"))
        #expect(report.hasProblems)
        #expect(onDisk(tree.path("home/cache/app/x")))
    }

    @Test("An accepted warning holds only for the location the review saw")
    func reviewedLocationBound() throws {
        let tree = try TempTree()
        try tree.file("home/a/Thing/x", bytes: 1_000)
        try tree.file("home/b/Thing/y", bytes: 1_000)
        let link = tree.path("home/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("home/a"))
        let executor = sandboxExecutor(tree)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/link/Thing"), size: 1_000)], useTrash: false)
        let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)

        // The parent now leads elsewhere, to a folder that raises the same warning.
        #expect(unlink(link) == 0)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("home/b"))
        let redirected = executor.execute(reviewed, dryRun: false)
        #expect(redirected.skipped.first?.reason.hasPrefix(CleanupExecutor.changedSinceReview) == true)
        #expect(redirected.hasProblems)
        #expect(onDisk(tree.path("home/b/Thing/y")))

        // Back at the reviewed location, but another folder stands there now.
        #expect(unlink(link) == 0)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("home/a"))
        try FileManager.default.removeItem(atPath: tree.path("home/a/Thing"))
        try tree.file("home/a/Thing/z", bytes: 1_000)
        let replaced = executor.execute(reviewed, dryRun: false)
        #expect(replaced.skipped.first?.reason.hasPrefix(CleanupExecutor.changedSinceReview) == true)
        #expect(onDisk(tree.path("home/a/Thing/z")))
    }

    @Test("A run judges every item's share of the disk by the disk as it was when the run started")
    func volumeShareReadOncePerRun() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/big/x", bytes: 40_960)
        try tree.file("home/Projects/small/y", bytes: 16_384)
        let big = tree.path("home/Projects/big")
        var executor = sandboxExecutor(tree)
        // Removing the big folder shrinks the disk's used space, so the small one becomes a larger share of it.
        executor.safety = SafetyGuard(
            home: tree.path("home"), volumes: emptyVolumes, isRunningAsRoot: false,
            volumeCapacity: { _ in
                let used: UInt64 = onDisk(big) ? 100_000 : 60_000
                return VolumeCapacity(name: "Test", mountPoint: "/", total: 200_000, freeNow: 200_000 - used, available: 200_000 - used)
            })
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: big, size: 40_960), CleanupItem(path: tree.path("home/Projects/small"), size: 16_384),
            ], useTrash: false)
        let review = CleanupReview(plan, executor: executor)
        #expect(review.items.map { $0.verdict.reasons.contains("This holds 16% of the disk's used space") } == [false, true])

        let report = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)

        #expect(report.items.map(\.outcome.isRemoved) == [true, true], "\(report.skipped)")
        #expect(!report.hasProblems)
    }

    @Test("A reason's numbers are read apart from its words")
    func reasonNumbers() {
        let read = ReviewRecord.numbers(in: "This holds 12% of 3 disks, ٣ not counted")
        #expect(read.text == "This holds % of  disks, ٣ not counted")
        #expect(read.values == [12, 3])
        #expect(ReviewRecord.numbers(in: "99999999999999999999 bytes").values.isEmpty, "too large for a count")
    }

    @Test("An accepted volume share covers that share or less, not a larger one")
    func volumeShareBound() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/big/x", bytes: 40_000)
        var executor = sandboxExecutor(tree)
        executor.safety = SafetyGuard(
            home: tree.path("home"), volumes: emptyVolumes, isRunningAsRoot: false,
            volumeCapacity: { _ in VolumeCapacity(name: "Test", mountPoint: "/", total: 200_000, freeNow: 100_000, available: 100_000) })
        func plan(recording size: UInt64) -> CleanupPlan {
            CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/big"), size: size)], useTrash: false)
        }

        // Reviewed at 12%, about 40% at removal.
        let grown = manualRun(plan(recording: 12_000), with: executor)
        let skipped = try #require(grown.skipped.first)
        #expect(skipped.reason.hasPrefix(CleanupExecutor.changedSinceReview))
        #expect(skipped.reason.contains("of the disk's used space"))
        #expect(onDisk(tree.path("home/Projects/big/x")))

        // Reviewed at 50%, about 40% at removal.
        let shrunk = manualRun(plan(recording: 50_000), with: executor)
        #expect(shrunk.items.first?.outcome.isRemoved == true)
    }

    @Test("Unticked rows don't run, and the counts and totals leave them out")
    func untickedRowsDontRun() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        try tree.file("home/Projects/b/y", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/a"), size: 2_000),
                CleanupItem(path: tree.path("home/Projects/b"), size: 1_000),
            ], useTrash: false)
        let review = CleanupReview(plan, executor: executor)
        let keepB = try #require(review.items.first { $0.subject.path == tree.path("home/Projects/b") })
        let narrowed = review.setting(keepB, included: false)
        #expect(review.isIncluded(keepB))
        #expect(!narrowed.isIncluded(keepB))
        #expect(narrowed.selectedItems.map(\.path) == [tree.path("home/Projects/a")])
        #expect(narrowed.itemBytes == 2_000)
        #expect(narrowed.warningCount == 1)

        let report = executor.execute(narrowed.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(report.items.map(\.item.path) == [tree.path("home/Projects/a")])
        #expect(!onDisk(tree.path("home/Projects/a")))
        #expect(onDisk(tree.path("home/Projects/b/y")))
        #expect(narrowed.setting(keepB, included: true).selectedItems.count == 2)
    }

    @Test("A review made again keeps the rows the person unticked and their Trash choice")
    func reviewAgainKeepsChoices() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        try tree.file("home/Projects/b/y", bytes: 1_000)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/a"), size: 2_000),
                CleanupItem(path: tree.path("home/Projects/b"), size: 1_000),
            ], useTrash: true)
        let first = CleanupReview(plan, executor: sandboxExecutor(tree))
        let keepB = try #require(first.items.first { $0.subject.path == tree.path("home/Projects/b") })
        let chosen = first.setting(keepB, included: false).usingTrash(false)

        // The settings changed: another executor reviews the same plan.
        let again = CleanupReview(plan, executor: sandboxExecutor(tree)).keepingChoices(of: chosen)

        #expect(again.selectedItems.map(\.path) == [tree.path("home/Projects/a")])
        #expect(!again.useTrash)
        let row = try #require(again.items.first { $0.id == keepB.id })
        #expect(again.setting(row, included: true).selectedItems.count == 2)
    }

    @Test("Blocked rows can't be ticked and never reach the executor")
    func blockedRowsNeverRun() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let arguments = ["xcrun", "--version"]
        var user = Rule(id: "tool", name: "Tool", paths: [], safety: SafetySpec(level: .safe), action: ActionSpec(command: arguments))
        user.isBuiltin = false
        let executor = sandboxExecutor(tree, rules: [user])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home"), size: 1_000),
                CleanupItem(path: tree.path("home/Projects/a"), size: 1_000),
            ],
            commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 1)], useTrash: false)
        let review = CleanupReview(plan, executor: executor)
        #expect(review.blockedCount == 2)
        let home = try #require(review.items.first { $0.subject.path == tree.path("home") })
        #expect(home.verdict.isBlocked)
        #expect(!review.setting(home, included: true).isIncluded(home))
        #expect(review.selectedItems.map(\.path) == [tree.path("home/Projects/a")])
        #expect(review.selectedCommands.isEmpty)

        let report = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(report.items.map(\.item.path) == [tree.path("home/Projects/a")])
        #expect(report.commands.isEmpty)
        #expect(onDisk(tree.path("home")))
    }

    @Test("The review says where the selected items go")
    func disposalWording() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 1_000)
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let trashed = CleanupItem(path: tree.path("home/.Trash/old"), size: 1_000, scanStarted: Date())
        let project = CleanupItem(path: tree.path("home/Projects/a"), size: 1_000)

        let emptying = CleanupReview(CleanupPlan(items: [trashed], useTrash: true), executor: executor)
        #expect(emptying.disposal == .deleteFromTrash)
        #expect(emptying.disposalSummary?.contains("already in the Trash") == true)

        let review = CleanupReview(CleanupPlan(items: [trashed, project], useTrash: true), executor: executor)
        // What's already in the Trash is deleted for good even when the rest goes there; the wording says which part.
        #expect(review.disposal == .moveToTrashAndDeleteFromTrash)
        #expect(review.disposal.isPermanent)
        #expect(
            review.disposalSummary
                == "1.0 KB will be moved to the Trash; 1.0 KB already in the Trash will be deleted permanently.")
        let projectRow = try #require(review.items.first { $0.id == project.id })
        #expect(review.setting(projectRow, included: false).disposal == .deleteFromTrash)
        let trashedRow = try #require(review.items.first { $0.id == trashed.id })
        #expect(review.setting(trashedRow, included: false).disposal == .moveToTrash)
        #expect(!review.setting(trashedRow, included: false).disposal.isPermanent)
        #expect(review.canChooseTrash)
        #expect(review.usingTrash(false).disposal == .delete)
        #expect(review.usingTrash(false).disposalSummary?.contains("deleted permanently") == true)
        #expect(review.commandSummary == nil)

        var always = executor
        always.alwaysTrash = true
        let forced = CleanupReview(CleanupPlan(items: [project], useTrash: false), executor: always)
        #expect(!forced.canChooseTrash)
        #expect(forced.disposal == .moveToTrash)
        #expect(forced.acknowledge(acceptingWarnings: true).plan.useTrash, "the reviewed plan says what the removal will do")
        #expect(!review.usingTrash(false).acknowledge(acceptingWarnings: true).plan.useTrash)
    }

    @Test("The unticked Trash choice is what runs")
    func trashChoiceRuns() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let review = CleanupReview(
            CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a"), size: 1_000)], useTrash: true), executor: executor)
        let report = executor.execute(review.usingTrash(false).acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.trashedBytes == 0)
    }

    @Test("A reviewed plan runs only on the executor that made its review")
    func reviewBindsToExecutor() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a"), size: 1_000)], useTrash: false)
        let reviewedWith = sandboxExecutor(tree)
        let reviewed = CleanupReview(plan, executor: reviewedWith).acknowledge(acceptingWarnings: true)
        // Settings read again (the same values, even) make another executor: the review was of the old one.
        let current = sandboxExecutor(tree)

        let refused = current.execute(reviewed, dryRun: false)

        #expect(refused.reviewOutdated)
        #expect(refused.skipped.first?.reason == CleanupExecutor.outdatedReview)
        #expect(refused.hasProblems)
        #expect(!refused.removedAnything)
        #expect(onDisk(tree.path("home/Projects/a/x")))

        let ran = reviewedWith.execute(reviewed, dryRun: false)
        #expect(!ran.reviewOutdated)
        #expect(ran.items.first?.outcome.isRemoved == true)
    }
}
