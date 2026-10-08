import Foundation

/// What a job would do right now.
public struct JobEvaluation: Sendable {
    public var job: Job
    /// Everything the job's rules and folders matched.
    public var findings: [Finding]
    /// Findings narrowed to items that pass the job's age conditions.
    public var eligible: [Finding]
    /// When the scan behind these findings started. Files changed after it weren't part of what was evaluated.
    public var scanned: Date = Date()

    public var matchedBytes: UInt64 { findings.reduce(0) { $0 &+ $1.size } }
    public var eligibleBytes: UInt64 { eligible.reduce(0) { $0 &+ $1.size } }

    /// True when the job's size threshold (if any) is exceeded and there's something to clean.
    public var isTriggered: Bool {
        if let threshold = job.when.sizeAbove, matchedBytes < threshold.bytes { return false }
        return eligibleBytes > 0
    }

    public var triggerSummary: String {
        if let threshold = job.when.sizeAbove, matchedBytes < threshold.bytes {
            return "\(ByteCount.format(matchedBytes)) is below the \(threshold) threshold"
        }
        if eligibleBytes == 0 { return "Nothing matches the job's conditions" }
        return "\(ByteCount.format(eligibleBytes)) ready to clean"
    }
}

public struct JobRunResult: Sendable {
    public enum Action: Sendable {
        case notTriggered(String)
        case observed
        case suggested(Suggestion)
        case cleaned(CleanupReport)
        case failed(String)
    }

    public var job: Job
    public var date: Date
    public var evaluation: JobEvaluation?
    public var action: Action
    /// Set when the run happened but its job state couldn't be saved, so the agent may run the job again.
    public var recordError: String?

    public var summary: String {
        switch action {
        case .notTriggered(let reason): return "Skipped — \(reason)"
        case .observed: return "Observed \(ByteCount.format(evaluation?.matchedBytes ?? 0))"
        case .suggested(let suggestion): return "Suggested cleanup of \(ByteCount.format(suggestion.plan.totalBytes)) (id \(suggestion.id))"
        case .cleaned(let report): return ([report.summary] + report.problemNotes).joined(separator: ", ")
        case .failed(let message): return "Failed — \(message)"
        }
    }
}

extension CleanupReport {
    /// "2 items skipped", "1 command failed": everything a run left undone, for summaries and notifications.
    var problemNotes: [String] {
        func note(_ count: Int, _ noun: String, _ what: String) -> String? {
            count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s") \(what)" : nil
        }
        let skippedCommands = commands.filter(\.outcome.isSkipped).count
        let failedCommands = commands.filter(\.outcome.isFailed).count
        return [
            note(skipped.count, "item", "skipped"), note(failures.count, "item", "failed"),
            note(skippedCommands, "command", "skipped"), note(failedCommands, "command", "failed"),
        ].compactMap { $0 }
    }
}

/// Evaluates and runs jobs. Used by the background agent (`spacekit agent run`), the CLI and the app.
public struct JobRunner: Sendable {
    public var context: SpaceKitContext
    public var executor: CleanupExecutor
    /// Automatic runs that removed or left something always notify; observe and suggest runs only when
    /// `automation.notifications` is on.
    public var notifier: Notifier

    public init(context: SpaceKitContext, executor: CleanupExecutor? = nil, notifier: Notifier = AppleScriptNotifier()) {
        self.context = context
        self.executor = executor ?? context.executor
        self.notifier = notifier
    }

    /// Rules a job refers to that exist, plus a synthetic rule for its own folders.
    public func rules(for job: Job) -> (rules: [Rule], missing: [String]) {
        var rules: [Rule] = []
        var missing: [String] = []
        for id in job.rules {
            if let rule = context.library.rule(id: id) { rules.append(rule) } else { missing.append(id) }
        }
        return (rules, missing)
    }

    /// The synthetic rule for a job's own folders. Its items carry no rule id, so the safety guard treats
    /// them as user-chosen folders with the stricter checks that implies.
    static func customRuleID(_ job: Job) -> String { "job:\(job.id)" }

    public func evaluate(_ job: Job, progress: ScanProgress = ScanProgress(), now: Date = Date()) throws -> JobEvaluation {
        let scanned = Date()
        var (rules, _) = rules(for: job)
        if !job.paths.isEmpty {
            rules.append(
                Rule(
                    id: JobRunner.customRuleID(job), name: job.name, group: "Custom", category: "personal.custom",
                    paths: job.paths, granularity: job.granularity, safety: SafetySpec(level: .review),
                    action: ActionSpec(remove: true)))
        }
        guard !rules.isEmpty else { return JobEvaluation(job: job, findings: [], eligible: []) }
        let analysis = try context.analyzer.analyzeSync(rules: rules, progress: progress)
        let eligible = analysis.findings.compactMap { finding -> Finding? in
            let items = finding.eligibleItems(olderThan: job.when.olderThan, keepRecent: job.when.keepRecent, now: now)
            return items.isEmpty ? nil : Finding(rule: finding.rule, items: items)
        }
        return JobEvaluation(job: job, findings: analysis.findings, eligible: eligible, scanned: scanned)
    }

    public func plan(for evaluation: JobEvaluation) -> CleanupPlan {
        var plan = CleanupPlan.make(
            findings: evaluation.eligible, trashPreference: context.trashPreference(for: evaluation.job.action),
            created: evaluation.scanned)
        let customID = JobRunner.customRuleID(evaluation.job)
        for index in plan.items.indices where plan.items[index].ruleID == customID {
            plan.items[index].ruleID = nil
        }
        return plan
    }

    public func automationContext(for job: Job) -> AutomationContext {
        // With `action: rule` the plan trashes whenever the job's own folders contribute items, because their
        // synthetic rule keeps `safety.trash` on; those are the only items the guard asks this about.
        AutomationContext(
            jobID: job.id, allowReview: job.includeReview, customPaths: job.paths,
            olderThan: job.when.olderThan, usesTrash: context.trashPreference(for: job.action) ?? true)
    }

    /// Runs one job according to its mode. `manual` runs (from the app or `spacekit jobs run --yes`) clean
    /// immediately regardless of mode, because a person asked for it. Pass `confirmed: true` only after that
    /// person has seen and accepted the guard's warnings; otherwise items that need confirmation are skipped.
    public func run(_ job: Job, manual: Bool = false, confirmed: Bool = false, dryRun: Bool = false, now: Date = Date()) -> JobRunResult {
        var result: JobRunResult
        do {
            let evaluation = try evaluate(job, now: now)
            let action: JobRunResult.Action
            if !evaluation.isTriggered {
                action = .notTriggered(evaluation.triggerSummary)
            } else if manual {
                action = .cleaned(executor.execute(plan(for: evaluation), context: .manual(confirmed: confirmed), dryRun: dryRun))
            } else {
                action = scheduledAction(job, evaluation: evaluation, dryRun: dryRun, now: now)
            }
            result = JobRunResult(job: job, date: now, evaluation: evaluation, action: action)
        } catch {
            result = JobRunResult(job: job, date: now, evaluation: nil, action: .failed(error.localizedDescription))
        }
        if !dryRun {
            do {
                try record(result)
            } catch {
                result.recordError = "Couldn't save the job's state: \(error.localizedDescription)"
            }
        }
        return result
    }

    /// What a triggered job does on schedule, by mode.
    private func scheduledAction(_ job: Job, evaluation: JobEvaluation, dryRun: Bool, now: Date) -> JobRunResult.Action {
        let notify = !dryRun && context.config.automation.notifications
        switch job.mode {
        case .observe:
            if notify {
                notifier.notify(
                    title: "\(job.name) is \(ByteCount.format(evaluation.matchedBytes))",
                    body: job.when.sizeAbove.map { "Above your \($0) threshold. Open SpaceKit to review." } ?? "Open SpaceKit to review.")
            }
            return .observed
        case .suggest:
            let suggestion = Suggestion(jobID: job.id, jobName: job.name, plan: plan(for: evaluation), created: now)
            if !dryRun {
                do {
                    try context.suggestions.add(suggestion)
                } catch {
                    return .failed("Couldn't save the suggestion: \(error.localizedDescription)")
                }
            }
            if notify {
                notifier.notify(
                    title: "Cleanup ready: \(ByteCount.format(suggestion.plan.totalBytes))",
                    body: "\(job.name) — review in SpaceKit, or run: spacekit suggestions approve \(suggestion.id)")
            }
            return .suggested(suggestion)
        case .automatic:
            let report = executor.execute(plan(for: evaluation), context: .automatic(automationContext(for: job)), dryRun: dryRun)
            // Removals happen without anyone watching, so they are always announced, whatever the setting.
            let notes = report.problemNotes
            if !dryRun && (report.freedBytes > 0 || !notes.isEmpty) {
                notifier.notify(title: "SpaceKit: \(report.summary)", body: ([job.name] + notes).joined(separator: " · "))
            }
            return .cleaned(report)
        }
    }

    /// Saves when the job ran and what it found, so its schedule moves on. Front ends that run a job
    /// themselves call this too.
    public func record(_ result: JobRunResult) throws {
        try context.jobStates.update(result.job.id) { state in
            state.lastRun = result.date
            state.lastOutcome = result.summary
            state.lastMatchedBytes = result.evaluation?.matchedBytes
            state.lastEligibleBytes = result.evaluation?.eligibleBytes
        }
    }

    // MARK: Scheduling

    /// When each enabled job runs next.
    public func nextRuns(now: Date = Date()) -> [(job: Job, date: Date)] {
        let states = context.jobStates.load()
        return context.config.jobs.filter(\.enabled).map { job in
            let state = states[job.id]
            let anchor = state?.lastRun ?? state?.firstSeen ?? now
            return (job, job.schedule.nextRun(after: anchor))
        }
        .sorted { $0.date < $1.date }
    }

    /// Jobs whose next run time has passed (catching up after sleep). Jobs seen for the first time are
    /// remembered and run on their next scheduled time.
    public func dueJobs(now: Date = Date()) throws -> [Job] {
        var due: [Job] = []
        try context.jobStates.modify { states in
            for job in context.config.jobs where job.enabled {
                guard let state = states[job.id] else {
                    states[job.id] = JobState(firstSeen: now)
                    continue
                }
                if job.schedule.nextRun(after: state.lastRun ?? state.firstSeen) <= now { due.append(job) }
            }
        }
        return due
    }

    /// The agent's entry point: run due jobs, record a usage sample, and take a snapshot if one is due.
    /// Nothing runs while job state can't be saved; otherwise every wake-up would repeat the same jobs.
    public func runDue(now: Date = Date(), log: (String) -> Void = { _ in }) -> [JobRunResult] {
        if let capacity = VolumeCapacity.of(path: "/") {
            try? context.history.recordVolumeSample(capacity, now: now)
        }
        let due: [Job]
        do {
            due = try dueJobs(now: now)
        } catch {
            log("Not running jobs: couldn't save job state (\(error.localizedDescription))")
            return []
        }
        var results: [JobRunResult] = []
        for job in due {
            log("Running \(job.id) (\(job.mode.rawValue))")
            let result = run(job, now: now)
            log("  \(result.summary)")
            if let problem = result.recordError { log("  \(problem)") }
            results.append(result)
        }
        if let schedule = context.config.automation.snapshot {
            let last = context.history.lastSnapshotDate()
            if last == nil || schedule.nextRun(after: last!) <= now {
                log("Taking storage snapshot")
                if let analysis = try? context.analyzer.analyzeSync() {
                    try? context.history.recordSnapshot(analysis: analysis, now: now)
                }
            }
        }
        return results
    }

    /// Range of space the next scheduled automatic runs are expected to free, from the last evaluation of each job.
    public func estimatedRecovery(states: [String: JobState]? = nil) -> (low: UInt64, high: UInt64) {
        let states = states ?? context.jobStates.load()
        var low: UInt64 = 0
        var high: UInt64 = 0
        for job in context.config.jobs where job.enabled && job.mode != .observe {
            guard let state = states[job.id] else { continue }
            let eligible = state.lastEligibleBytes ?? 0
            let matched = state.lastMatchedBytes ?? 0
            let triggered = job.when.sizeAbove.map { matched >= $0.bytes } ?? true
            if triggered { low &+= eligible }
            high &+= max(eligible, matched)
        }
        return (low, high)
    }
}
