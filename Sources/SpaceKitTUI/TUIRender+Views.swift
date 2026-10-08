import Foundation
import SpaceKitCore

extension TUIApp {
    // MARK: Dev Intelligence

    func devView(width: Int, height: Int) -> [String] {
        if state.tree == nil {
            if let progress = state.scanProgress { return progressView(progress, title: "Scanning…", width: width, height: height) }
            return ["", "  Waiting for the scan…".dim]
        }
        if let progress = state.analysisProgress {
            return progressView(progress, title: "Looking for developer storage…", width: width, height: height)
        }
        guard let analysis = state.analysis else { return ["", "  Press r to analyse.".dim] }
        let rows = state.devRows
        guard !rows.isEmpty else { return ["", "  Nothing recognised. Rules live in rules/ and ~/.config/spacekit/rules.".dim] }

        var lines: [String] = []
        lines.append(
            "  " + "Regenerable \(ByteCount.format(analysis.total(.safe)))".fg(ANSI.safe).bold + "   "
                + "Review \(ByteCount.format(analysis.total(.review)))".fg(ANSI.review) + "   "
                + "Don't touch \(ByteCount.format(analysis.total(.protected)))".fg(ANSI.protected))
        lines.append("")
        let selected = rows.indices.contains(state.dev.selection) ? rows[state.dev.selection].finding : nil
        let details = selected.map(findingDetails) ?? []
        // The details panel gives way to the list on short screens.
        let showDetails = height - lines.count - details.count >= 3
        let available = height - lines.count - (showDetails ? details.count : 0)

        let nameWidth = max(16, min(36, width - 70))
        for index in state.dev.visibleRows(available, count: rows.count) {
            let row = rows[index]
            guard let finding = row.finding else {
                lines.append(" " + TerminalText.sanitize(row.group).bold)
                continue
            }
            let mark = state.markedRules.contains(finding.id) ? "◉".fg(ANSI.review) : " "
            let dot = "●".fg(ANSI.color(for: finding.safety))
            let name = ANSI.pad(ANSI.truncate(TerminalText.sanitize(finding.rule.name), to: nameWidth), to: nameWidth)
            let group = ANSI.pad(ANSI.truncate(TerminalText.sanitize(finding.rule.group), to: 14), to: 14).dim
            let size = ANSI.pad(ByteCount.format(finding.size), to: 9, alignRight: true).bold
            let count = ANSI.pad("\(finding.items.count) item\(finding.items.count == 1 ? "" : "s")", to: 10, alignRight: true).dim
            let used = finding.lastUsed.map { "used " + $0.relativeDescription() } ?? ""
            let line = "  \(mark) \(dot) \(name) \(group) \(size) \(count)  " + used.dim
            lines.append(index == state.dev.selection ? highlighted(line) : line)
        }
        if showDetails { lines += details }
        return lines
    }

    private func findingDetails(_ finding: Finding) -> [String] {
        let rule = finding.rule
        let size = ByteCount.format(finding.size).bold
        var lines = ["", " " + TerminalText.sanitize(rule.name).bold + " — " + size + "  " + finding.safety.badge]
        if let description = rule.description { lines.append(" " + TerminalText.sanitize(description).dim) }
        let summary = finding.facts().filter { [.risk, .recreatedBy, .lastUsed].contains($0.kind) }
        lines.append(" " + summary.map { "\($0.label): \(TerminalText.sanitize($0.value))" }.joined(separator: "  ·  ").dim)
        return lines
    }

    // MARK: AI

    func aiView(width: Int, height: Int) -> [String] {
        if let progress = state.analysisProgress {
            return progressView(progress, title: "Looking for local AI storage…", width: width, height: height)
        }
        guard let report = state.aiReport else { return ["", "  Waiting for the scan…".dim] }
        guard report.total > 0 else { return ["", "  No local AI models found (Ollama, Hugging Face, LM Studio, …).".dim] }
        var lines: [String] = []
        lines.append("  " + "LOCAL AI".bold + "   " + ByteCount.format(report.total).bold.fg(ANSI.accent))
        lines.append(
            "  " + "Potentially reclaimable \(ByteCount.format(report.reclaimable()))".fg(ANSI.safe)
                + "   " + "Active (\(Int(report.activeWindow.days))d) \(ByteCount.format(report.active()))".dim
                + "   " + "Unused \(Int(report.activeWindow.days))+ days \(ByteCount.format(report.unused()))".fg(ANSI.review))
        lines.append("")
        let rows = state.aiRows
        let tools = Dictionary(report.tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for index in state.ai.visibleRows(height - lines.count, count: rows.count) {
            let row = rows[index]
            guard let model = row.model else {
                lines.append(
                    " " + ANSI.pad(ANSI.truncate(TerminalText.sanitize(row.tool), to: 39).bold, to: 40)
                        + ByteCount.format(tools[row.tool]?.size ?? 0).bold)
                continue
            }
            let status = model.status(within: report.activeWindow).terminalText
            let used = model.lastUsed.map { $0.relativeDescription() } ?? "–"
            let line =
                "   ├ " + ANSI.pad(ANSI.truncate(TerminalText.sanitize(model.name), to: 40), to: 40)
                + ANSI.pad(ByteCount.format(model.size), to: 9, alignRight: true)
                + "  " + ANSI.pad(status, to: 9) + "  " + used.dim
            lines.append(index == state.ai.selection ? highlighted(line) : line)
        }
        return lines
    }

    // MARK: Automation

    func jobsView(width: Int, height: Int) -> [String] {
        if state.automation == nil { refreshAutomation() }
        guard let snapshot = state.automation else { return [] }
        let next = Dictionary(snapshot.nextRuns.map { ($0.job.id, $0.date) }, uniquingKeysWith: { a, _ in a })

        var lines: [String] = []
        lines.append(
            "  " + "AUTOMATIC CLEANUP".bold + "    Your Mac has recovered " + ByteCount.format(snapshot.recovered).bold.fg(ANSI.safe)
                + " over the last 3 months.")
        let agentText =
            snapshot.agent.loaded
            ? "● Background agent running".fg(ANSI.safe)
            : snapshot.agent.installed
                ? "● Agent installed, not loaded".fg(ANSI.review)
                : "○ Background agent not installed — press i".fg(ANSI.review)
        lines.append("  " + agentText)
        if let error = context.configError { lines.append("  " + "Config error: \(TerminalText.sanitize(error))".fg(ANSI.protected)) }
        lines.append("")
        let jobs = context.config.jobs
        guard !jobs.isEmpty else {
            return lines + ["  No jobs yet. Create one from Dev Intelligence (n), or run: spacekit jobs add".dim]
        }
        // Each job takes three rows; keep the selected one on screen.
        var window = ScrollWindow()
        let visibleJobs = window.follow(selection: state.jobSelection, visible: (height - lines.count - 1) / 3, count: jobs.count)
        for index in visibleJobs {
            let job = jobs[index]
            let toggle = job.terminalToggle
            let mode = ANSI.pad(job.mode.title, to: 10).fg(job.mode == .automatic ? ANSI.accent : 250)
            let nextText = job.nextRunText(next[job.id])
            let name = ANSI.truncate(TerminalText.sanitize(job.name), to: 33).bold
            let title =
                " " + ANSI.pad(name, to: 34) + mode + ANSI.pad(job.schedule.description, to: 27) + ANSI.pad(nextText.dim, to: 18) + toggle
            lines.append(index == state.jobSelection ? highlighted(title) : title)
            var detail = "   " + TerminalText.sanitize(job.conditionSummary).dim
            if let last = snapshot.states[job.id]?.lastOutcome { detail += "   last: ".dim + TerminalText.sanitize(last) }
            lines.append(detail)
            lines.append("")
        }
        if let first = snapshot.nextRuns.first {
            let estimate = snapshot.estimate
            lines.append(
                "  Next automatic cleanup: " + first.date.formatted(date: .abbreviated, time: .shortened).bold
                    + (estimate.high > 0
                        ? "   Estimated recovery: \(ByteCount.format(estimate.low))–\(ByteCount.format(estimate.high))".dim : ""))
        }
        return lines
    }

    // MARK: History

    func historyView(width: Int, height: Int) -> [String] {
        if state.history == nil { refreshHistory() }
        guard let snapshot = state.history else { return [] }
        let days = snapshot.days
        var lines: [String] = []
        lines.append("  " + "YOUR DISK".bold)
        guard days.count >= 2 else {
            return lines + [
                "", "  History builds up as SpaceKit runs. The background agent records usage every few hours.".dim,
                "  Install it from the Automation view (i) or with: spacekit agent install".dim,
            ]
        }
        let values = days.map { Double($0.used) }
        let chartWidth = max(0, min(width - 14, values.count * 2))
        let rows = max(0, min(10, height - 12))
        if chartWidth >= 2 && rows >= 2 {
            lines += chart(values, width: chartWidth, rows: rows)
            if let first = days.first?.date, let last = days.last?.date {
                let left = first.formatted(.dateTime.month(.abbreviated).day())
                let right = last.formatted(.dateTime.month(.abbreviated).day())
                lines.append(
                    "  " + String(repeating: " ", count: 11) + left.dim
                        + String(repeating: " ", count: max(1, chartWidth - left.count - right.count)) + right.dim)
            }
        }
        lines.append("")
        if let month = snapshot.monthDelta {
            let text = ByteCount.formatDelta(month) + " this month"
            lines.append("  " + (month > 0 ? text.fg(ANSI.review) : text.fg(ANSI.safe)).bold)
        }
        if !snapshot.grew.isEmpty {
            lines.append("")
            lines.append("  " + "WHAT GREW?".bold)
            lines += snapshot.grew.prefix(max(0, height - lines.count - 1)).map(\.terminalLine)
        }
        return lines
    }

    /// A bar chart of `values`, resampled to `width` columns, `rows` high, with the axis below.
    private func chart(_ values: [Double], width: Int, rows: Int) -> [String] {
        let resampled = (0..<width).map { values[min(values.count - 1, $0 * values.count / width)] }
        let low = (values.min() ?? 0) * 0.98
        let high = values.max() ?? 1
        var lines: [String] = []
        for row in (0..<rows).reversed() {
            let threshold = low + (high - low) * Double(row) / Double(rows - 1)
            let label =
                row == rows - 1 || row == 0
                ? ANSI.pad(ByteCount.format(UInt64(max(0, threshold))), to: 9, alignRight: true) : String(repeating: " ", count: 9)
            let bar = resampled.map { $0 >= threshold ? "█" : " " }.joined()
            lines.append("  " + label.dim + " │".dim + bar.fg(ANSI.accent))
        }
        lines.append("  " + String(repeating: " ", count: 9) + " └".dim + String(repeating: "─", count: width).dim)
        return lines
    }
}
