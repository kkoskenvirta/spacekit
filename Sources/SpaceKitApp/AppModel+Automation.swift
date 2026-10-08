import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Automation

    var jobRunner: JobRunner { JobRunner(context: context) }

    /// Evaluates a job in the background and opens the review sheet with its plan. A job whose conditions aren't
    /// met doesn't run, as in the CLI and the TUI: the check is recorded and its result shown.
    func previewJob(_ job: Job) {
        let runner = jobRunner
        Task {
            switch await self.evaluate(job, with: runner) {
            case .success(let evaluation):
                let plan = runner.plan(for: evaluation)
                guard evaluation.isTriggered, !plan.isEmpty else {
                    self.errorMessage = "\(job.name): \(evaluation.triggerSummary)."
                    self.record(evaluation, report: nil, with: runner)
                    return
                }
                self.review(plan, title: "Run “\(job.name)” now") { report in
                    self.record(evaluation, report: report, with: runner)
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Saves a manual run so the job's schedule moves on, as `JobRunner.run` would.
    private func record(_ evaluation: JobEvaluation, report: CleanupReport?, with runner: JobRunner) {
        do {
            try runner.record(.manual(evaluation, report: report))
        } catch {
            errorMessage = "Couldn't save the job's state: \(error.localizedDescription)"
        }
        refreshJournal()
    }

    /// Re-evaluates the suggestion's job first, so only items that still meet its conditions are offered (a project
    /// used since it was prepared drops out). The run is recorded against the job, as in the CLI, and the suggestion
    /// is removed only when the cleanup removed something and had no problems.
    func approve(_ suggestion: Suggestion) {
        guard let job = config.jobs.first(where: { $0.id == suggestion.jobID }) else {
            errorMessage = "The job “\(suggestion.jobName)” that prepared this cleanup no longer exists. Dismiss the suggestion."
            return
        }
        let runner = jobRunner
        Task {
            switch await self.evaluate(job, with: runner) {
            case .success(let evaluation):
                let plan = suggestion.plan.keeping(onlyEligible: evaluation.eligible).plan
                guard !plan.isEmpty else {
                    self.errorMessage = "Nothing in “\(suggestion.jobName)” needs cleaning any more: it was used or removed since."
                    return
                }
                self.review(plan, title: "Approve “\(suggestion.jobName)”") { report in
                    self.record(evaluation, report: report, with: runner)
                    if report.removedAnything && !report.hasProblems { self.dismiss(suggestion) }
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func dismiss(_ suggestion: Suggestion) {
        do {
            try context.suggestions.remove(suggestion.id)
        } catch {
            errorMessage = "Couldn't remove the suggestion: \(error.localizedDescription)"
        }
        refreshJournal()
    }

    func installAgent() {
        guard let executable = LaunchAgent.spacekitExecutable() else {
            errorMessage =
                "Couldn't find the spacekit command-line tool. Build it with `make install`, or use the app bundle from `make app`."
            return
        }
        do {
            try LaunchAgent(paths: context.paths).install(executable: executable, interval: context.config.automation.checkEvery.seconds)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAutomation()
    }

    func uninstallAgent() {
        do {
            try LaunchAgent(paths: context.paths).uninstall()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAutomation()
    }

    /// Saves a job: in place of the job `id` when editing, otherwise as a new job whose id doesn't clash with another.
    func saveJob(_ job: Job, replacing id: String? = nil) {
        updateConfig { $0.upsertJob(job, replacing: id) }
    }

    func deleteJob(_ job: Job) {
        updateConfig { $0.jobs.removeAll { $0.id == job.id } }
    }
}

/// A job being created or edited in the job editor.
struct JobDraft: Identifiable {
    let id = UUID()
    var job: Job
    /// The id of the job being edited, or nil for a new job.
    var originalID: String?
}

extension JobDraft {
    /// A new job for folders chosen in Explore.
    init(paths: [String]) {
        let name = paths.count == 1 ? "Clean \(PathUtil.lastComponent(paths[0]))" : "Clean \(paths.count) folders"
        self.init(
            job: Job(
                id: Rule.slug(name), name: name, paths: paths.map { PathUtil.abbreviate($0) }, mode: .suggest,
                schedule: .weekly, when: Job.Conditions(olderThan: .days(30))))
    }

    /// A new job from a rule's suggested policy.
    init(rule: Rule) {
        self.init(job: Job.suggested(for: rule))
    }
}
