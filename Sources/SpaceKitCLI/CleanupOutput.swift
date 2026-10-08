import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

/// `--yes` and `--accept-warnings`, the go-ahead of every command that removes things.
struct AcknowledgementOptions: ParsableArguments {
    @Flag(
        name: [.short, .long],
        help: "Go ahead without asking. Only what the guard allows outright runs unless you add --accept-warnings.")
    var yes = false
    @Flag(name: .long, help: "With --yes, also remove the items whose warnings the preview printed.")
    var acceptWarnings = false

    func validate() throws {
        if acceptWarnings && !yes { throw ValidationError("--accept-warnings goes with --yes.") }
    }
}

/// How every command that removes things shows its plan and its result.
enum CleanupOutput {
    /// Every row of a plan with the verdict a preview shows for it, largest item first: the review's own, or for
    /// `jobs show` the verdicts an automatic run gets. The text preview and the JSON plan both print these.
    struct Verdicts {
        var items: [(CleanupItem, SafetyVerdict)]
        var commands: [(PlannedCommand, SafetyVerdict)]
        var manualSteps: [String]
        var useTrash: Bool
        /// What the rows that may run add up to: the review's selection, or what `context` lets run without anyone
        /// accepting a warning. Blocked rows never count.
        var totalBytes: UInt64

        /// The review as a person sees it, so the warnings they accept are exactly the ones printed.
        init(_ review: CleanupReview) {
            items = review.items.map { ($0.subject, $0.verdict) }
            commands = review.commands.map { ($0.subject, $0.verdict) }
            manualSteps = review.manualSteps
            useTrash = review.useTrash
            totalBytes = review.itemBytes &+ review.commandBytes
        }

        /// The plan with the verdicts `context` gets, such as an automatic run's.
        init(_ plan: CleanupPlan, executor: CleanupExecutor, context: CleanupContext) {
            items = plan.itemsLargestFirst.map { ($0, executor.verdict(for: $0, context: context)) }
            commands = plan.commands.map { ($0, executor.verdict(for: $0, context: context)) }
            manualSteps = plan.manualSteps
            useTrash = plan.useTrash
            // An automatic run acknowledges nothing, so only what the guard allows outright runs.
            func runs(_ verdict: SafetyVerdict) -> Bool { context.isAutomatic ? verdict.decision == .allow : !verdict.isBlocked }
            totalBytes =
                items.filter { runs($0.1) }.reduce(0) { $0 &+ $1.0.size }
                &+ commands.filter { runs($0.1) }.reduce(0) { $0 &+ $1.0.estimatedBytes }
        }
    }

    /// One line per item and command with its verdict, followed by the guard's reasons for anything that isn't
    /// simply allowed, and the manual steps. At most `limit` items are listed.
    static func planLines(_ verdicts: Verdicts, limit: Int = .max) -> [String] {
        var lines: [String] = []
        for (item, verdict) in verdicts.items.prefix(limit) {
            let label = item.kind == .looseFiles ? "files in " + Output.path(item.path) : Output.path(item.path)
            lines += verdictLines(verdict, Output.size(item.size) + "  " + label)
        }
        if verdicts.items.count > limit { lines.append("  … \(verdicts.items.count - limit) more".dim) }
        for (command, verdict) in verdicts.commands {
            let text =
                "$ ".fg(ANSI.accent) + Output.safe(command.displayString) + "  "
                + "(frees up to \(ByteCount.format(command.estimatedBytes)); the tool decides what's unused)".dim
            lines += verdictLines(verdict, text)
        }
        lines += verdicts.manualSteps.map { "  → ".dim + Output.safe($0) }
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
            case .skipped(let reason, _):
                lines.append("  skipped ".dim + Output.safe(entry.command.displayString) + ": " + Output.safe(reason).dim)
            case .removed, .wouldRemove:
                break
            }
        }
        lines += report.notes.map { "  skipped ".dim + Output.safe($0).dim }
        lines += report.warnings.map { "  ! ".fg(ANSI.review) + Output.safe($0) }
        return lines
    }

    /// Prints the review of `plan`, gets the go-ahead and runs it through `executor`. Returns the report, or `nil` when
    /// nothing ran.
    static func session(
        _ plan: CleanupPlan, executor: CleanupExecutor, acknowledgement: AcknowledgementOptions, json: Bool, interactive: Bool,
        heading: String = "Cleanup preview", verb: String = "Clean", hint: String
    ) throws -> CleanupReport? {
        try session(
            plan, executor: executor, acknowledgement: acknowledgement, json: json, interactive: interactive, heading: heading,
            verb: verb, hint: hint, run: { executor.execute($0, dryRun: false) }, report: { $0 })
    }

    /// Prints the review of `plan` made with `executor`, gets the go-ahead and runs the reviewed plan through `run`
    /// (a manual job run completes it with the same executor). Returns what `run` returned, or `nil` when nothing ran;
    /// `report` reads the cleanup report from it.
    ///
    /// Warnings are accepted only here, after the preview printed them: by `--accept-warnings` next to `--yes`, or by
    /// answering the question when `interactive`. `--yes` alone runs only what the guard allows outright; the rows with
    /// warnings are still handed to the executor, which reports each as not accepted, so the result lists them and the
    /// command exits nonzero (`exitIfProblems`). With `json`, stdout carries only JSON: the plan alone without `--yes`,
    /// else the plan and the result, always; the preview then goes to stderr.
    static func session<Ran>(
        _ plan: CleanupPlan, executor: CleanupExecutor, acknowledgement: AcknowledgementOptions, json: Bool, interactive: Bool,
        heading: String, verb: String = "Clean", hint: String, run: (ReviewedPlan) -> Ran, report: (Ran) -> CleanupReport
    ) throws -> Ran? {
        let review = CleanupReview(plan, executor: executor)
        let planJSON = json ? PlanJSON(review) : nil
        if let planJSON, !acknowledgement.yes {
            try Output.json(RunJSON(plan: planJSON))
            return nil
        }
        Output.emit([heading.bold] + planLines(Verdicts(review)), toStandardError: json)
        guard !review.isEmpty else {
            Output.emit(["Nothing in this plan can be removed.".dim], toStandardError: json)
            // Here `json` comes with `--yes`: the result says nothing ran.
            if let planJSON { try Output.json(RunJSON(plan: planJSON, result: ReportJSON(CleanupReport(dryRun: false)))) }
            return nil
        }
        Output.emit([""] + summaryLines(review), toStandardError: json)
        // What it cleans and where it goes is on the lines above; the question says when yes accepts the warnings.
        let question = "\n\(verb) now" + (review.needsAcknowledgement ? ", accepting the warnings above?" : "?")
        let acceptingWarnings: Bool
        if acknowledgement.yes {
            acceptingWarnings = acknowledgement.acceptWarnings
        } else if interactive && Output.confirm(question) {
            acceptingWarnings = true
        } else {
            let warnings = review.needsAcknowledgement ? " Items with warnings also need --accept-warnings." : ""
            print("\n" + (hint + warnings).dim)
            return nil
        }
        if review.needsAcknowledgement && !acceptingWarnings {
            let count = review.warningCount
            let note = "\(count) with warnings not accepted, so left alone; add --accept-warnings to run them too."
            Output.emit([note.fg(ANSI.review)], toStandardError: json)
        }
        let ran = run(review.acknowledge(acceptingWarnings: acceptingWarnings))
        if let planJSON {
            try Output.json(RunJSON(plan: planJSON, result: ReportJSON(report(ran))))
        } else {
            Output.emit([""] + reportLines(report(ran)))
        }
        return ran
    }

    /// Ends the command with a nonzero status when the run didn't do everything it was asked to.
    static func exitIfProblems(_ report: CleanupReport) throws {
        if report.hasProblems { throw ExitCode(1) }
    }

    /// Where the selected items go and what the selected commands do, in the review's own words.
    static func summaryLines(_ review: CleanupReview) -> [String] {
        let disposal = review.disposalSummary.map { review.disposal.isPermanent ? $0.bold.fg(ANSI.protected) : $0.bold }
        return [disposal, review.commandSummary].compactMap { $0 }
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

    /// The plan a person reviews, with the verdicts the review shows.
    init(_ review: CleanupReview) {
        self.init(CleanupOutput.Verdicts(review))
    }

    init(_ verdicts: CleanupOutput.Verdicts) {
        useTrash = verdicts.useTrash
        totalBytes = verdicts.totalBytes
        items = verdicts.items.map { item, verdict in
            Item(path: item.path, kind: item.kind.rawValue, bytes: item.size, rule: item.ruleID, verdict: VerdictJSON(verdict))
        }
        commands = verdicts.commands.map { command, verdict in
            Command(
                rule: command.ruleID, arguments: command.arguments, estimatedBytes: command.estimatedBytes, verdict: VerdictJSON(verdict))
        }
        manualSteps = verdicts.manualSteps
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
        case .skipped(let reason, _): (status, self.reason) = ("skipped", reason)
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
    /// Files left on purpose inside items that were removed (`CleanupReport.notes`); not problems.
    var notes: [String]

    init(_ report: CleanupReport) {
        ok = !report.hasProblems
        summary = report.summary
        freedBytes = report.freedBytes
        trashedBytes = report.trashedBytes
        deletedBytes = report.deletedBytes
        items = report.items.map { Item(path: $0.item.path, kind: $0.item.kind.rawValue, outcome: OutcomeJSON($0.outcome)) }
        commands = report.commands.map { Command(arguments: $0.command.arguments, outcome: OutcomeJSON($0.outcome), output: $0.output) }
        warnings = report.warnings
        notes = report.notes
    }
}

/// A plan and what running it did.
struct RunJSON: Encodable {
    var plan: PlanJSON
    var result: ReportJSON?
}
