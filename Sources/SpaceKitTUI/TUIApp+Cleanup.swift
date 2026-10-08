import Foundation
import SpaceKitCore

extension TUIApp {
    /// Shows what the guard thinks of each item and command and asks before doing anything. The footer, always
    /// on screen, counts what will be removed and says whether it goes to the Trash; `y` works only once the
    /// whole list has been shown.
    func confirmCleanup(_ plan: CleanupPlan, title: String, job: JobEvaluation? = nil) {
        let executor = context.executor
        let clean = TerminalText.sanitize
        var lines: [String] = []
        var allowed = CleanupPlan(manualSteps: plan.manualSteps, useTrash: plan.useTrash, created: plan.created)
        var needConfirmation = 0
        var blocked = 0
        // Every reason the guard gave is listed with its own decision, because the first one raised isn't always the
        // one that decided: a git repository (confirm) can also sit in a protected folder (block).
        func add(_ verdict: SafetyVerdict, _ text: String) -> Bool {
            var line: String = verdict.decision.mark + " " + text
            switch verdict.decision {
            case .allow: break
            case .confirm: needConfirmation += 1
            case .block:
                blocked += 1
                line += "  " + "blocked".fg(verdict.decision.color)
            }
            lines.append(line)
            guard verdict.decision != .allow else { return true }
            for entry in verdict.entries {
                let reason: String = clean(entry.reason).fg(entry.decision.color)
                lines.append("    " + entry.decision.mark + " " + reason)
            }
            return verdict.decision == .confirm
        }
        for item in plan.itemsLargestFirst {
            let verdict = executor.verdict(for: item, context: .manual(confirmed: false))
            let size = ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true)
            if add(verdict, "\(size)  \(clean(PathUtil.abbreviate(item.path)))") { allowed.items.append(item) }
        }
        for command in plan.commands {
            let verdict = executor.verdict(for: command, context: .manual(confirmed: false))
            let text =
                "$ ".fg(ANSI.accent) + clean(command.displayString) + "  " + "frees up to \(ByteCount.format(command.estimatedBytes))".dim
            if add(verdict, text) { allowed.commands.append(command) }
        }
        for step in plan.manualSteps { lines.append("→ ".dim + clean(step)) }
        let title = clean(title)
        guard !allowed.isEmpty else {
            state.modal = Modal(title: title, lines: lines, footer: ["Nothing here can be removed.".bold])
            return
        }
        state.modal = Modal(
            title: title, lines: lines,
            footer: cleanupFooter(allowed, needConfirmation: needConfirmation, blocked: blocked),
            onConfirm: { [unowned self] in self.execute(allowed, job: job) }, confirmLabel: "y clean · n cancel")
    }

    private func cleanupFooter(_ allowed: CleanupPlan, needConfirmation: Int, blocked: Int) -> [String] {
        let count = allowed.items.count + allowed.commands.count
        var counts = "\(count) to clean"
        if needConfirmation > 0 { counts += " · " + "\(needConfirmation) need your confirmation (!)".fg(ANSI.review) }
        if blocked > 0 { counts += " · " + "\(blocked) blocked".fg(ANSI.protected) }
        var footer = [counts]
        if !allowed.items.isEmpty {
            let size = ByteCount.format(allowed.items.reduce(0) { $0 &+ $1.size })
            footer.append(
                allowed.useTrash
                    ? "\(size) will be moved to the Trash.".bold
                    : "\(size) will be deleted permanently, not moved to the Trash.".bold.fg(ANSI.protected))
        }
        if !allowed.commands.isEmpty {
            let commands = allowed.commands.count
            footer.append("\(commands) tool command\(commands == 1 ? "" : "s") will run; each removes only what its tool knows is unused.")
        }
        return footer
    }

    func execute(_ plan: CleanupPlan, job: JobEvaluation? = nil) {
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
            // The person saw every item and warning in the preview and pressed y.
            let report = executor.execute(plan, context: .manual(confirmed: true), dryRun: false)
            inbox.post(.cleaned(report, job))
        }
    }

    func cleanupFinished(_ report: CleanupReport, job: JobEvaluation?) {
        state.activity = nil
        terminal.holdTerminationSignals(false)
        let removals = Removal.from(report)
        for removal in removals where !removal.partial { state.marked[removal.path] = nil }
        if state.analysisProgress != nil {
            state.pendingRemovals += removals
        } else {
            applyRemovals(removals)
        }
        refreshFindings(ruleIDs: report.rulesToReevaluate)
        var lines = reportLines(report)
        if let job {
            if let problem = record(job, report: report) { lines.append(problem.fg(ANSI.protected)) }
            refreshAutomation()
        }
        if state.quitWhenIdle || terminal.heldSignal != nil {
            state.exitMessage = lines.joined(separator: "\n")
            state.quit = true
            return
        }
        state.modal = Modal(title: report.hasProblems ? "Done, with problems" : "Done", lines: lines)
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
        for (command, outcome, _) in report.commands {
            let text: String
            switch outcome {
            case .removed(let bytes, _): text = "freed \(ByteCount.format(bytes))"
            case .wouldRemove(let bytes): text = "would free \(ByteCount.format(bytes))"
            case .skipped(let reason): text = "skipped: \(clean(reason))".fg(ANSI.review)
            case .failed(let reason): text = "failed: \(clean(reason))".fg(ANSI.protected)
            }
            lines.append("$ \(clean(command.displayString)): " + text)
        }
        return lines
    }

    /// Updates the trees, findings and AI report after a cleanup without re-scanning. Only call it while no
    /// analysis is reading the tree.
    func applyRemovals(_ removals: [Removal]) {
        guard !removals.isEmpty else { return }
        let previous = state.current
        let currentPath = previous?.path
        if let tree = state.tree {
            Removal.apply(removals, to: tree)
            // Folders above the current one may have been removed; their nodes are gone, so go by path.
            let current = currentPath.map { nearestNode(to: $0, in: tree) } ?? tree.root
            state.current = current
            if current !== previous {
                state.explore = ListCursor()
            } else {
                state.explore.selection = min(state.explore.selection, max(0, current.items.count - 1))
            }
        }
        // A copy: reading `state.tree` inside the mutating call on `state.result` is an exclusivity violation.
        let tree = state.tree
        state.result?.apply(removals, exploreTree: tree)
    }

    func nearestNode(to path: String, in tree: ScanTree) -> DirNode {
        var candidate = path
        while !candidate.isEmpty {
            if let node = tree.node(at: candidate) { return node }
            let parent = PathUtil.parent(candidate)
            if parent == candidate { break }
            candidate = parent
        }
        return tree.root
    }
}
