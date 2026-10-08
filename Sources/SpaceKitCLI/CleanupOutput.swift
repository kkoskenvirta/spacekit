import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

/// How every command that removes things shows its plan and its result.
enum CleanupOutput {
    /// One line per item and command with the verdict `context` gets, followed by the guard's reasons for
    /// anything that isn't simply allowed, and the manual steps.
    static func planLines(_ plan: CleanupPlan, executor: CleanupExecutor, context: CleanupContext, limit: Int = .max) -> [String] {
        var lines: [String] = []
        let items = plan.itemsLargestFirst
        for item in items.prefix(limit) {
            let label = item.kind == .looseFiles ? "files in " + Output.path(item.path) : Output.path(item.path)
            lines += verdictLines(executor.verdict(for: item, context: context), Output.size(item.size) + "  " + label)
        }
        if items.count > limit { lines.append("  … \(items.count - limit) more".dim) }
        for command in plan.commands {
            let text =
                "$ ".fg(ANSI.accent) + Output.safe(command.displayString) + "  "
                + "(frees up to \(ByteCount.format(command.estimatedBytes)); the tool decides what's unused)".dim
            lines += verdictLines(executor.verdict(for: command, context: context), text)
        }
        lines += plan.manualSteps.map { "  → ".dim + Output.safe($0) }
        return lines
    }

    /// Each reason carries its own decision: a blocked item can also have a reason that alone would only need
    /// confirmation, and that one isn't labelled "Blocked".
    private static func verdictLines(_ verdict: SafetyVerdict, _ text: String) -> [String] {
        var lines = ["  \(verdict.decision.mark) " + text]
        guard verdict.decision != .allow else { return lines }
        for entry in verdict.entries {
            let reason = Output.safe(entry.reason)
            let label: String = entry.decision == .block ? "Blocked: " + reason : reason
            lines.append("        " + label.fg(entry.decision.color))
        }
        return lines
    }

    /// The summary, then everything that didn't go as planned.
    static func reportLines(_ report: CleanupReport) -> [String] {
        var lines = [report.summary.bold.fg(report.hasProblems ? ANSI.review : ANSI.safe)]
        if report.trashedBytes > 0 {
            lines.append("Items in the Trash still use disk space until it's emptied: ".dim + "spacekit trash --empty".bold)
        }
        for (item, reason) in report.failures {
            lines.append("  ✗ ".fg(ANSI.protected) + Output.path(item.path) + ": " + Output.safe(reason))
        }
        for (item, reason) in report.skipped {
            lines.append("  skipped ".dim + Output.path(item.path) + ": " + Output.safe(reason).dim)
        }
        for entry in report.commands {
            switch entry.outcome {
            case .failed(let reason):
                lines.append("  ✗ ".fg(ANSI.protected) + Output.safe(entry.command.displayString) + ": " + Output.safe(reason))
                lines += entry.output.split(separator: "\n").suffix(5).map { "    " + Output.safe(String($0)).dim }
            case .skipped(let reason):
                lines.append("  skipped ".dim + Output.safe(entry.command.displayString) + ": " + Output.safe(reason).dim)
            case .removed, .wouldRemove:
                break
            }
        }
        lines += report.warnings.map { "  ! ".fg(ANSI.review) + Output.safe($0) }
        return lines
    }

    /// Shows the plan with the guard's verdicts, gets the go-ahead (`yes`, or a question when `interactive`) and
    /// runs it. Returns the report, or `nil` when nothing ran.
    ///
    /// Items that need confirmation are confirmed only here, after their warnings were printed and the person
    /// agreed. With `json`, stdout carries only JSON: the plan alone without `yes`, else the plan and the result;
    /// the human preview then goes to stderr.
    static func session(
        _ plan: CleanupPlan, executor: CleanupExecutor, yes: Bool, json: Bool, interactive: Bool, heading: String = "Cleanup preview",
        verb: String = "Clean", hint: String
    ) throws -> CleanupReport? {
        let review = CleanupContext.manual(confirmed: false)
        let planJSON = json ? PlanJSON(plan: plan, executor: executor, context: review) : nil
        if let planJSON, !yes {
            try Output.json(RunJSON(plan: planJSON))
            return nil
        }
        Output.emit([heading.bold] + planLines(plan, executor: executor, context: review), toStandardError: json)
        let preview = executor.execute(plan, context: .manual(confirmed: true), dryRun: true)
        let wouldAct = preview.items.contains { $0.outcome.isWouldRemove } || preview.commands.contains { $0.outcome.isWouldRemove }
        guard wouldAct else {
            Output.emit(["Nothing in this plan can be removed.".dim], toStandardError: json)
            if let planJSON { try Output.json(RunJSON(plan: planJSON)) }
            return nil
        }
        guard yes || (interactive && Output.confirm("\n" + question(plan, preview: preview, verb: verb))) else {
            print("\n" + hint.dim)
            return nil
        }
        let report = executor.execute(plan, context: .manual(confirmed: true), dryRun: false)
        if let planJSON {
            try Output.json(RunJSON(plan: planJSON, result: ReportJSON(report)))
        } else {
            Output.emit([""] + reportLines(report))
        }
        return report
    }

    /// Ends the command with a nonzero status when the run didn't do everything it was asked to.
    static func exitIfProblems(_ report: CleanupReport) throws {
        if report.hasProblems { throw ExitCode(1) }
    }

    /// "Clean 1.2 GB to the Trash and run 1 tool command?"
    static func question(_ plan: CleanupPlan, preview: CleanupReport, verb: String = "Clean") -> String {
        let itemBytes = preview.items.reduce(UInt64(0)) { total, entry in
            if case .wouldRemove(let bytes) = entry.outcome { return total + bytes }
            return total
        }
        let commands = preview.commands.filter { $0.outcome.isWouldRemove }.count
        let parts = [
            itemBytes > 0 ? ByteCount.format(itemBytes) + (plan.useTrash ? " to the Trash" : " permanently") : "",
            commands > 0 ? "run \(commands) tool command\(commands == 1 ? "" : "s")" : "",
        ]
        return "\(verb) " + parts.filter { !$0.isEmpty }.joined(separator: " and ") + "?"
    }
}

// MARK: JSON

struct VerdictJSON: Encodable {
    var decision: String
    var reasons: [String]

    init(_ verdict: SafetyVerdict) {
        decision = "\(verdict.decision)"
        reasons = verdict.reasons
    }
}

struct PlanJSON: Encodable {
    struct Item: Encodable {
        var path: String
        var kind: String
        var bytes: UInt64
        var rule: String?
        var verdict: VerdictJSON
    }
    struct Command: Encodable {
        var rule: String
        var arguments: [String]
        var estimatedBytes: UInt64
        var verdict: VerdictJSON
    }
    var useTrash: Bool
    var totalBytes: UInt64
    var items: [Item]
    var commands: [Command]
    var manualSteps: [String]

    init(plan: CleanupPlan, executor: CleanupExecutor, context: CleanupContext) {
        useTrash = plan.useTrash
        totalBytes = plan.totalBytes
        items = plan.items.map { item in
            Item(
                path: item.path, kind: item.kind.rawValue, bytes: item.size, rule: item.ruleID,
                verdict: VerdictJSON(executor.verdict(for: item, context: context)))
        }
        commands = plan.commands.map { command in
            Command(
                rule: command.ruleID, arguments: command.arguments, estimatedBytes: command.estimatedBytes,
                verdict: VerdictJSON(executor.verdict(for: command, context: context)))
        }
        manualSteps = plan.manualSteps
    }
}

struct OutcomeJSON: Encodable {
    var status: String
    var bytes: UInt64?
    var trashedTo: String?
    var reason: String?

    init(_ outcome: CleanupOutcome) {
        switch outcome {
        case .removed(let bytes, let trashedTo): (status, self.bytes, self.trashedTo) = ("removed", bytes, trashedTo)
        case .wouldRemove(let bytes): (status, self.bytes) = ("wouldRemove", bytes)
        case .skipped(let reason): (status, self.reason) = ("skipped", reason)
        case .failed(let reason): (status, self.reason) = ("failed", reason)
        }
    }
}

struct ReportJSON: Encodable {
    struct Item: Encodable {
        var path: String
        var kind: String
        var outcome: OutcomeJSON
    }
    struct Command: Encodable {
        var arguments: [String]
        var outcome: OutcomeJSON
        var output: String
    }
    var ok: Bool
    var summary: String
    var freedBytes: UInt64
    var trashedBytes: UInt64
    var deletedBytes: UInt64
    var items: [Item]
    var commands: [Command]
    var warnings: [String]

    init(_ report: CleanupReport) {
        ok = !report.hasProblems
        summary = report.summary
        freedBytes = report.freedBytes
        trashedBytes = report.trashedBytes
        deletedBytes = report.deletedBytes
        items = report.items.map { Item(path: $0.item.path, kind: $0.item.kind.rawValue, outcome: OutcomeJSON($0.outcome)) }
        commands = report.commands.map { Command(arguments: $0.command.arguments, outcome: OutcomeJSON($0.outcome), output: $0.output) }
        warnings = report.warnings
    }
}

/// A plan and what running it did.
struct RunJSON: Encodable {
    var plan: PlanJSON
    var result: ReportJSON?
}
