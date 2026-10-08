import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Cleanup

    func cleanupItem(for item: DiskItem) -> CleanupItem? {
        tree.flatMap { CleanupItem(item, in: $0, ruleID: rule(for: item.path)?.id) }
    }

    func addToCleanupList(_ items: [CleanupItem]) {
        for item in items where !cleanupList.contains(where: { $0.id == item.id }) {
            cleanupList.append(item)
        }
    }

    func isInCleanupList(_ path: String?) -> Bool {
        guard let path else { return false }
        return cleanupList.contains { $0.path == path }
    }

    var cleanupListBytes: UInt64 { cleanupList.reduce(0) { $0 + $1.size } }

    /// Opens the review sheet for a plan, unless another cleanup is already open (it may be running). `run` is the job run
    /// by hand the plan belongs to.
    func review(_ plan: CleanupPlan, title: String, run: ManualJobRun? = nil) {
        guard pendingCleanup == nil else {
            errorMessage = "Another cleanup is open. Finish or cancel it first."
            return
        }
        pendingCleanup = PendingCleanup(title: title, plan: plan, run: run)
    }

    /// `finding` is one of the current analysis's findings; its items carry that analysis's scan start time, which is
    /// the Explore scan's unless the analysis scanned the rule locations itself.
    func reviewFinding(_ finding: Finding, items: [FindingItem]? = nil) {
        guard let analysis = analysis else { return }
        let plan = CleanupPlan.make(
            findings: [finding], trashPreference: context.trashPreference(for: .rule), scanStarted: analysis.scanStarted
        ) { items ?? $0.items }
        review(plan, title: "Clean \(finding.rule.name)")
    }

    /// The review the sheet shows before anything runs. The guard's checks can touch the disk, so they run off the
    /// main actor.
    func cleanupReview(of plan: CleanupPlan) async -> CleanupReview {
        let executor = context.executor
        return await Task.detached(priority: .userInitiated) { CleanupReview(plan, executor: executor) }.value
    }

    var isCleaning: Bool { runningCleanups > 0 }

    /// Runs a reviewed plan with the executor of the context current now, through `run` when it completes a job run by
    /// hand (which records the run and settles the suggestion), and finishes that bookkeeping before the app may quit.
    /// A plan reviewed before the settings changed comes back `reviewOutdated` with nothing done; the sheet reviews
    /// it again.
    func execute(
        _ plan: ReviewedPlan, run: ManualJobRun? = nil, onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) async -> CleanupReport {
        beginCleanup()
        defer { endCleanup() }
        let executor = context.executor
        let (report, outcome) = await Task.detached(priority: .userInitiated) { () -> (CleanupReport, ManualJobRun.Outcome?) in
            guard let run else { return (executor.execute(plan, dryRun: false, onProgress: onProgress), nil) }
            let outcome = run.complete(plan, executor: executor, onProgress: onProgress)
            return (outcome.report, outcome)
        }.value
        guard !report.reviewOutdated else { return report }
        if let outcome { finishJobRun(outcome) }
        applyRemovals(report)
        return report
    }

    /// Brings every view up to date after a cleanup without re-scanning or re-analysing everything: the workspace
    /// shrinks the tree and the findings in place (see `follow` for the views), and the Trash, the journal and the
    /// volumes are measured again.
    private func applyRemovals(_ report: CleanupReport) {
        workspace.apply(report, context: context)
        let removals = Removal.from(report)
        // Here rather than when the workspace's change lands: a new scan shown before then drops the change.
        forgetRemoved(removals)
        refreshJournal()
        refreshVolumes()
        // Re-measure the Trash exactly (and resync it in the map) once the move has settled.
        refreshTrash(resync: report.trashedBytes > 0 || removals.contains { PathUtil.isStrictAncestor(trashPath, of: $0.path) })
        refreshSnapshots()
    }

    /// Takes what a cleanup removed off the cleanup list.
    private func forgetRemoved(_ removals: [Removal]) {
        cleanupList.removeAll { item in removals.contains { $0.takesAll(of: item.path, kind: item.kind) } }
    }
}
