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
        if let error = context.configError {
            Output.warn("The config file is invalid, so nothing was saved. Fix it first (spacekit config validate): \(Output.safe(error))")
            throw ExitCode.failure
        }
        try context.configStore.update(change)
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
            if json {
                try Output.json(
                    EvaluationJSON(
                        job: job, matchedBytes: evaluation.matchedBytes, eligibleBytes: evaluation.eligibleBytes,
                        triggered: evaluation.isTriggered, status: evaluation.triggerSummary, missingRules: runner.rules(for: job).missing,
                        plan: PlanJSON(plan: plan, executor: runner.executor, context: automation)))
                return
            }
            JobsCommand.warnMissingRules(job, runner: runner)
            Output.emit(JobsCommand.summaryLines(job, evaluation))
            Output.emit(CleanupOutput.planLines(plan, executor: runner.executor, context: automation, limit: 25))
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
                let verdict = context.safetyGuard.evaluate(path: PathUtil.join(PathUtil.expand(folder), "item"), context: automation)
                if verdict.isBlocked {
                    Output.warn(Output.safe("Automatic runs won't clean inside \(folder): \(verdict.reasons.joined(separator: "; "))"))
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

    /// Saves a run's outcome so the job's schedule moves on; a failure to save is reported, not swallowed.
    static func record(_ result: JobRunResult, runner: JobRunner) -> Bool {
        do {
            try runner.record(result)
            return true
        } catch {
            Output.warn(Output.safe("Couldn't save the job's state: \(error.localizedDescription)"))
            return false
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a job now. Previews by default; --yes cleans; --scheduled behaves exactly like the agent would.",
            discussion: """
                Without --scheduled the job cleans now, whatever its mode, with the checks of a cleanup you start yourself:
                the preview lists what will go and any warnings, and --yes confirms them. The exit status is nonzero when
                anything failed or a warning was raised.
                """
        )
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Flag(name: [.short, .long], help: "Clean now, accepting the warnings in the preview.") var yes = false
        @Flag(name: .long, help: "Follow the job's mode (observe/suggest/automatic) like a scheduled run.") var scheduled = false

        func run() throws {
            let context = global.loadContext()
            let job = try JobsCommand.find(id, in: context)
            let runner = JobRunner(context: context)
            if scheduled {
                try runScheduled(job, runner: runner)
                return
            }
            JobsCommand.warnMissingRules(job, runner: runner)
            let evaluation = try ProgressReporter.run("Evaluating \(Output.safe(job.name))") { try runner.evaluate(job, progress: $0) }
            Output.emit(JobsCommand.summaryLines(job, evaluation))
            guard evaluation.isTriggered else {
                if yes && !JobsCommand.record(.manual(evaluation, report: nil), runner: runner) { throw ExitCode(1) }
                return
            }
            guard
                let report = try CleanupOutput.session(
                    runner.plan(for: evaluation), executor: runner.executor, yes: yes, json: false, interactive: false,
                    heading: "What this run removes",
                    hint: "Preview only. Run with --yes to clean now, or --scheduled to run it the way the agent would.")
            else { return }
            let recorded = JobsCommand.record(.manual(evaluation, report: report), runner: runner)
            try CleanupOutput.exitIfProblems(report)
            if !recorded { throw ExitCode(1) }
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
                for item in suggestion.plan.items.sorted(by: { $0.size > $1.size }).prefix(5) {
                    print("    " + Output.size(item.size) + "  " + Output.path(item.path).dim)
                }
                if suggestion.plan.items.count > 5 { print("    … \(suggestion.plan.items.count - 5) more".dim) }
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
                job's age conditions, are dropped. The suggestion is kept unless the run removed something and nothing
                failed. The exit status is nonzero when anything failed or a warning was raised.
                """
        )
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Flag(name: [.short, .long], help: "Run the cleanup, accepting the warnings in the preview.") var yes = false
        @Flag(name: .long, help: "Machine-readable plan and result on stdout; the preview goes to stderr.") var json = false

        func run() throws {
            let context = global.loadContext()
            let suggestion = try SuggestionsCommand.find(id, in: context)
            guard let job = context.config.jobs.first(where: { $0.id == suggestion.jobID }) else {
                throw ValidationError(
                    "The job that prepared this suggestion (\(Output.safe(suggestion.jobID))) is no longer in your config, so its conditions can't be "
                        + "checked. Dismiss it: spacekit suggestions dismiss \(Output.safe(suggestion.id))")
            }
            let runner = JobRunner(context: context)
            let evaluation = try ProgressReporter.run("Checking \(Output.safe(job.name))") { try runner.evaluate(job, progress: $0) }
            let (plan, dropped) = suggestion.plan.keeping(onlyEligible: evaluation.eligible)
            var notes = [
                Output.safe(suggestion.jobName).bold + "  ·  " + "prepared \(suggestion.created.relativeDescription())".dim
            ]
            notes += dropped.map { "  no longer eligible: ".dim + Output.path($0.path) }
            Output.emit(notes, toStandardError: json)
            guard !plan.isEmpty else {
                let dismiss = "spacekit suggestions dismiss \(Output.safe(suggestion.id))"
                Output.emit(
                    ["Nothing in this suggestion still matches the job's conditions. Dismiss it: " + dismiss], toStandardError: json)
                if json {
                    try Output.json(RunJSON(plan: PlanJSON(plan: plan, executor: runner.executor, context: .manual(confirmed: false))))
                }
                return
            }
            guard
                let report = try CleanupOutput.session(
                    plan, executor: runner.executor, yes: yes, json: json, interactive: false, heading: "Suggested cleanup",
                    hint: "Preview only. Approve with: spacekit suggestions approve \(Output.safe(suggestion.id)) --yes")
            else { return }
            let recorded = JobsCommand.record(.manual(evaluation, report: report), runner: runner)
            if report.removedAnything && !report.hasProblems {
                try context.suggestions.remove(suggestion.id)
            } else {
                Output.emit(["Kept the suggestion, so you can try again or dismiss it."], toStandardError: json)
            }
            try CleanupOutput.exitIfProblems(report)
            if !recorded { throw ExitCode(1) }
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
