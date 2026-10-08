import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

struct JobsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs",
        abstract: "Scheduled cleanups: observe, suggest or clean automatically.",
        subcommands: [List.self, Show.self, Add.self, Remove.self, Enable.self, Disable.self, Run.self, Next.self],
        defaultSubcommand: List.self
    )

    static func find(_ id: String, in context: SpaceKitContext) throws -> Job {
        guard let job = context.config.jobs.first(where: { $0.id == id }) else { throw noJob(id) }
        return job
    }

    static func noJob(_ id: String) -> ValidationError { ValidationError("No job '\(Output.safe(id))'. See `spacekit jobs list`.") }

    /// Changes the config file as it is on disk now. A file that doesn't parse is never replaced: saving the
    /// defaults loaded in its place would drop protected paths, allowed commands and disabled rules.
    static func updateConfig(_ context: SpaceKitContext, _ change: (inout SpaceKitConfig) throws -> Void) throws {
        do {
            _ = try context.applying(change)
        } catch let error as ConfigError {
            Output.warn(
                "The config file is invalid, so nothing was saved. Fix it first (spacekit config validate): "
                    + Output.safe(error.localizedDescription))
            throw ExitCode.failure
        }
    }

    /// The job, what it matched now and whether it would run.
    static func summaryLines(_ job: Job, _ evaluation: JobEvaluation) -> [String] {
        [
            Output.safe(job.name).bold + "  ·  " + job.mode.title + "  ·  " + job.schedule.description,
            job.conditionSummary.dim,
            "",
            "Matched:   " + ByteCount.format(evaluation.matchedBytes).bold,
            "Eligible:  " + ByteCount.format(evaluation.eligibleBytes).bold + "  (after age conditions)".dim,
            "Status:    " + (evaluation.isTriggered ? "would run — ".fg(ANSI.safe) : "would skip — ".dim) + evaluation.triggerSummary,
            "",
        ]
    }

    static func warnMissingRules(_ job: Job, runner: JobRunner) {
        let missing = runner.rules(for: job).missing
        if !missing.isEmpty { Output.warn("Unknown rules: \(Output.safe(missing.joined(separator: ", ")))") }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List jobs.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            if json {
                try Output.json(context.config.jobs)
                return
            }
            let states = context.jobStates.load()
            let next = Dictionary(JobRunner(context: context).nextRuns().map { ($0.job.id, $0.date) }, uniquingKeysWith: { a, _ in a })
            guard !context.config.jobs.isEmpty else {
                print("No jobs. Add one with `spacekit jobs add --rule xcode.derived-data`, or start from `spacekit config init`.")
                return
            }
            for job in context.config.jobs {
                print(
                    ANSI.pad(job.terminalToggle, to: 6) + " " + ANSI.pad(Output.safe(job.name).bold, to: 32) + ANSI.pad(job.mode.title, to: 11)
                        + ANSI.pad(job.schedule.description, to: 22) + job.nextRunText(next[job.id]).dim)
                print(
                    "       " + "\(Output.safe(job.id))  ·  ".dim + job.conditionSummary.dim
                        + (states[job.id]?.lastOutcome.map { "  ·  last: \(Output.safe($0))" } ?? "").dim)
            }
            let agent = LaunchAgent(paths: context.paths).status()
            if !agent.loaded {
                print()
                print(
                    "The background agent isn't running, so jobs only run when you call them. Install it: ".fg(ANSI.review)
                        + "spacekit agent install".bold)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Evaluate a job now and show what a scheduled run would do.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        struct EvaluationJSON: Encodable {
            var job: Job
            var matchedBytes: UInt64
            var eligibleBytes: UInt64
            var triggered: Bool
            var status: String
            var missingRules: [String]
            /// Verdicts are those of an automatic run.
            var plan: PlanJSON
        }

        func run() throws {
            let context = global.loadContext()
            let job = try JobsCommand.find(id, in: context)
            let runner = JobRunner(context: context)
            let evaluation = try ProgressReporter.run("Evaluating") { try runner.evaluate(job, progress: $0) }
            let plan = runner.plan(for: evaluation)
            let automation = CleanupContext.automatic(runner.automationContext(for: job))
            let verdicts = CleanupOutput.Verdicts(plan, executor: runner.executor, context: automation)
            if json {
                try Output.json(
                    EvaluationJSON(
                        job: job, matchedBytes: evaluation.matchedBytes, eligibleBytes: evaluation.eligibleBytes,
                        triggered: evaluation.isTriggered, status: evaluation.triggerSummary, missingRules: runner.rules(for: job).missing,
                        plan: PlanJSON(verdicts)))
                return
            }
            JobsCommand.warnMissingRules(job, runner: runner)
            Output.emit(JobsCommand.summaryLines(job, evaluation))
            Output.emit(CleanupOutput.planLines(verdicts, limit: 25))
            print()
            print("✓ = a scheduled run may remove it; ✗ = scheduled runs leave it alone (you can still clean it yourself).".dim)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a job to the config.",
            discussion: """
                Examples:
                  spacekit jobs add --rule xcode.derived-data --mode automatic --schedule "sunday 03:00" --size-above 30GB --keep-recent 14d
                  spacekit jobs add --rule node.node-modules --older-than 60d
                  spacekit jobs add --name "Old downloads" --path ~/Downloads --older-than 90d --mode suggest
                """
        )
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Rule id (repeatable).") var rule: [String] = []
        @Option(name: .long, help: "Your own folder to clean (repeatable).") var path: [String] = []
        @Option(name: .long, help: "Job name (default: from the first rule).") var name: String?
        @Option(name: .long, help: "Job id (default: from the name).") var id: String?
        @Option(name: .long, help: "observe, suggest or automatic.") var mode: Job.Mode?
        @Option(name: .long, help: "hourly, daily, weekly, monthly, or e.g. \"sunday 03:00\".", transform: Parse.schedule)
        var schedule: Schedule?
        @Option(name: .long, help: "Only act when the total exceeds this (e.g. 30GB).", transform: Parse.size) var sizeAbove: ByteCount?
        @Option(name: .long, help: "Only items unused at least this long (e.g. 60d).", transform: Parse.retention) var olderThan: Age?
        @Option(name: .long, help: "Keep items used within this window (e.g. 14d).", transform: Parse.retention) var keepRecent: Age?
        @Option(name: .long, help: "trash, delete or rule.") var action: Job.Action = .trash
        @Flag(name: .long, help: "Allow 🟡 review items in automatic runs.") var includeReview = false

        func validate() throws {
            guard !rule.isEmpty || !path.isEmpty else { throw ValidationError("Give at least one --rule or --path") }
        }

        func run() throws {
            let context = global.loadContext()
            var rules: [Rule] = []
            for id in rule {
                guard let found = context.library.rule(id: id) else { throw ValidationError("Unknown rule '\(Output.safe(id))'") }
                guard found.safety.level != .protected else {
                    throw ValidationError("\(Output.safe(found.name)) is protected and can't be cleaned")
                }
                rules.append(found)
            }
            var job = rules.first.map(Job.suggested(for:)) ?? Job(id: "custom", name: name ?? "Custom cleanup")
            job.rules = rules.map(\.id)
            job.paths = path.map { PathUtil.abbreviate(PathUtil.expandArgument($0)) }
            if let name { job.name = name } else if rules.count > 1 { job.name = rules.map(\.name).joined(separator: " + ") }
            job.id = id ?? Rule.slug(job.name)
            if let mode { job.mode = mode } else if !path.isEmpty { job.mode = .suggest }
            if let schedule { job.schedule = schedule }
            if let sizeAbove { job.when.sizeAbove = sizeAbove }
            if let olderThan { job.when.olderThan = olderThan }
            if let keepRecent { job.when.keepRecent = keepRecent }
            job.action = action
            job.includeReview = includeReview

            // Check custom folders against the guard up front.
            let automation = CleanupContext.automatic(JobRunner(context: context).automationContext(for: job))
            for folder in job.paths {
                // Something the job might find inside the folder: only where it would be is known yet.
                let inside = PathUtil.join(PathUtil.expand(folder), "item")
                if let reasons = context.safetyGuard.locationRefusal(of: inside, rule: nil, context: automation) {
                    Output.warn(Output.safe("Automatic runs won't clean inside \(folder): \(reasons.joined(separator: "; "))"))
                }
            }
            var storedID = job.id
            try JobsCommand.updateConfig(context) { storedID = $0.upsertJob(job, replacing: nil) }
            job.id = storedID
            print("Added job " + Output.safe(job.id).bold + ": \(job.mode.title), \(job.schedule). " + job.conditionSummary.dim)
            if job.mode == .automatic && !LaunchAgent(paths: context.paths).status().loaded {
                print("Install the background agent so it runs on schedule: ".fg(ANSI.review) + "spacekit agent install".bold)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a job from the config.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String

        func run() throws {
            let context = global.loadContext()
            try JobsCommand.updateConfig(context) { config in
                guard config.jobs.contains(where: { $0.id == id }) else { throw JobsCommand.noJob(id) }
                config.jobs.removeAll { $0.id == id }
            }
            print("Removed \(Output.safe(id)).")
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a job on.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() throws { try JobsCommand.setEnabled(id, true, global) }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a job off.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() throws { try JobsCommand.setEnabled(id, false, global) }
    }

    static func setEnabled(_ id: String, _ enabled: Bool, _ global: GlobalOptions) throws {
        let context = global.loadContext()
        try updateConfig(context) { config in
            guard let index = config.jobs.firstIndex(where: { $0.id == id }) else { throw noJob(id) }
            config.jobs[index].enabled = enabled
        }
        print("\(Output.safe(id)): \(enabled ? "on" : "off")")
    }

    /// Reviews `run`'s plan with `executor`, the context's, and completes the run with that same executor once the person
    /// said go. `nil` when nothing ran.
    static func complete(
        _ run: ManualJobRun, plan: CleanupPlan, executor: CleanupExecutor, acknowledgement: AcknowledgementOptions, json: Bool,
        heading: String, hint: String
    ) throws -> ManualJobRun.Outcome? {
        try CleanupOutput.session(
            plan, executor: executor, acknowledgement: acknowledgement, json: json, interactive: false, heading: heading, hint: hint,
            run: { run.complete($0, executor: executor) }, report: \.report)
    }

    /// Ends a job run or an approval: what couldn't be saved is warned about, and the exit status is nonzero when the
    /// run left something undone or its state wasn't saved.
    static func finish(_ outcome: ManualJobRun.Outcome) throws {
        for error in outcome.saveErrors { Output.warn(Output.safe(error)) }
        try CleanupOutput.exitIfProblems(outcome.report)
        if !outcome.saveErrors.isEmpty { throw ExitCode(1) }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a job now. Previews by default; --yes cleans; --scheduled behaves exactly like the agent would.",
            discussion: """
                Without --scheduled the job cleans now, whatever its mode, with the checks of a cleanup you start yourself:
                the preview lists what will go and any warnings. --yes runs what the guard allows outright; items with
                warnings also need --accept-warnings. A job below its size threshold is skipped with the reason unless you
                add --force. The run is recorded as the job's last run. The exit status is nonzero when anything failed, a
                row's warnings weren't accepted or a warning was raised.
                """
        )
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @OptionGroup var acknowledgement: AcknowledgementOptions
        @Flag(name: .long, help: "Run it even when the job is below its size threshold.") var force = false
        @Flag(name: .long, help: "Follow the job's mode (observe/suggest/automatic) like a scheduled run.") var scheduled = false

        func validate() throws {
            if force && scheduled {
                throw ValidationError("--force can't be used with --scheduled, which runs the job as the agent would.")
            }
        }

        func run() throws {
            let context = global.loadContext()
            let job = try JobsCommand.find(id, in: context)
            let runner = JobRunner(context: context)
            if scheduled {
                try runScheduled(job, runner: runner)
                return
            }
            JobsCommand.warnMissingRules(job, runner: runner)
            let prepared = try ProgressReporter.run("Evaluating \(Output.safe(job.name))") {
                try ManualJobRun.prepare(job, runner: runner, progress: $0)
            }
            Output.emit(JobsCommand.summaryLines(job, prepared.evaluation))
            let run = force ? prepared.forced() : prepared
            guard let plan = run.plan else {
                if run.canForce { print("Run it anyway with --force.".dim) }
                return
            }
            let outcome = try JobsCommand.complete(
                run, plan: plan, executor: context.executor, acknowledgement: acknowledgement, json: false,
                heading: "What this run removes",
                hint: "Preview only. Run with --yes to clean now, or --scheduled to run it the way the agent would.")
            if let outcome { try JobsCommand.finish(outcome) }
        }

        private func runScheduled(_ job: Job, runner: JobRunner) throws {
            let result = ProgressReporter.run("Running \(Output.safe(job.name))") { _ in runner.run(job) }
            print(Output.safe(result.summary))
            var failed = result.recordError != nil
            switch result.action {
            case .cleaned(let report):
                Output.emit(Array(CleanupOutput.reportLines(report).dropFirst()))
                failed = failed || report.hasProblems
            case .failed:
                failed = true
            case .notTriggered, .observed, .suggested:
                break
            }
            if let problem = result.recordError { Output.warn(Output.safe(problem)) }
            if failed { throw ExitCode(1) }
        }
    }

    struct Next: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "When jobs run next, and how much they're expected to free.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        struct NextJSON: Encodable {
            struct Run: Encodable {
                var job: String
                var name: String
                var date: Date
            }
            var runs: [Run]
            var estimatedLowBytes: UInt64
            var estimatedHighBytes: UInt64
        }

        func run() throws {
            let context = global.loadContext()
            let runner = JobRunner(context: context)
            let runs = runner.nextRuns()
            let estimate = runner.estimatedRecovery()
            if json {
                try Output.json(
                    NextJSON(
                        runs: runs.map { NextJSON.Run(job: $0.job.id, name: $0.job.name, date: $0.date) }, estimatedLowBytes: estimate.low,
                        estimatedHighBytes: estimate.high))
                return
            }
            guard let first = runs.first else {
                print("No enabled jobs.")
                return
            }
            print("Next automatic cleanup".bold)
            print(first.date.formatted(.dateTime.weekday(.wide).hour().minute()) + "  ·  " + Output.safe(first.job.name))
            if estimate.high > 0 {
                print("Estimated recovery: \(ByteCount.format(estimate.low))–\(ByteCount.format(estimate.high))".dim)
            }
            print()
            for run in runs {
                print("  " + ANSI.pad(run.date.formatted(date: .abbreviated, time: .shortened), to: 22) + Output.safe(run.job.name))
            }
        }
    }
}

struct SuggestionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggestions",
        abstract: "Cleanups prepared by `suggest` jobs, waiting for your approval.",
        subcommands: [List.self, Approve.self, Dismiss.self],
        defaultSubcommand: List.self
    )

    static func find(_ id: String, in context: SpaceKitContext) throws -> Suggestion {
        guard let suggestion = context.suggestions.get(id) else {
            throw ValidationError("No suggestion '\(Output.safe(id))'. See `spacekit suggestions`.")
        }
        return suggestion
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List pending suggestions.")
        /// How many of a suggestion's largest items, and of its problems, the list shows before "… N more".
        static let listedItems = 5
        static let listedProblems = 3
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            let suggestions = context.suggestions.all()
            if json {
                try Output.json(suggestions)
                return
            }
            guard !suggestions.isEmpty else {
                print("No pending suggestions.")
                return
            }
            for suggestion in suggestions {
                print(
                    Output.safe(suggestion.id).bold + "  " + Output.safe(suggestion.jobName) + "  "
                        + ByteCount.format(suggestion.plan.totalBytes).bold + "  "
                        + "prepared \(suggestion.created.relativeDescription())".dim)
                let items = Excerpt(suggestion.plan.items.sorted(by: { $0.size > $1.size }), first: Self.listedItems)
                for item in items.shown { print("    " + Output.size(item.size) + "  " + Output.path(item.path).dim) }
                if let more = items.moreText() { print("    … \(more)".dim) }
                let problems = Excerpt(suggestion.problems, first: Self.listedProblems)
                for problem in problems.shown { print("    ! ".fg(ANSI.review) + Output.safe(problem).dim) }
                if let more = problems.moreText("problems") { print("    … \(more)".dim) }
            }
            print()
            print("Preview one with `spacekit suggestions approve <id>`, or dismiss it with `spacekit suggestions dismiss <id>`.".dim)
        }
    }

    struct Approve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Preview a suggested cleanup; run it with --yes.",
            discussion: """
                The job is evaluated again first: items used since the suggestion was made, or no longer matching the
                job's age conditions, are dropped. --yes runs what the guard allows outright; items with warnings also
                need --accept-warnings. Approving records the job's last run. Afterwards the suggestion is dismissed when
                nothing in it is left to clean (also when nothing in it still met the job's conditions, so nothing ran);
                otherwise it's kept with what's left and the problems the run hit. The exit status is nonzero when anything
                failed, a row's warnings weren't accepted or a warning was raised.
                """
        )
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @OptionGroup var acknowledgement: AcknowledgementOptions
        @Flag(name: .long, help: "Machine-readable plan and result on stdout; the preview goes to stderr.") var json = false

        func run() throws {
            let context = global.loadContext()
            let suggestion = try SuggestionsCommand.find(id, in: context)
            let runner = JobRunner(context: context)
            let dismiss = "spacekit suggestions dismiss \(Output.safe(suggestion.id))"
            let run: ManualJobRun
            do {
                run = try ProgressReporter.run("Checking \(Output.safe(suggestion.jobName))") {
                    try ManualJobRun.prepare(suggestion, runner: runner, progress: $0)
                }
            } catch let missing as ManualJobRun.JobMissing {
                throw ValidationError(Output.safe(missing.localizedDescription) + " Run: " + dismiss)
            }
            var notes = [
                Output.safe(suggestion.jobName).bold + "  ·  " + "prepared \(suggestion.created.relativeDescription())".dim
            ]
            notes += run.dropped.map { "  no longer eligible: ".dim + Output.path($0.path) }
            Output.emit(notes, toStandardError: json)
            guard let plan = run.plan else {
                try settleNothingLeft(run, suggestion: suggestion, executor: context.executor, dismiss: dismiss)
                return
            }
            guard
                let outcome = try JobsCommand.complete(
                    run, plan: plan, executor: context.executor, acknowledgement: acknowledgement, json: json,
                    heading: "Suggested cleanup",
                    hint: "Preview only. Approve with: spacekit suggestions approve \(Output.safe(suggestion.id)) --yes")
            else { return }
            Output.emit(Self.fateLines(outcome.fate), toStandardError: json)
            try JobsCommand.finish(outcome)
        }

        /// Nothing in the suggestion still meets its job's conditions, or the guard blocks all of it. Approving it (`--yes`)
        /// runs nothing, records the job's run and dismisses it; the plan printed is the suggestion's own, with nothing left
        /// in it but the blocked rows, each with its verdict and reasons.
        private func settleNothingLeft(_ run: ManualJobRun, suggestion: Suggestion, executor: CleanupExecutor, dismiss: String) throws {
            let reason = Output.safe(run.skipReason ?? "")
            var left = suggestion.plan
            left.items = run.blockedRows.items
            left.commands = run.blockedRows.commands
            let plan = PlanJSON(CleanupReview(left, executor: executor))
            guard acknowledgement.yes, let outcome = run.settleWithNothingLeft() else {
                Output.emit([reason + ". Approving it with --yes dismisses it, as does: " + dismiss], toStandardError: json)
                if json { try Output.json(RunJSON(plan: plan)) }
                return
            }
            Output.emit([reason + "."] + Self.fateLines(outcome.fate), toStandardError: json)
            if json { try Output.json(RunJSON(plan: plan, result: ReportJSON(outcome.report))) }
            try JobsCommand.finish(outcome)
        }

        private static func fateLines(_ fate: ManualJobRun.SuggestionFate?) -> [String] {
            switch fate {
            case .kept(let kept):
                let count = kept.plan.items.count + kept.plan.commands.count
                return ["Kept the suggestion with \(count) left to clean, so you can try again or dismiss it."]
            case .dismissed: return ["Dismissed the suggestion: nothing in it is left to clean."]
            case .gone: return ["The suggestion was dismissed or replaced while this ran, so it's left as it is now."]
            case nil: return []
            }
        }
    }

    struct Dismiss: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard a suggestion.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String

        func run() throws {
            let context = global.loadContext()
            let suggestion = try SuggestionsCommand.find(id, in: context)
            try context.suggestions.remove(suggestion.id)
            print("Dismissed.")
        }
    }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "The background agent that runs jobs on schedule (a per-user launchd job).",
        subcommands: [Run.self, Install.self, Uninstall.self, Status.self],
        defaultSubcommand: Status.self
    )

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run due jobs once (what launchd calls).")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            try context.paths.ensureDirectories()
            let stamp = Date().ISO8601Format()
            print("[\(stamp)] agent run")
            let results = JobRunner(context: context).runDue { print("[\(stamp)] \(Output.safe($0))") }
            if results.isEmpty { print("[\(stamp)] no jobs due") }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install and start the background agent.",
            discussion: "The agent uses the config this command uses (--config or $SPACEKIT_CONFIG) and the same state folder."
        )
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Check interval, 5m to 24h (default: automation.checkEvery, 1h).", transform: Parse.age) var every: Age?

        func run() throws {
            let context = global.loadContext()
            let requested = every ?? context.config.automation.checkEvery
            guard let executable = LaunchAgent.spacekitExecutable() else {
                throw ValidationError("Can't locate the spacekit executable")
            }
            if LaunchAgent.isDevelopmentBuild(executable) {
                Output.warn(
                    "Installing an agent that points at a development build (\(Output.safe(executable))). "
                        + "Run `make install` for a stable path.")
            }
            let seconds = try LaunchAgent(paths: context.paths).install(executable: executable, interval: requested.seconds)
            let interval = Age(seconds: TimeInterval(seconds))
            print(
                "Background agent installed: checks for due jobs every \(interval)"
                    + (interval == requested ? "." : " (\(requested) is outside the allowed 5m to 24h)."))
            print("Config: \(Output.path(context.paths.configFile))".dim)
            print("Logs: \(Output.path(context.paths.logDirectory + "/agent.log"))".dim)
            print(
                ("To scan protected folders it needs Full Disk Access: System Settings → Privacy & Security → Full Disk Access → add "
                    + "\(Output.safe(executable)).").dim)
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and remove the background agent.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            try LaunchAgent(paths: global.loadContext().paths).uninstall()
            print("Background agent removed. Jobs stay in your config.")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the agent is installed and running.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        struct StatusJSON: Encodable {
            var installed: Bool
            var loaded: Bool
            var executable: String?
            var intervalSeconds: Int?
            var nextJob: String?
            var nextRun: Date?
        }

        func run() throws {
            let context = global.loadContext()
            let status = LaunchAgent(paths: context.paths).status()
            let next = JobRunner(context: context).nextRuns().first
            if json {
                try Output.json(
                    StatusJSON(
                        installed: status.installed, loaded: status.loaded, executable: status.executable, intervalSeconds: status.interval,
                        nextJob: next?.job.id, nextRun: next?.date))
                return
            }
            print("Installed: " + (status.installed ? "yes".fg(ANSI.safe) : "no".fg(ANSI.review)))
            print("Loaded:    " + (status.loaded ? "yes".fg(ANSI.safe) : "no".fg(ANSI.review)))
            if let executable = status.executable { print("Program:   \(Output.safe(executable))") }
            if let interval = status.interval { print("Interval:  \(Age(seconds: TimeInterval(interval)))") }
            if let next { print("Next job:  \(Output.safe(next.job.name)), \(next.date.relativeDescription())") }
        }
    }
}
