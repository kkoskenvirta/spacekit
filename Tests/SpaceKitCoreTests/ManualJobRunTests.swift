import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Manual job runs")
struct ManualJobRunTests {
    /// A fixture with one 🟢 rule over `home/build`, whose child folders are the items.
    func buildFixture(_ folders: [String]) throws -> RunnerFixture {
        var fixture = try RunnerFixture()
        for folder in folders { try fixture.tree.file("home/build/\(folder)/out.o", bytes: 8192) }
        fixture.rules = [fixture.rule("build", "home/build", level: .safe)]
        return fixture
    }

    func buildJob(mode: Job.Mode = .suggest, sizeAbove: ByteCount? = nil) -> Job {
        Job(id: "build", name: "Build", rules: ["build"], mode: mode, when: Job.Conditions(sizeAbove: sizeAbove), action: .delete)
    }

    /// Runs the job the way the agent does, so its suggestion is saved, and returns it.
    func suggest(_ fixture: RunnerFixture, job: Job) throws -> Suggestion {
        guard case .suggested(let suggestion) = fixture.runner.run(job, now: Date(timeIntervalSince1970: 1_000)).action else {
            throw TestFailure("expected a suggestion")
        }
        return suggestion
    }

    func reviewed(_ run: ManualJobRun, _ executor: CleanupExecutor, untick: Set<String> = []) throws -> ReviewedPlan {
        var review = CleanupReview(try #require(run.plan), executor: executor)
        for row in review.items where untick.contains(PathUtil.lastComponent(row.subject.path)) {
            review = review.setting(row, included: false)
        }
        return review.acknowledge(acceptingWarnings: false)
    }

    func lastRun(_ fixture: RunnerFixture) -> Date? { fixture.context.jobStates.load()["build"]?.lastRun }

    @Test("Preparing and completing a job run removes its plan, records the run and journals each removal once")
    func jobRun() throws {
        let fixture = try buildFixture(["a"])
        let run = try ManualJobRun.prepare(buildJob(), runner: fixture.runner)
        let executor = fixture.runner.executor
        #expect(run.skipReason == nil)
        #expect(lastRun(fixture) == nil)

        let date = Date(timeIntervalSince1970: 5_000)
        let outcome = run.complete(try reviewed(run, executor), executor: executor, now: date)

        #expect(outcome.report.freedBytes > 0)
        #expect(outcome.saveErrors.isEmpty)
        #expect(outcome.fate == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.tree.path("home/build/a")))
        #expect(lastRun(fixture) == date)
        #expect(fixture.context.jobStates.load()["build"]?.lastOutcome == outcome.report.summary)
        let journal = Journal(file: fixture.tree.path("state/journal.jsonl")).entries()
        #expect(journal.map(\.path) == [fixture.tree.path("home/build/a")])
        #expect(journal.first?.automatic == false)
    }

    @Test("A run completes with the executor current at completion and refuses a review made with another one")
    func completesWithCurrentExecutor() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        // The settings change after the review: the context now has another executor.
        let reviewedWith = fixture.runner.executor
        let plan = try reviewed(run, reviewedWith)
        let current = fixture.runner.executor
        let suggested = lastRun(fixture)

        let refused = run.complete(plan, executor: current)

        #expect(refused.report.reviewOutdated)
        #expect(refused.fate == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.tree.path("home/build/a")))
        #expect(lastRun(fixture) == suggested, "a refused run records nothing")
        let stored = try #require(fixture.context.suggestions.get(suggestion.id), "a refused run leaves the suggestion alone")
        #expect(stored.plan.items.count == suggestion.plan.items.count)
        #expect(stored.problems.isEmpty)

        let outcome = run.complete(try reviewed(run, current), executor: current)
        #expect(outcome.report.removedAnything)
        #expect(outcome.fate == .dismissed)
        #expect(lastRun(fixture) != suggested)
    }

    @Test("A job below its threshold would skip, says why, and runs only when forced")
    func belowThreshold() throws {
        let fixture = try buildFixture(["a"])
        let run = try ManualJobRun.prepare(buildJob(sizeAbove: .gb(1)), runner: fixture.runner)
        let executor = fixture.runner.executor

        #expect(run.skipReason?.hasSuffix("is below the 1.0 GB threshold") == true)
        #expect(run.jobName == "Build")
        #expect(run.canForce)
        #expect(run.plan == nil)

        let forced = run.forced()
        #expect(forced.skipReason == nil)
        let plan = try reviewed(forced, executor)

        // Only the forced run runs it: the skipped one removes nothing and records nothing.
        let skipped = run.complete(plan, executor: executor)
        #expect(!skipped.report.removedAnything)
        #expect(FileManager.default.fileExists(atPath: fixture.tree.path("home/build/a")))
        #expect(lastRun(fixture) == nil)

        let outcome = forced.complete(plan, executor: executor)
        #expect(outcome.report.removedAnything)
        #expect(lastRun(fixture) != nil)
    }

    @Test("A job with nothing to clean can't be forced")
    func nothingToForce() throws {
        let fixture = try buildFixture([])
        try fixture.tree.directory("home/build")
        let run = try ManualJobRun.prepare(buildJob(), runner: fixture.runner)
        #expect(run.skipReason == "Nothing matches the job's conditions")
        #expect(!run.canForce)
        #expect(run.forced().plan == nil)
    }

    @Test("Approving a suggestion that removes everything dismisses it and records the job's run")
    func approvalDismisses() throws {
        var fixture = try buildFixture(["a", "b"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let executor = fixture.runner.executor

        let date = Date(timeIntervalSince1970: 9_000)
        let outcome = run.complete(try reviewed(run, executor), executor: executor, now: date)

        #expect(outcome.fate == .dismissed)
        #expect(fixture.context.suggestions.all().isEmpty)
        #expect(lastRun(fixture) == date)
    }

    @Test("A partly successful approval keeps the suggestion, narrowed to what's left, with the problems attached")
    func approvalKeepsRemainder() throws {
        var fixture = try buildFixture(["a", "b", "c"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let executor = fixture.runner.executor
        // `b` can't lose its contents, so removing it fails; `c` is unticked.
        #expect(chmod(fixture.tree.path("home/build/b"), 0o555) == 0)
        defer { chmod(fixture.tree.path("home/build/b"), 0o755) }

        let outcome = run.complete(try reviewed(run, executor, untick: ["c"]), executor: executor)

        guard case .kept(let kept) = outcome.fate else {
            Issue.record("expected the suggestion to be kept")
            return
        }
        #expect(kept.id == suggestion.id)
        #expect(kept.plan.items.map { PathUtil.lastComponent($0.path) }.sorted() == ["b", "c"])
        #expect(kept.problems.count == 1)
        #expect(kept.problems.first?.contains("build/b") == true)
        let stored = try #require(fixture.context.suggestions.get(suggestion.id))
        #expect(stored.plan.items.count == 2)
        #expect(stored.problems == kept.problems)
        #expect(lastRun(fixture) != nil)
    }

    @Test("An approval that removed nothing because nothing eligible is left dismisses the suggestion")
    func nothingLeft() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let executor = fixture.runner.executor
        let plan = try reviewed(run, executor)
        try FileManager.default.removeItem(atPath: fixture.tree.path("home/build/a"))

        let outcome = run.complete(plan, executor: executor)

        #expect(!outcome.report.removedAnything)
        #expect(outcome.fate == .dismissed)
        #expect(fixture.context.suggestions.all().isEmpty)
    }

    @Test("An approval settles against the suggestion as stored now: what another approval settled stays settled")
    func approvalSettlesAgainstStored() throws {
        var fixture = try buildFixture(["a", "b"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let executor = fixture.runner.executor
        let plan = try reviewed(run, executor, untick: ["b"])
        // Meanwhile another approval settled `b` and kept only `a`.
        var narrowed = suggestion
        narrowed.plan.items = suggestion.plan.items.filter { PathUtil.lastComponent($0.path) == "a" }
        try fixture.context.suggestions.add(narrowed)

        let outcome = run.complete(plan, executor: executor)

        #expect(outcome.report.removedAnything)
        #expect(outcome.fate == .dismissed, "b, unticked here, was already settled by the other approval")
        #expect(fixture.context.suggestions.all().isEmpty)
    }

    @Test("An approval of a suggestion dismissed meanwhile says so and doesn't bring it back")
    func approvalOfDismissed() throws {
        var fixture = try buildFixture(["a", "b"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let executor = fixture.runner.executor
        let plan = try reviewed(run, executor, untick: ["b"])
        try fixture.context.suggestions.remove(suggestion.id)

        let outcome = run.complete(plan, executor: executor)

        #expect(outcome.report.removedAnything)
        #expect(outcome.fate == .gone)
        #expect(fixture.context.suggestions.all().isEmpty)
    }

    @Test("Approving a suggestion with nothing left dismisses it and records the job's run without running anything")
    func nothingEligibleAtPrepare() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        try FileManager.default.removeItem(atPath: fixture.tree.path("home/build/a"))
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        #expect(run.plan == nil)
        #expect(!run.canForce)
        #expect(run.hasNothingLeft)

        let date = Date(timeIntervalSince1970: 7_000)
        let outcome = try #require(run.settleWithNothingLeft(now: date))

        #expect(outcome.fate == .dismissed)
        #expect(outcome.report.items.isEmpty && outcome.report.commands.isEmpty)
        #expect(outcome.saveErrors.isEmpty)
        #expect(fixture.context.suggestions.all().isEmpty)
        #expect(lastRun(fixture) == date)
    }

    @Test("Approving a suggestion whose remaining rows are all blocked dismisses it and records the job's run")
    func nothingSelectableAtPrepare() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        // Protected since it was suggested: the job still finds it, the guard blocks it.
        let folder = fixture.tree.path("home/build/a")
        let protected = sandboxExecutor(fixture.tree, rules: fixture.rules, protectedPaths: [folder], protectedRules: fixture.rules)
        let runner = JobRunner(context: fixture.context, executor: protected, notifier: fixture.notifier)

        let run = try ManualJobRun.prepare(suggestion, runner: runner)

        #expect(run.plan == nil)
        #expect(!run.canForce)
        #expect(run.hasNothingLeft)
        #expect(run.skipReason?.contains("Protected in your configuration") == true)
        // Front ends list the blocked rows with their verdicts (suggestions approve --json).
        #expect(run.blockedRows.items.map(\.path) == [folder])
        let date = Date(timeIntervalSince1970: 7_000)
        let outcome = try #require(run.settleWithNothingLeft(now: date))
        #expect(outcome.fate == .dismissed)
        #expect(fixture.context.suggestions.all().isEmpty)
        #expect(lastRun(fixture) == date)
        #expect(onDisk(folder))
    }

    /// `sudo spacekit suggestions approve <id> --yes` must not dismiss the suggestion for good: the rows are blocked by
    /// how SpaceKit runs, not by what they are.
    @Test(
        "An invalid config or running as root blocks every row but doesn't dismiss the suggestion: fixing that unblocks them",
        arguments: [true, false])
    func circumstancesKeepSuggestion(_ invalidConfig: Bool) throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let blocked = sandboxExecutor(
            fixture.tree, rules: fixture.rules, configError: invalidConfig ? "bad" : nil, root: !invalidConfig,
            protectedRules: fixture.rules)

        let runner = JobRunner(context: fixture.context, executor: blocked, notifier: fixture.notifier)

        let run = try ManualJobRun.prepare(suggestion, runner: runner)

        #expect(!run.hasNothingLeft && run.settleWithNothingLeft() == nil)
        #expect(run.blockedRows.isEmpty)
        let plan = try #require(run.plan)
        // Nothing can be selected, so nothing runs; were it completed anyway, the suggestion stays as it was.
        let review = CleanupReview(plan, executor: blocked)
        #expect(review.isEmpty)
        let outcome = run.complete(review.acknowledge(acceptingWarnings: true), executor: blocked)
        if case .kept(let kept)? = outcome.fate {
            #expect(kept.plan.items.map(\.path) == suggestion.plan.items.map(\.path))
        } else {
            Issue.record("\(String(describing: outcome.fate))")
        }
        #expect(onDisk(fixture.tree.path("home/build/a")))
    }

    @Test("Only an approval with nothing left settles without a run")
    func settlingNeedsNothingLeft() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let approval = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let jobRun = try ManualJobRun.prepare(job, runner: fixture.runner)
        let suggested = lastRun(fixture)

        #expect(!approval.hasNothingLeft && approval.settleWithNothingLeft() == nil)
        #expect(!jobRun.hasNothingLeft && jobRun.settleWithNothingLeft() == nil)
        #expect(fixture.context.suggestions.get(suggestion.id) != nil)
        #expect(lastRun(fixture) == suggested)
    }

    @Test("Approving drops items that no longer meet the job's conditions, and isn't held back by its threshold")
    func approvalNarrows() throws {
        var fixture = try buildFixture(["a", "b"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        try FileManager.default.removeItem(atPath: fixture.tree.path("home/build/b"))
        fixture.config.jobs = [buildJob(sizeAbove: .gb(1))]

        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)

        #expect(!run.evaluation.isTriggered)
        #expect(run.skipReason == nil)
        #expect(run.plan?.items.map { PathUtil.lastComponent($0.path) } == ["a"])
        #expect(run.dropped.map { PathUtil.lastComponent($0.path) } == ["b"])
    }

    @Test("Approving takes each item's facts from the fresh evaluation, never more than the saved suggestion offered")
    func approvalTrustsFreshFacts() throws {
        var fixture = try buildFixture(["a"])
        try fixture.tree.file("home/build/stray.log", bytes: 4096)
        let job = buildJob()
        fixture.config.jobs = [job]
        var suggestion = try suggest(fixture, job: job)
        let loose = try #require(suggestion.plan.items.firstIndex { $0.kind == .looseFiles })
        let folder = try #require(suggestion.plan.items.firstIndex { $0.kind == .directory })
        // A suggestions file edited after it was saved: facts that would widen what the run may remove.
        suggestion.plan.items[loose].looseFileNames = ["stray.log", "elsewhere.log"]
        suggestion.plan.items[loose].scanStarted = Date.distantFuture
        suggestion.plan.items[folder].ruleID = "other"
        suggestion.plan.items[folder].size = 1
        let saved = Date(timeIntervalSince1970: 500)
        suggestion.plan.items[folder].scanStarted = saved

        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let items = try #require(run.plan?.items)
        let fresh = fixture.runner.plan(for: run.evaluation)
        let looseItem = try #require(items.first { $0.kind == .looseFiles })
        #expect(looseItem.looseFileNames == ["stray.log"])
        #expect(looseItem.scanStarted == run.evaluation.scanStarted, "never later than the scan that saw the files")
        let folderItem = try #require(items.first { $0.kind == .directory })
        #expect(folderItem.ruleID == "build")
        #expect(folderItem.size == fresh.items.first { $0.id == folderItem.id }?.size)
        #expect(folderItem.scanStarted == saved, "an earlier saved scan start is the stricter one")
    }

    @Test("A suggestion whose job is gone can't be approved")
    func missingJob() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        fixture.config.jobs = []
        #expect(throws: ManualJobRun.JobMissing.self) { try ManualJobRun.prepare(suggestion, runner: fixture.runner) }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
