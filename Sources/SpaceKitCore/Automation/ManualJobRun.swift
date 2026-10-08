import Foundation

/// A job a person runs by hand, or a suggestion they approve, in two steps around the review.
///
/// `prepare` evaluates the job now and says whether the run would go ahead or skip, and why. A suggestion's saved plan
/// is narrowed to what the fresh evaluation still offers. `complete`, which exists only on a prepared run, executes the
/// reviewed plan with the executor current then, records the job's run so its schedule moves on, and settles the
/// suggestion. The app, the TUI and the CLI only show the prepared run, review its plan and ask.
public struct ManualJobRun: Sendable {
    /// The job's evaluation at `prepare` time.
    public let evaluation: JobEvaluation
    /// The suggestion being approved; `nil` when the job runs by hand.
    public let suggestion: Suggestion?
    /// The suggestion's items that no longer meet the job's conditions, left out of the plan.
    public let dropped: [CleanupItem]
    /// The person chose to run it although the job is below its threshold.
    public let isForced: Bool
    /// Everything the run could offer, whether or not it would skip.
    private let candidate: CleanupPlan
    /// For an approval whose every remaining row the guard blocks: a reason one of them is blocked for.
    private let allBlocked: String?

    /// The rows of an approval that the guard blocks every one of (`hasNothingLeft`), for front ends to list with their
    /// verdicts; empty for any other run.
    public var blockedRows: CleanupPlan { allBlocked != nil ? candidate : CleanupPlan() }
    private let runner: JobRunner

    /// The suggestion's job is no longer in the config, so its conditions can't be checked.
    public struct JobMissing: LocalizedError {
        public let suggestion: Suggestion

        public var errorDescription: String? {
            "The job “\(suggestion.jobName)” that prepared this cleanup is no longer in your config, so its conditions can't be "
                + "checked. Dismiss the suggestion."
        }
    }

    /// What became of an approved suggestion.
    public enum SuggestionFate: Sendable, Equatable {
        /// Nothing eligible is left of it, so it's gone.
        case dismissed
        /// Narrowed to the rows still left to clean, with the problems the run hit.
        case kept(Suggestion)
        /// It was dismissed, or replaced by a newer run of its job, while this approval ran, so there was nothing to
        /// settle and it wasn't brought back.
        case gone
    }

    public struct Outcome: Sendable {
        public let report: CleanupReport
        /// What became of the approved suggestion. `nil` for a job run by hand, a run refused as reviewed with another
        /// executor, and a suggestion that couldn't be saved (`saveErrors` says why).
        public let fate: SuggestionFate?
        /// The job's state or the suggestion that couldn't be saved. The removals happened regardless.
        public let saveErrors: [String]
    }

    // MARK: Prepare

    /// Evaluates `job` for a run by hand. It goes ahead when the job is triggered, or when forced.
    public static func prepare(_ job: Job, runner: JobRunner, progress: ScanProgress = ScanProgress(), now: Date = Date()) throws
        -> ManualJobRun
    {
        let evaluation = try runner.evaluate(job, progress: progress, now: now)
        return ManualJobRun(
            evaluation: evaluation, suggestion: nil, dropped: [], isForced: false, candidate: runner.plan(for: evaluation),
            allBlocked: nil, runner: runner)
    }

    /// Evaluates the job that prepared `suggestion` again and narrows the suggestion to what still meets the job's
    /// conditions: a project used since then drops out. What runs is described by the fresh evaluation, never by the
    /// saved file, which only limits it. The job's threshold doesn't hold an approval back; it was
    /// crossed when the suggestion was made, and approving is the person's explicit go-ahead.
    public static func prepare(_ suggestion: Suggestion, runner: JobRunner, progress: ScanProgress = ScanProgress(), now: Date = Date())
        throws -> ManualJobRun
    {
        guard let job = runner.context.config.jobs.first(where: { $0.id == suggestion.jobID }) else {
            throw JobMissing(suggestion: suggestion)
        }
        let evaluation = try runner.evaluate(job, progress: progress, now: now)
        let (plan, dropped) = suggestion.plan.keeping(onlyIn: runner.plan(for: evaluation))
        return ManualJobRun(
            evaluation: evaluation, suggestion: suggestion, dropped: dropped, isForced: false, candidate: plan,
            allBlocked: allBlocked(plan, executor: runner.executor), runner: runner)
    }

    /// A reason the guard blocks a row of `plan` for, when it blocks every row, so a review would have nothing to select.
    /// Only the rows' own blocks count: an invalid config or running as root (`sudo`) blocks everything until it's
    /// fixed, which unblocks the rows (`CleanupExecutor.blocksEverything`).
    private static func allBlocked(_ plan: CleanupPlan, executor: CleanupExecutor) -> String? {
        guard !plan.isEmpty, !executor.blocksEverything else { return nil }
        let review = CleanupReview(plan, executor: executor)
        guard review.isEmpty else { return nil }
        let verdicts = review.items.map(\.verdict) + review.commands.map(\.verdict)
        return verdicts.lazy.flatMap(\.entries).first { $0.decision == .block }?.reason
    }

    /// The name of the job that runs, for front ends to show.
    public var jobName: String { evaluation.job.name }

    /// Why the run would do nothing now, or `nil` when its plan is ready for review.
    public var skipReason: String? {
        if candidate.isEmpty {
            return suggestion == nil
                ? evaluation.triggerSummary : "Nothing in this suggestion still meets the job's conditions: it was used or removed since"
        }
        if let allBlocked { return "Everything left in this suggestion is blocked: \(allBlocked)" }
        if suggestion == nil && !evaluation.isTriggered && !isForced { return evaluation.triggerSummary }
        return nil
    }

    /// Whether `forced()` would make a skipped run reviewable: only a threshold holds it back, not an empty plan or one
    /// with nothing left to select.
    public var canForce: Bool { skipReason != nil && !candidate.isEmpty && !hasNothingLeft }

    /// This run, going ahead although the job is below its threshold ("Run anyway", `--force`).
    public func forced() -> ManualJobRun {
        ManualJobRun(
            evaluation: evaluation, suggestion: suggestion, dropped: dropped, isForced: true, candidate: candidate, allBlocked: allBlocked,
            runner: runner)
    }

    /// The plan to review, or `nil` while the run would skip.
    public var plan: CleanupPlan? { skipReason == nil ? candidate : nil }

    // MARK: Complete

    /// Runs `reviewed` with `executor`, the one of the context current now (not the one `prepare` saw: the settings
    /// may have changed while the person reviewed), and records the job's run. Only rows of this run's `plan` run, so
    /// a run that would skip removes nothing and records nothing, and a suggestion's dropped items can't come back
    /// through another review.
    ///
    /// A plan reviewed with another executor doesn't run (`CleanupReport.reviewOutdated`): nothing is recorded and the
    /// suggestion stays as it is, for the person to review again.
    ///
    /// An approved suggestion is then settled: what's left of it is checked again (not removed, still on disk, not
    /// blocked). With nothing left it's dismissed; otherwise it's kept, narrowed to that, with the run's problems.
    public func complete(
        _ reviewed: ReviewedPlan, executor: CleanupExecutor, now: Date = Date(), onProgress: CleanupExecutor.ProgressHandler? = nil
    ) -> Outcome {
        guard let plan else { return Outcome(report: CleanupReport(dryRun: false), fate: nil, saveErrors: []) }
        let report = executor.execute(reviewed.limited(to: plan), dryRun: false, onProgress: onProgress)
        if report.reviewOutdated { return Outcome(report: report, fate: nil, saveErrors: []) }
        return finish(report, action: .cleaned(report), now: now) { left(after: report, executor: executor) }
    }

    /// An approval of a suggestion nothing of which still meets the job's conditions, or whose every remaining row the
    /// guard blocks. There is nothing to select, review or force; `settleWithNothingLeft(now:)` finishes it.
    public var hasNothingLeft: Bool { suggestion != nil && (candidate.isEmpty || allBlocked != nil) }

    /// Finishes an approval with nothing left (`hasNothingLeft`) without running anything: records the job's run, as
    /// every approval does, and dismisses the suggestion. `nil` for any other run, which finishes through `complete`.
    public func settleWithNothingLeft(now: Date = Date()) -> Outcome? {
        guard hasNothingLeft else { return nil }
        return finish(CleanupReport(dryRun: false), action: .notTriggered(skipReason ?? ""), now: now) { CleanupPlan() }
    }

    /// Records the job's run and settles the suggestion being approved to what's `left` of it. The suggestion is
    /// settled as stored now, under the store's lock: another approval may have settled some of it meanwhile.
    private func finish(_ report: CleanupReport, action: JobRunResult.Action, now: Date, left: () -> CleanupPlan) -> Outcome {
        var errors: [String] = []
        do {
            try runner.record(JobRunResult(job: evaluation.job, date: now, evaluation: evaluation, action: action))
        } catch {
            errors.append("Couldn't save the job's state: \(error.localizedDescription)")
        }
        guard let suggestion else { return Outcome(report: report, fate: nil, saveErrors: errors) }
        let fate: SuggestionFate
        do {
            fate = try runner.context.suggestions.narrow(suggestion.id, to: left(), problems: report.problemDetails)
        } catch {
            errors.append("Couldn't save the suggestion: \(error.localizedDescription)")
            return Outcome(report: report, fate: nil, saveErrors: errors)
        }
        return Outcome(report: report, fate: fate, saveErrors: errors)
    }

    /// The still-eligible rows that weren't removed, still exist and aren't blocked, which includes rows the person
    /// unticked. Blocks that come from the run's circumstances (`CleanupExecutor.blocksEverything`) don't count.
    private func left(after report: CleanupReport, executor: CleanupExecutor) -> CleanupPlan {
        let removedItems = Set(report.items.filter(\.outcome.isRemoved).map(\.item.id))
        let ranCommands = Set(report.commands.filter(\.outcome.isRemoved).map(\.command.id))
        let judged = !executor.blocksEverything
        var left = candidate
        left.items = candidate.items.filter {
            !removedItems.contains($0.id) && Self.exists($0.path) && !(judged && executor.verdict(for: $0, context: .manual).isBlocked)
        }
        left.commands = candidate.commands.filter {
            !ranCommands.contains($0.id) && !(judged && executor.verdict(for: $0, context: .manual).isBlocked)
        }
        return left
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

extension CleanupReport {
    /// One line per thing the run left undone, with its reason.
    var problemDetails: [String] {
        failures.map { "\(PathUtil.abbreviate($0.item.path)): \($0.reason)" }
            + skipped.map { "\(PathUtil.abbreviate($0.item.path)): \($0.reason)" }
            + unfinishedCommands.map { "\($0.command.displayString): \($0.reason)" } + warnings
    }
}
