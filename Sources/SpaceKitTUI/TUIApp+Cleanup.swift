import Foundation
import SpaceKitCore

extension TUIApp {
    /// Shows the review of `plan`: every item and command with all of the guard's reasons. The footer, always on
    /// screen, counts what will be removed and says where it goes. `y` works only once the whole list has been shown,
    /// so pressing it acknowledges every warning listed. A job run by hand (`run`) completes through `ManualJobRun`.
    func confirmCleanup(_ plan: CleanupPlan, title: String, run: ManualJobRun? = nil) {
        let review = CleanupReview(plan, executor: context.executor)
        let clean = TerminalText.sanitize
        var lines: [String] = []
        // Every reason the guard gave is listed with its own decision, because the first one raised isn't always the
        // one that decided: a git repository (confirm) can also sit in a protected folder (block).
        func add(_ verdict: SafetyVerdict, _ text: String) {
            let blocked = verdict.isBlocked ? "  " + "blocked".fg(verdict.decision.color) : ""
            lines.append(verdict.decision.mark + " " + text + blocked)
            guard verdict.decision != .allow else { return }
            lines += verdict.entries.map { "    " + $0.decision.mark + " " + clean($0.reason).fg($0.decision.color) }
        }
        for row in review.items {
            let size = ANSI.pad(ByteCount.format(row.subject.size), to: 9, alignRight: true)
            add(row.verdict, "\(size)  \(clean(PathUtil.abbreviate(row.subject.path)))")
        }
        for row in review.commands {
            let command = row.subject
            let estimate = "frees up to \(ByteCount.format(command.estimatedBytes))".dim
            add(row.verdict, "$ ".fg(ANSI.accent) + clean(command.displayString) + "  " + estimate)
        }
        for step in review.manualSteps { lines.append("→ ".dim + clean(step)) }
        let title = clean(title)
        guard !review.isEmpty else {
            state.modal = Modal(title: title, lines: lines, footer: ["Nothing here can be removed.".bold])
            return
        }
        state.modal = Modal(
            title: title, lines: lines, footer: cleanupFooter(review),
            onConfirm: { [unowned self] in self.execute(review.acknowledge(acceptingWarnings: true), run: run) },
            confirmLabel: "y clean · n cancel")
    }

    private func cleanupFooter(_ review: CleanupReview) -> [String] {
        var counts = "\(review.selectedItems.count + review.selectedCommands.count) to clean"
        if review.warningCount > 0 { counts += " · " + "\(review.warningCount) with warnings to accept (!)".fg(ANSI.review) }
        if review.blockedCount > 0 { counts += " · " + "\(review.blockedCount) blocked".fg(ANSI.protected) }
        var footer = [counts]
        if let disposal = review.disposalSummary {
            footer.append(review.disposal.isPermanent ? disposal.bold.fg(ANSI.protected) : disposal.bold)
        }
        if let commands = review.commandSummary { footer.append(commands) }
        return footer
    }

    func execute(_ plan: ReviewedPlan, run: ManualJobRun? = nil) {
        guard state.activity == nil else {
            flash("Busy: \(state.activity?.text ?? "")")
            return
        }
        state.activity = .cleaning
        // Stopping mid-removal would leave an item half deleted; the journal is written per removal, so
        // finishing first and then exiting is safe.
        terminal.holdTerminationSignals(true)
        let (executor, inbox) = (context.executor, inbox)
        Thread.detachNewThread {
            guard let run else {
                inbox.post(.cleaned(executor.execute(plan, dryRun: false), nil))
                return
            }
            let outcome = run.complete(plan, executor: executor)
            inbox.post(.cleaned(outcome.report, outcome))
        }
    }

    /// `outcome` is that of a job run by hand, whose state may not have been saved.
    func cleanupFinished(_ report: CleanupReport, outcome: ManualJobRun.Outcome?) {
        state.activity = nil
        terminal.holdTerminationSignals(false)
        for removal in Removal.from(report) where !removal.partial { state.marked[removal.path] = nil }
        workspace.apply(report, context: context)
        var lines = reportLines(report)
        if let outcome {
            lines += outcome.saveErrors.map { TerminalText.sanitize($0).fg(ANSI.protected) }
            refreshAutomation()
        }
        if state.quitWhenIdle || terminal.heldSignal != nil {
            state.exitMessage = lines.joined(separator: "\n")
            state.quit = true
            return
        }
        // A plan reviewed before the settings changed ran none of its rows, each listed with that reason.
        let title = report.reviewOutdated ? "Nothing was removed: review it again" : report.hasProblems ? "Done, with problems" : "Done"
        state.modal = Modal(title: title, lines: lines)
    }

    /// What happened, including everything that didn't: skipped and failed items, command results and
    /// warnings such as journal writes that failed.
    func reportLines(_ report: CleanupReport) -> [String] {
        let clean = TerminalText.sanitize
        var lines = [report.summary.bold.fg(ANSI.safe)]
        if report.trashedBytes > 0 {
            lines.append("Items in the Trash still use disk space until it's emptied (spacekit trash --empty).".dim)
        }
        for warning in report.warnings { lines.append("⚠ ".fg(ANSI.review) + clean(warning)) }
        for (item, reason) in report.failures {
            lines.append("✗ ".fg(ANSI.protected) + "\(clean(PathUtil.abbreviate(item.path))): \(clean(reason))")
        }
        for (item, reason) in report.skipped {
            lines.append("• ".dim + "\(clean(PathUtil.abbreviate(item.path))): \(clean(reason))".dim)
        }
        for note in report.notes { lines.append("• ".dim + clean(note).dim) }
        for (command, outcome, _) in report.commands {
            let text: String
            switch outcome {
            case .removed(let bytes, _): text = "freed \(ByteCount.format(bytes))"
            case .wouldRemove(let bytes): text = "would free \(ByteCount.format(bytes))"
            case .skipped(let reason, _): text = "skipped: \(clean(reason))".fg(ANSI.review)
            case .failed(let reason): text = "failed: \(clean(reason))".fg(ANSI.protected)
            }
            lines.append("$ \(clean(command.displayString)): " + text)
        }
        return lines
    }

    /// Keeps Explore on the folder it showed, or on the nearest one above it that a cleanup left.
    func follow(_ change: Workspace.Change) {
        guard let previous = state.current, let current = change.survivor(of: previous) else { return }
        state.current = current
        if current !== previous {
            state.explore = ListCursor()
        } else {
            state.explore.selection = min(state.explore.selection, max(0, current.items.count - 1))
        }
    }
}
