import Foundation
import SpaceKitCore

/// What the Automation view shows. Reading it asks launchd and reads the journal, so it's gathered when the
/// view opens and after changes, not on every frame.
struct AutomationSnapshot {
    var recovered: UInt64
    var states: [String: JobState]
    var nextRuns: [(job: Job, date: Date)]
    var agent: LaunchAgent.Status
    var estimate: (low: UInt64, high: UInt64)
}

/// What the History view shows, read from the history file when the view opens.
struct HistorySnapshot {
    var days: [(date: Date, used: UInt64, total: UInt64)]
    var monthDelta: Int64?
    var grew: [GrowthItem]
}

struct TUIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

extension TUIApp {
    func refreshAutomation() {
        let runner = JobRunner(context: context)
        let states = context.jobStates.load()
        state.automation = AutomationSnapshot(
            recovered: context.journal.recovered(since: Age.days(90).ago()),
            states: states, nextRuns: runner.nextRuns(), agent: LaunchAgent(paths: context.paths).status(),
            estimate: runner.estimatedRecovery(states: states))
    }

    func refreshHistory() {
        let history = context.history
        state.history = HistorySnapshot(
            days: history.dailyUsage(days: 120), monthDelta: history.usedDelta(over: .days(30)),
            grew: history.whatGrew(over: .days(90)))
    }

    func handleJobs(_ key: TerminalKey) {
        if key == .character("i") {
            toggleAgent()
            return
        }
        let jobs = context.config.jobs
        guard !jobs.isEmpty else { return }
        let index = min(state.jobSelection, jobs.count - 1)
        let job = jobs[index]
        let name = TerminalText.sanitize(job.name)
        switch key {
        case .up, .character("k"): state.jobSelection = max(0, index - 1)
        case .down, .character("j"): state.jobSelection = min(jobs.count - 1, index + 1)
        case .character("e"), .space:
            let enabled = !job.enabled
            saveConfig("\(name): \(enabled ? "enabled" : "disabled")") { config in
                try TUIApp.withJob(job.id, in: &config) { $0.enabled = enabled }
            }
        case .character("m"):
            let modes = Job.Mode.allCases
            let next = modes[((modes.firstIndex(of: job.mode) ?? 0) + 1) % modes.count]
            saveConfig("\(name): \(next.title) — \(next.explanation)") { config in
                try TUIApp.withJob(job.id, in: &config) { $0.mode = next }
            }
        case .character("x"), .enter:
            guard !refuseWhileBusy() else { return }
            evaluate(job)
        default:
            break
        }
    }

    func createJob(for rule: Rule) {
        let name = TerminalText.sanitize(rule.name)
        guard !context.config.jobs.contains(where: { $0.rules == [rule.id] }) else {
            flash("A job for \(name) already exists")
            return
        }
        guard rule.safety.level != .protected, rule.action.isCleanable else {
            flash("\(name) can't be cleaned automatically")
            return
        }
        let job = Job.suggested(for: rule)
        saveConfig("Created job “\(name)” (\(job.mode.rawValue), \(job.schedule)) — see Automation") { config in
            config.upsertJob(job, replacing: nil)
        }
    }

    static func withJob(_ id: String, in config: inout SpaceKitConfig, _ change: (inout Job) -> Void) throws {
        guard let index = config.jobs.firstIndex(where: { $0.id == id }) else {
            throw TUIError(message: "Job \(id) is no longer in the config file")
        }
        change(&config.jobs[index])
    }

    /// Applies `change` to the config file as it is on disk now, not to the copy loaded at start, which would
    /// drop jobs added elsewhere since. Refuses while the file is invalid: saving would replace it with defaults.
    func saveConfig(_ message: String, _ change: (inout SpaceKitConfig) throws -> Void) {
        do {
            if let error = context.configError {
                throw TUIError(message: "Config file is invalid: \(error). Fix it (spacekit config validate) first")
            }
            context.config = try context.configStore.update(change)
            flash(message)
        } catch {
            flash("Couldn't save config: \(TerminalText.sanitize(error.localizedDescription))")
        }
        refreshAutomation()
    }

    // MARK: Running a job

    func evaluate(_ job: Job) {
        state.activity = .evaluating(TerminalText.sanitize(job.name))
        let (runner, inbox) = (JobRunner(context: context), inbox)
        Thread.detachNewThread {
            let result = Result { () throws -> (JobEvaluation, CleanupPlan) in
                let evaluation = try runner.evaluate(job)
                return (evaluation, runner.plan(for: evaluation))
            }
            inbox.post(.evaluated(job, result))
        }
    }

    func jobEvaluated(_ job: Job, _ result: Result<(JobEvaluation, CleanupPlan), Error>) {
        state.activity = nil
        let name = TerminalText.sanitize(job.name)
        switch result {
        case .failure(let error):
            state.modal = Modal(title: name, lines: [TerminalText.sanitize(error.localizedDescription)])
        case .success(let (evaluation, plan)):
            guard evaluation.isTriggered, !plan.isEmpty else {
                var lines = [TerminalText.sanitize(evaluation.triggerSummary)]
                if let problem = record(evaluation, report: nil) { lines.append(problem.fg(ANSI.protected)) }
                refreshAutomation()
                state.modal = Modal(title: name, lines: lines)
                return
            }
            confirmCleanup(plan, title: "Run “\(name)” now", job: evaluation)
        }
    }

    /// Saves the run the way `JobRunner.run` would, so the job's schedule moves on and the Automation view
    /// shows the outcome. Returns the problem if the state couldn't be saved.
    func record(_ evaluation: JobEvaluation, report: CleanupReport?) -> String? {
        do {
            try JobRunner(context: context).record(.manual(evaluation, report: report))
            return nil
        } catch {
            return "Couldn't save the job's state: \(TerminalText.sanitize(error.localizedDescription))"
        }
    }

    // MARK: Background agent

    func toggleAgent() {
        let agent = LaunchAgent(paths: context.paths)
        defer { refreshAutomation() }
        if agent.status().installed {
            do {
                try agent.uninstall()
                flash("Background agent removed")
            } catch {
                flash("Couldn't remove the agent: \(TerminalText.sanitize(error.localizedDescription))")
            }
            return
        }
        guard let executable = LaunchAgent.spacekitExecutable() else {
            flash("Can't locate the spacekit executable")
            return
        }
        do {
            let seconds = try agent.install(executable: executable, interval: context.config.automation.checkEvery.seconds)
            var lines = [
                "Checks for due jobs every \(Age(seconds: TimeInterval(seconds))).", "Runs: " + TerminalText.sanitize(executable),
            ]
            if LaunchAgent.isDevelopmentBuild(executable) {
                lines.append("That's a development build. Run `make install` for a stable path, then install again.".fg(ANSI.review))
            }
            lines += [
                "", "To scan protected folders it needs Full Disk Access: System Settings → Privacy & Security".dim,
                "→ Full Disk Access → add the executable above.".dim,
            ]
            state.modal = Modal(title: "Background agent installed", lines: lines)
        } catch {
            flash("Couldn't install agent: \(TerminalText.sanitize(error.localizedDescription))")
        }
    }
}
