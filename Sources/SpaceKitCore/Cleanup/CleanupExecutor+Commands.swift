import Foundation

extension CleanupExecutor {
    /// Checks one tool command without running it: the same gates as items (root, config, rule safety, the guard
    /// for the item an `itemCommand` names), plus which executables may run at all.
    public func verdict(for command: PlannedCommand, context: CleanupContext) -> SafetyVerdict {
        var verdict = SafetyVerdict.allow
        refuseIfConfigInvalid(&verdict)
        if safety.isRunningAsRoot {
            verdict.raise(.block, "SpaceKit never runs cleanup commands as root (sudo)")
        }
        guard let rule = rules[command.ruleID] else {
            verdict.raise(.block, "Rule \(command.ruleID) isn't active any more; refresh the plan")
            return verdict
        }
        if expectedArguments(for: command, rule: rule) != command.arguments {
            verdict.raise(.block, "The command no longer matches rule \(rule.id); refresh the plan")
        }
        checkExecutable(command.arguments.first ?? "", rule: rule, into: &verdict)
        if let model = command.modelName, model.isEmpty || model.hasPrefix("-") {
            verdict.raise(.block, "'\(model)' isn't a model name the tool can be given safely")
        }

        if let itemPath = command.itemPath {
            let item = safety.evaluate(
                path: itemPath, size: command.estimatedBytes, rule: rule, context: context,
                isRepository: RepositoryProbe.isRepository(itemPath), containsRepository: RepositoryProbe.containsRepository(itemPath))
            verdict = verdict.merging(item)
        } else {
            switch rule.safety.level {
            case .protected:
                verdict.raise(.block, "\(rule.name) is marked “Don't touch”")
            case .review:
                if case .automatic(let automation) = context {
                    if !automation.allowReview { verdict.raise(.block, "\(rule.name) needs review; the job doesn't include review items") }
                } else {
                    verdict.raise(.confirm, "\(rule.name) is marked “Review”: it can be run but may be slow or costly to undo")
                }
            case .safe:
                break
            }
        }
        return verdict
    }

    /// What the rule says this command is now. A plan's command that differs (an edited rule, an old suggestion)
    /// doesn't run.
    func expectedArguments(for command: PlannedCommand, rule: Rule) -> [String]? {
        if let itemPath = command.itemPath {
            return rule.action.itemCommand.map { CleanupPlan.itemArguments($0, path: itemPath) }
        }
        if let model = command.modelName {
            return rule.ai?.removeArguments(forModel: model)
        }
        return rule.action.command
    }

    /// Built-in rules may use `RuleLibrary.trustedCommands`; every other rule only `safety.allowedCommands`.
    private func checkExecutable(_ executable: String, rule: Rule, into verdict: inout SafetyVerdict) {
        guard Shell.isBareName(executable) else {
            verdict.raise(.block, "Commands must name a tool by its bare name, not a path: '\(executable)'")
            return
        }
        if extraAllowedCommands.contains(executable) { return }
        if rule.isBuiltin {
            if !RuleLibrary.trustedCommands.contains(executable) {
                verdict.raise(.block, "'\(executable)' isn't a trusted command; add it to safety.allowedCommands to allow it")
            }
        } else {
            verdict.raise(.block, RuleLibrary.untrustedRuleCommand(executable))
        }
    }

    func runCommand(_ command: PlannedCommand, context: CleanupContext, run: inout Run) -> (CleanupOutcome, String) {
        let verdict = verdict(for: command, context: context)
        guard verdict.permits(confirmed: CleanupExecutor.isConfirmed(context)) else { return (CleanupExecutor.refusal(verdict), "") }
        if context.isAutomatic && (run.budget == 0 || command.estimatedBytes > run.budget) { return (overBudget(), "") }
        let name = command.arguments[0]
        guard let executable = Shell.which(name) else { return (.skipped(reason: "'\(name)' is not installed"), "") }
        if run.dryRun { return (.wouldRemove(bytes: command.estimatedBytes), "") }

        let before = measure(command.measurePaths) ?? 0
        let result = Shell.run(executable, Array(command.arguments.dropFirst()), timeout: CleanupExecutor.commandTimeout)
        if result.timedOut {
            return (.failed(reason: "Stopped after \(Int(CleanupExecutor.commandTimeout)) seconds"), result.output)
        }
        guard result.status == 0 else {
            return (.failed(reason: "Exited with status \(result.status)"), result.output)
        }
        let after = measure(command.measurePaths) ?? before
        let freed = before > after ? before - after : 0
        run.charge(freed)
        record(entry(path: command.displayString, bytes: freed, method: .command, ruleID: command.ruleID, context: context), in: &run)
        return (.removed(bytes: freed, trashedTo: nil), result.output)
    }
}
