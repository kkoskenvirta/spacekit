import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Cleanup

    func cleanupItem(for item: DiskItem) -> CleanupItem? {
        CleanupItem(item, markers: tree?.markers, ruleID: rule(for: item.path)?.id)
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

    /// Opens the review sheet for a plan, unless another cleanup is already open (it may be running).
    func review(_ plan: CleanupPlan, title: String, completion: (@MainActor (CleanupReport) -> Void)? = nil) {
        guard pendingCleanup == nil else {
            errorMessage = "Another cleanup is open. Finish or cancel it first."
            return
        }
        pendingCleanup = PendingCleanup(title: title, plan: plan, completion: completion)
    }

    /// A plan for items picked from the map or the cleanup list, dated by the scan they came from (loose files
    /// changed since aren't touched), moved to the Trash.
    func manualPlan(_ items: [CleanupItem]) -> CleanupPlan {
        CleanupPlan(items: items, useTrash: true, created: treeScanStarted)
    }

    /// When the scan behind the Dev and AI findings began. It's the Explore scan's unless the analysis scanned
    /// the rule locations itself.
    var analysisScanStarted: Date { analysisResult?.scanStarted ?? treeScanStarted }

    func reviewFinding(_ finding: Finding, items: [FindingItem]? = nil) {
        let trash = context.trashPreference(for: .rule)
        let plan = CleanupPlan.make(findings: [finding], trashPreference: trash, created: analysisScanStarted) { items ?? $0.items }
        review(plan, title: "Clean \(finding.rule.name)")
    }

    /// The guard's verdict on everything in a plan, as the review sheet shows it before anything runs.
    struct PlanVerdicts: Sendable {
        var items: [(item: CleanupItem, verdict: SafetyVerdict)]
        var commands: [(command: PlannedCommand, verdict: SafetyVerdict)]
    }

    func verdicts(for plan: CleanupPlan) async -> PlanVerdicts {
        let executor = context.executor
        return await Task.detached(priority: .userInitiated) {
            PlanVerdicts(
                items: plan.itemsLargestFirst.map { ($0, executor.verdict(for: $0, context: .manual(confirmed: false))) },
                commands: plan.commands.map { ($0, executor.verdict(for: $0, context: .manual(confirmed: false))) })
        }.value
    }

    var isCleaning: Bool { runningCleanups > 0 }

    /// Runs a reviewed plan, then `completion` (bookkeeping such as job state) before the app may quit.
    /// Pass `confirmed: true` only when the person acknowledged every warning the review showed; otherwise items and
    /// commands that need confirmation are skipped.
    func execute(
        _ plan: CleanupPlan, confirmed: Bool, completion: (@MainActor (CleanupReport) -> Void)? = nil,
        onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) async -> CleanupReport {
        beginCleanup()
        defer { endCleanup() }
        let executor = context.executor
        let report = await Task.detached(priority: .userInitiated) {
            executor.execute(plan, context: .manual(confirmed: confirmed), dryRun: false, onProgress: onProgress)
        }.value
        completion?(report)
        Task {
            await untilTreesAreFree()
            applyRemovals(report)
        }
        return report
    }

    /// Brings every view up to date after a cleanup without re-scanning or re-analysing everything:
    /// the trees shrink in place, findings lose only the cleaned items, the AI report and category
    /// totals update only if they were affected, and rules whose tool command ran are re-evaluated alone.
    private func applyRemovals(_ report: CleanupReport) {
        let removals = Removal.from(report)
        applyToTreesAndFindings(removals)

        // Tool commands free space their own way; re-evaluate just those rules.
        refreshFindings(ruleIDs: report.rulesToReevaluate)

        let removedPaths = Set(removals.filter { $0.kind != .looseFiles && !$0.partial }.map(\.path))
        // A partly removed folder was rescanned: it keeps its node, but the folders inside it got new ones.
        let rescannedPaths = removals.filter(\.partial).map(\.path)
        let isGone: (String) -> Bool = { path in
            removedPaths.contains { PathUtil.isAncestorOrEqual($0, of: path) }
                || rescannedPaths.contains { PathUtil.isStrictAncestor($0, of: path) }
        }
        if let focus, isGone(focus.path) {
            var survivor = focus.parent
            while let node = survivor, isGone(node.path) { survivor = node.parent }
            refocus(on: survivor ?? tree?.root)
        }
        if !removedPaths.isEmpty || removals.contains(where: { $0.kind == .looseFiles }) {
            cleanupList.removeAll { item in
                removedPaths.contains { PathUtil.isAncestorOrEqual($0, of: item.path) }
                    || (item.kind == .looseFiles && removals.contains { $0.kind == .looseFiles && $0.path == item.path })
            }
        }
        if let path = selection?.path, isGone(path) { selection = nil }
        if let path = hovered?.path, isGone(path) { hovered = nil }

        refreshJournal()
        refreshVolumes()
        // Re-measure the Trash exactly (and resync it in the map) once the move has settled.
        refreshTrash(resync: report.trashedBytes > 0 || removals.contains { PathUtil.isStrictAncestor(trashPath, of: $0.path) })
        refreshSnapshots()
    }
}
