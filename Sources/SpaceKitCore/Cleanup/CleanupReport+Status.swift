import Foundation

extension CleanupReport {
    /// Commands that were refused, couldn't start, or didn't finish, with the reason.
    public var unfinishedCommands: [(command: PlannedCommand, reason: String)] {
        commands.compactMap { entry in
            switch entry.outcome {
            case .skipped(let reason), .failed(let reason): return (entry.command, reason)
            case .removed, .wouldRemove: return nil
            }
        }
    }

    /// The run didn't do everything it was asked to: an item failed or gained a warning after the preview, a
    /// command was skipped or failed, or a warning was raised. Other skipped items don't count: refusals the preview
    /// already showed, items already gone or no longer the ones reviewed (a stale plan, files that arrived later),
    /// and items past an automatic run's budget. Front ends report this as an error (the CLI exits nonzero).
    public var hasProblems: Bool {
        let changed = skipped.contains { $0.reason.hasPrefix(CleanupExecutor.changedSinceReview) }
        return !failures.isEmpty || changed || !unfinishedCommands.isEmpty || !warnings.isEmpty
    }

    /// At least one item was removed or one command ran.
    public var removedAnything: Bool {
        items.contains { $0.outcome.isRemoved } || commands.contains { $0.outcome.isRemoved }
    }
}
