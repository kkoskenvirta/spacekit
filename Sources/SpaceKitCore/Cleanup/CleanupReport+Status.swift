import Foundation

extension CleanupReport {
    /// A report of a run that hasn't done anything (yet).
    public init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    /// Commands that were refused, couldn't start, or didn't finish, with the reason.
    public var unfinishedCommands: [(command: PlannedCommand, reason: String)] {
        commands.compactMap { entry in
            switch entry.outcome {
            case .skipped(let reason, _), .failed(let reason): return (entry.command, reason)
            case .removed, .wouldRemove: return nil
            }
        }
    }

    /// The run didn't do everything it was asked to: an item failed, changed since the review (a reason the review
    /// didn't show, or no longer at its reviewed location) or had warnings the person didn't accept, a command was
    /// skipped or failed, or a warning was raised. Other skipped items don't count: refusals the preview already
    /// showed, items already gone or not covered by their scan (a stale plan, files that arrived later), and items
    /// past an automatic run's budget. Front ends report this as an error (the CLI exits nonzero).
    public var hasProblems: Bool {
        let leftUndone = items.contains { entry in
            if case .skipped(_, let kind) = entry.outcome { return kind.isProblem }
            return false
        }
        return !failures.isEmpty || leftUndone || !unfinishedCommands.isEmpty || !warnings.isEmpty
    }

    /// At least one item was removed or one command ran.
    public var removedAnything: Bool {
        items.contains { $0.outcome.isRemoved } || commands.contains { $0.outcome.isRemoved }
    }
}
