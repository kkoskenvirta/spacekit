import Foundation

extension CleanupPlan {
    /// This plan narrowed to what `eligible` (a fresh evaluation of the same job) still offers. A saved plan, such
    /// as a suggestion, may be days old: items used since then or no longer matching the job's age conditions
    /// must not be removed on the strength of the old preview.
    ///
    /// Items are matched by path and kind, item commands by the item they name, and whole-rule commands by
    /// their rule still having eligible items. `created`, `useTrash` and the manual steps are kept, so the
    /// executor still leaves alone whatever changed after the original preview.
    public func keeping(onlyEligible eligible: [Finding]) -> (plan: CleanupPlan, dropped: [CleanupItem]) {
        let eligibleIDs = Set(eligible.flatMap { $0.items.map(\.id) })
        let eligiblePaths = Set(eligible.flatMap { $0.items.map(\.path) })
        let eligibleRules = Set(eligible.filter { !$0.items.isEmpty }.map(\.rule.id))

        var refreshed = self
        refreshed.items = items.filter { eligibleIDs.contains($0.id) }
        refreshed.commands = commands.filter { command in
            if let itemPath = command.itemPath { return eligiblePaths.contains(itemPath) }
            return eligibleRules.contains(command.ruleID)
        }
        return (refreshed, items.filter { !eligibleIDs.contains($0.id) })
    }
}
