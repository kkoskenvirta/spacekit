import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Cleanup execution: tool commands")
struct CleanupCommandTests {
    enum Origin { case builtin, user }

    func rule(
        _ tree: TempTree, id: String = "tool", level: SafetyLevel = .safe, origin: Origin, command: [String]? = nil,
        itemCommand: [String]? = nil, paths: [String] = []
    ) -> Rule {
        var rule = Rule(
            id: id, name: id, paths: paths.map { tree.path($0) }, granularity: .children, safety: SafetySpec(level: level),
            action: ActionSpec(command: command, itemCommand: itemCommand))
        rule.source = tree.path(origin == .builtin ? "builtin-rules/tools.yaml" : "user-rules/tools.yaml")
        rule.isBuiltin = origin == .builtin
        return rule
    }

    func outcome(_ report: CleanupReport) -> CleanupOutcome? { report.commands.first?.outcome }

    func isSkipped(_ outcome: CleanupOutcome?, mentioning text: String? = nil) -> Bool {
        guard case .skipped(let reason) = outcome else { return false }
        return text.map { reason.localizedCaseInsensitiveContains($0) } ?? true
    }

    func wouldRun(_ outcome: CleanupOutcome?) -> Bool {
        if case .wouldRemove = outcome { return true }
        return false
    }

    @Test("Only bare executable names run, even when the name is allowed")
    func bareNamesOnly() throws {
        let tree = try TempTree()
        let victim = try tree.file("home/keep.txt", bytes: 100)
        for executable in ["/bin/rm", "../../../../../../bin/rm", "bin/rm"] {
            let arguments = [executable, "-f", victim]
            let tool = rule(tree, origin: .user, command: arguments)
            let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 1)])
            let report = sandboxExecutor(tree, rules: [tool], allowed: ["rm"]).execute(plan, context: .manual(confirmed: true), dryRun: false)
            #expect(isSkipped(outcome(report), mentioning: "name"), "\(executable)")
            #expect(onDisk(victim))
        }
    }

    @Test("Shell.which resolves bare names only, and never from relative PATH entries")
    func which() {
        #expect(Shell.which("/bin/ls") == nil)
        #expect(Shell.which("../bin/ls") == nil)
        #expect(Shell.which("") == nil)
        #expect(Shell.which("ls")?.hasSuffix("/ls") == true)
        let path = Shell.searchPath(environmentPATH: ".:bin::/usr/bin", home: "/Users/tester")
        #expect(path.allSatisfy { $0.hasPrefix("/") })
        #expect(path.contains("/usr/bin"))
    }

    @Test("Built-in trust covers built-in rules only; other rules need safety.allowedCommands")
    func builtinTrust() throws {
        let tree = try TempTree()
        let arguments = ["swift", "--version"]
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 1)])
        let user = rule(tree, origin: .user, command: arguments)
        let builtin = rule(tree, origin: .builtin, command: arguments)
        let refused = sandboxExecutor(tree, rules: [user]).execute(plan, context: .manual(confirmed: true), dryRun: true)
        #expect(isSkipped(outcome(refused), mentioning: "allowedCommands"))
        // Validation warns with the words the executor refuses with.
        let warning = RuleLibrary.issues(for: user).first { $0.severity == .warning }?.message ?? ""
        #expect(isSkipped(outcome(refused), mentioning: warning))
        let trusted = sandboxExecutor(tree, rules: [builtin]).execute(plan, context: .manual(confirmed: true), dryRun: true)
        #expect(wouldRun(outcome(trusted)))
        let allowed = sandboxExecutor(tree, rules: [user], allowed: ["swift"]).execute(plan, context: .manual(confirmed: true), dryRun: true)
        #expect(wouldRun(outcome(allowed)))
    }

    @Test("A command whose rule is gone, or that no longer matches its rule, is refused")
    func ruleMustMatch() throws {
        let tree = try TempTree()
        let builtin = rule(tree, origin: .builtin, command: ["swift", "--version"])
        let itemRule = rule(tree, id: "items", origin: .builtin, itemCommand: ["swift", "{name}"])
        let plan = CleanupPlan(commands: [
            PlannedCommand(ruleID: "gone", arguments: ["swift", "--version"], estimatedBytes: 1),
            PlannedCommand(ruleID: "tool", arguments: ["swift", "build"], estimatedBytes: 1),
            PlannedCommand(ruleID: "items", arguments: ["swift", "x"], estimatedBytes: 1),
        ])
        let report = sandboxExecutor(tree, rules: [builtin, itemRule]).execute(plan, context: .manual(confirmed: true), dryRun: true)
        #expect(report.commands.count == 3)
        #expect(report.commands.allSatisfy { isSkipped($0.outcome) })
    }

    @Test("Commands are refused as root and with an invalid config")
    func rootAndConfig() throws {
        let tree = try TempTree()
        let arguments = ["swift", "--version"]
        let builtin = rule(tree, origin: .builtin, command: arguments)
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 1)])
        let asRoot = sandboxExecutor(tree, rules: [builtin], root: true).execute(plan, context: .manual(confirmed: true), dryRun: true)
        #expect(isSkipped(outcome(asRoot), mentioning: "root"))
        let badConfig = sandboxExecutor(tree, rules: [builtin], configError: "bad")
            .execute(plan, context: .manual(confirmed: true), dryRun: true)
        #expect(isSkipped(outcome(badConfig), mentioning: "Config file is invalid"))
    }

    @Test("Review commands need confirmation by hand")
    func reviewNeedsConfirmation() throws {
        let tree = try TempTree()
        let arguments = ["swift", "--version"]
        let review = rule(tree, level: .review, origin: .builtin, command: arguments)
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 1)])
        let executor = sandboxExecutor(tree, rules: [review])
        #expect(isSkipped(outcome(executor.execute(plan, context: .manual(confirmed: false), dryRun: true))))
        #expect(wouldRun(outcome(executor.execute(plan, context: .manual(confirmed: true), dryRun: true))))
    }

    @Test("Automatic runs don't start commands beyond the byte budget")
    func commandBudget() throws {
        let tree = try TempTree()
        let arguments = ["swift", "--version"]
        let builtin = rule(tree, origin: .builtin, command: arguments)
        let big = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 20_000)])
        let context = CleanupContext.automatic(AutomationContext(jobID: "j"))
        let over = sandboxExecutor(tree, rules: [builtin], budget: ByteCount(10_000)).execute(big, context: context, dryRun: true)
        #expect(isSkipped(outcome(over), mentioning: "budget"))
        let small = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 0)])
        let exhausted = sandboxExecutor(tree, rules: [builtin], budget: ByteCount(0)).execute(small, context: context, dryRun: true)
        #expect(isSkipped(outcome(exhausted), mentioning: "budget"))
    }

    @Test("Per-item commands name the item, and the item passes the safety guard")
    func itemCommands() throws {
        let tree = try TempTree()
        try tree.directory("home/toolchains/stable")
        try tree.directory("home/.ssh/keys")
        let items = rule(tree, level: .review, origin: .builtin, itemCommand: ["swift", "{name}", "{path}"], paths: ["home/toolchains"])
        let finding = Finding(
            rule: items,
            items: [
                FindingItem(path: tree.path("home/toolchains/stable"), kind: .directory, name: "shown/stable", size: 10),
                FindingItem(path: tree.path("home/.ssh/keys"), kind: .directory, name: "keys", size: 10),
            ])
        let plan = CleanupPlan.make(findings: [finding])
        let toolchain = try #require(plan.commands.first { $0.itemPath == tree.path("home/toolchains/stable") })
        #expect(toolchain.arguments == ["swift", "stable", tree.path("home/toolchains/stable")])
        let report = sandboxExecutor(tree, rules: [items]).execute(plan, context: .manual(confirmed: true), dryRun: true)
        for (command, outcome, _) in report.commands {
            if command.itemPath == tree.path("home/.ssh/keys") {
                #expect(isSkipped(outcome, mentioning: "Blocked"))
            } else {
                #expect(wouldRun(outcome))
            }
        }
    }

    @Test("A successful command is measured and journaled")
    func commandSuccess() throws {
        let tree = try TempTree()
        let target = try tree.file("home/cache/blob", bytes: 64_000)
        let arguments = ["rm", "-f", target]
        let tool = rule(tree, origin: .user, command: arguments)
        let plan = CleanupPlan(
            commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 64_000, measurePaths: [tree.path("home/cache")])])
        let report = sandboxExecutor(tree, rules: [tool], allowed: ["rm"]).execute(plan, context: .manual(confirmed: true), dryRun: false)
        let freed = try #require(outcome(report)?.freedBytes)
        #expect(freed >= 64_000)
        #expect(!onDisk(target))
        let entries = journalEntries(tree)
        #expect(entries.map(\.method) == [.command])
        #expect(entries.first?.bytes == freed)
    }
}

@Suite("Shell")
struct ShellTests {
    @Test("Runs a tool and returns its output and status")
    func output() {
        let result = Shell.run("/bin/sh", ["-c", "echo hi; exit 3"], timeout: 10)
        #expect(result.status == 3)
        #expect(result.output == "hi\n")
        #expect(!result.timedOut)
    }

    @Test("A background child holding the output pipe doesn't outlive the timeout")
    func backgroundChild() {
        let start = Date()
        let result = Shell.run("/bin/sh", ["-c", "sleep 8 & echo started"], timeout: 2)
        #expect(Date().timeIntervalSince(start) < 3.5)
        #expect(result.timedOut)
        #expect(result.output.contains("started"))
    }

    @Test("A tool that ignores SIGTERM is killed")
    func ignoresTerm() {
        let start = Date()
        let result = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 6"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 3.5)
        #expect(result.timedOut)
    }
}
