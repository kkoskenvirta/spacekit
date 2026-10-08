import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Refreshing a saved plan")
struct PlanRefreshTests {
    let rule = Rule(id: "cache", name: "Cache", paths: ["/tmp/x"], safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
    let toolRule = Rule(
        id: "tool", name: "Tool", paths: ["/tmp/t"], safety: SafetySpec(level: .safe), action: ActionSpec(command: ["brew", "cleanup"]))

    func item(_ path: String, kind: FindingItem.Kind = .directory) -> FindingItem {
        FindingItem(path: path, kind: kind, name: PathUtil.lastComponent(path), size: 100)
    }

    /// The plan a fresh evaluation of the job makes from `eligible`, from a scan after the saved one.
    func fresh(_ eligible: [Finding], trash: Bool = false) -> CleanupPlan {
        CleanupPlan.make(findings: eligible, trashPreference: trash, scanStarted: Date(timeIntervalSince1970: 2_000))
    }

    @Test("Keeps only items and commands that are still eligible, and the original scan start")
    func keepsEligible() {
        let scanned = Date(timeIntervalSince1970: 1_000)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: "/tmp/x/a", size: 100, ruleID: "cache", scanStarted: scanned),
                CleanupItem(path: "/tmp/x/b", size: 100, ruleID: "cache", scanStarted: scanned),
                CleanupItem(path: "/tmp/x", kind: .looseFiles, size: 10, ruleID: "cache", scanStarted: scanned),
            ],
            commands: [
                PlannedCommand(ruleID: "tool", arguments: ["brew", "cleanup"], estimatedBytes: 5),
                PlannedCommand(ruleID: "gone", arguments: ["x", "/tmp/y/c"], estimatedBytes: 5, itemPath: "/tmp/y/c"),
            ],
            useTrash: false)
        let eligible = [
            Finding(rule: rule, items: [item("/tmp/x/a"), item("/tmp/x", kind: .looseFiles)]),
            Finding(rule: toolRule, items: [item("/tmp/t")]),
        ]

        let (refreshed, dropped) = plan.keeping(onlyIn: fresh(eligible))

        #expect(refreshed.items.map(\.id) == ["/tmp/x/a", "/tmp/x/*"])
        #expect(refreshed.commands.map(\.ruleID) == ["tool"])
        #expect(dropped.map(\.path) == ["/tmp/x/b"])
        #expect(refreshed.items.allSatisfy { $0.scanStarted == scanned })
        #expect(refreshed.useTrash == false)
        #expect(plan.keeping(onlyIn: fresh(eligible, trash: true)).plan.useTrash, "either plan asking for the Trash wins")
    }

    @Test("A folder that is still there but as loose files isn't the same item")
    func kindMatters() {
        let plan = CleanupPlan(items: [CleanupItem(path: "/tmp/x", kind: .directory, size: 1, ruleID: "cache")])
        let (refreshed, dropped) = plan.keeping(onlyIn: fresh([Finding(rule: rule, items: [item("/tmp/x", kind: .looseFiles)])]))
        #expect(refreshed.items.isEmpty)
        #expect(dropped.count == 1)
    }

    @Test("Item commands stay only while their item is eligible")
    func itemCommands() {
        let plan = CleanupPlan(commands: [
            PlannedCommand(ruleID: "cache", arguments: ["x", "/tmp/x/a"], estimatedBytes: 1, itemPath: "/tmp/x/a"),
            PlannedCommand(ruleID: "cache", arguments: ["x", "/tmp/x/b"], estimatedBytes: 1, itemPath: "/tmp/x/b"),
        ])
        let itemRule = Rule(
            id: "cache", name: "Cache", paths: ["/tmp/x"], safety: SafetySpec(level: .safe),
            action: ActionSpec(itemCommand: ["x", "{path}"]))
        let (refreshed, _) = plan.keeping(onlyIn: fresh([Finding(rule: itemRule, items: [item("/tmp/x/b")])]))
        #expect(refreshed.commands.map(\.itemPath) == ["/tmp/x/b"])
    }
}

@Suite("Cleanup report status")
struct CleanupReportStatusTests {
    let item = CleanupItem(path: "/tmp/a", size: 1)
    let command = PlannedCommand(ruleID: "r", arguments: ["brew", "cleanup"], estimatedBytes: 1)

    @Test("Outcomes answer what happened without a pattern match")
    func outcomePredicates() {
        let outcomes: [CleanupOutcome] = [
            .removed(bytes: 1, trashedTo: nil), .wouldRemove(bytes: 1), .skipped(reason: "x", kind: .refused), .failed(reason: "y"),
        ]
        #expect(outcomes.map(\.isRemoved) == [true, false, false, false])
        #expect(outcomes.map(\.isWouldRemove) == [false, true, false, false])
        #expect(outcomes.map(\.isSkipped) == [false, false, true, false])
        #expect(outcomes.map(\.isFailed) == [false, false, false, true])
    }

    @Test("Skipped items alone are not a problem")
    func skippedItems() {
        var report = CleanupReport(dryRun: false)
        report.items = [(item, .skipped(reason: "Blocked: x", kind: .refused))]
        #expect(!report.hasProblems)
        #expect(!report.removedAnything)
    }

    @Test("Failed items, skipped or failed commands and warnings are problems")
    func problems() {
        var failed = CleanupReport(dryRun: false)
        failed.items = [(item, .failed(reason: "denied"))]
        #expect(failed.hasProblems)

        var skippedCommand = CleanupReport(dryRun: false)
        skippedCommand.commands = [(command, .skipped(reason: "'brew' is not installed", kind: .refused), "")]
        #expect(skippedCommand.hasProblems)
        #expect(skippedCommand.unfinishedCommands.map(\.reason) == ["'brew' is not installed"])

        var failedCommand = CleanupReport(dryRun: false)
        failedCommand.commands = [(command, .failed(reason: "Exited with status 1"), "oops")]
        #expect(failedCommand.hasProblems)

        var warned = CleanupReport(dryRun: false)
        warned.items = [(item, .removed(bytes: 1, trashedTo: nil))]
        warned.warnings = ["Couldn't write to the journal"]
        #expect(warned.hasProblems)
        #expect(warned.removedAnything)

        var changed = CleanupReport(dryRun: false)
        changed.items = [(item, .changedSinceReview("This folder is a git repository (source code)"))]
        #expect(changed.hasProblems)

        var notAccepted = CleanupReport(dryRun: false)
        notAccepted.items = [(item, .notAccepted("No SpaceKit rule recognises this; make sure you don't need it"))]
        #expect(notAccepted.hasProblems)
    }

    @Test("Whether a skipped item is a problem comes from its kind, never from its wording")
    func skipKindDecides() {
        var lookalike = CleanupReport(dryRun: false)
        lookalike.items = [(item, .skipped(reason: CleanupExecutor.changedSinceReview + "x", kind: .refused))]
        #expect(!lookalike.hasProblems)
        #expect(SkipKind.allCases.filter(\.isProblem) == [.changedSinceReview, .notAccepted])
    }

    @Test("Skip reasons read as before: the kind's words, then why")
    func skipWording() {
        #expect(CleanupOutcome.changedSinceReview("x") == .skipped(reason: "Changed since you reviewed it: x", kind: .changedSinceReview))
        #expect(CleanupOutcome.notAccepted("y") == .skipped(reason: "Warnings not accepted: y", kind: .notAccepted))
        #expect(
            CleanupExecutor.outdatedReview
                == "Changed since you reviewed it: SpaceKit's settings changed after the review. Review it again.")
    }

    @Test("A command that ran counts as removing something even if it freed nothing")
    func commandRan() {
        var report = CleanupReport(dryRun: false)
        report.commands = [(command, .removed(bytes: 0, trashedTo: nil), "")]
        #expect(report.removedAnything)
        #expect(!report.hasProblems)
    }
}

@Suite("Shell words")
struct ShellWordsTests {
    @Test(
        "Splits like a POSIX shell without running one",
        arguments: [
            ("nano", ["nano"]),
            ("code --wait", ["code", "--wait"]),
            ("  subl   -w  ", ["subl", "-w"]),
            ("'/Applications/My Editor.app/x' -w", ["/Applications/My Editor.app/x", "-w"]),
            ("\"a b\" c\\ d", ["a b", "c d"]),
            ("\"say \\\"hi\\\"\"", ["say \"hi\""]),
            ("'it''s'", ["its"]),
            ("vim -c 'set ft=yaml'", ["vim", "-c", "set ft=yaml"]),
            ("''", [""]),
        ])
    func splits(input: String, expected: [String]) {
        #expect(ShellWords.split(input) == expected)
    }

    @Test("Unterminated quotes and trailing escapes are rejected", arguments: ["'open", "\"open", "trailing\\"])
    func rejects(input: String) {
        #expect(ShellWords.split(input) == nil)
    }

    @Test("Blank input has no words")
    func blank() {
        #expect(ShellWords.split("   ") == [])
    }
}

@Suite("Path arguments")
struct PathArgumentTests {
    @Test("Keeps spaces and dollar signs that are part of the name")
    func keepsName() {
        #expect(PathUtil.expandArgument("/tmp/report ", home: "/Users/t") == "/tmp/report ")
        #expect(PathUtil.expandArgument(" /tmp/x", home: "/Users/t") == FileManager.default.currentDirectoryPath + "/ /tmp/x")
        #expect(PathUtil.expandArgument("/tmp/$HOME", home: "/Users/t") == "/tmp/$HOME")
    }

    @Test("Expands a leading tilde and makes relative paths absolute")
    func expands() {
        #expect(PathUtil.expandArgument("~", home: "/Users/t") == "/Users/t")
        #expect(PathUtil.expandArgument("~/a/../b", home: "/Users/t") == "/Users/t/b")
        #expect(PathUtil.expandArgument("x", home: "/Users/t") == FileManager.default.currentDirectoryPath + "/x")
    }
}
