import Foundation

extension CleanupExecutor {
    /// Checks one tool command without running it: the same gates as items (root, config, rule safety, the guard
    /// for the item an `itemCommand` names), plus which executables may run at all, judged at the place its tool is
    /// found now.
    public func verdict(for command: PlannedCommand, context: CleanupContext) -> SafetyVerdict {
        verdict(for: command, context: context, executable: runner.locate(command.arguments.first ?? ""), item: itemTarget(of: command))
    }

    /// The item an `itemCommand` acts on, read from the disk now; `nil` for a command of a whole rule or a model.
    func itemTarget(of command: PlannedCommand) -> RemovalTarget? {
        command.itemPath.map { path in
            RemovalTarget.at(
                path, home: safety.home, size: command.estimatedBytes, isRepository: false, containsRepository: false,
                probingRepositories: true, resolve: resolve)
        }
    }

    /// `executable`: where the command's tool is found, the program a run would start; `nil` when it isn't installed.
    /// `item`: the command's `itemTarget(of:)`, read once by the caller, which also binds a review to its location.
    func verdict(for command: PlannedCommand, context: CleanupContext, executable: String?, item: RemovalTarget?) -> SafetyVerdict {
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
        for reason in commandTrust.refusals(command, rule: rule, context: context) { verdict.raise(.block, reason) }
        if let refusal = commandTrust.programRefusal(command, rule: rule, at: executable, runner: runner) { verdict.raise(.block, refusal) }
        let automatic = commandTrust.automaticRefusal(
            command.arguments, at: executable, context: context, searchPath: runner.searchPath, changeable: changeable,
            developerFolderLink: developerFolderLink)
        if let refusal = automatic {
            verdict.raise(.block, refusal)
        }
        if item == nil, context.isAutomatic, let refusal = CommandTrust.linkedPathRefusal(rule, home: safety.home) {
            verdict.raise(.block, refusal)
        }
        if let warning = commandTrust.ownRuleWarning(command, rule: rule, context: context, at: executable) {
            verdict.raise(.confirm, warning)
        }

        if let item {
            verdict = verdict.merging(safety.evaluate(item, rule: rule, context: context))
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

    /// Why a reviewed command doesn't run: its tool isn't found where the review found it.
    static func foundElsewhere(_ name: String, now executable: String?) -> String {
        let now = executable.map { "is found at \(TerminalText.sanitize($0)) now" } ?? "isn't installed any more"
        return "'\(TerminalText.sanitize(name))' \(now), not where you reviewed it"
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

    /// `reviewed`: what the person's review showed for this command; `nil` in an automatic run.
    ///
    /// The tool is looked up once: the verdict judges the program found, and that program is the one started. So is the
    /// item an `itemCommand` names: a reviewed command runs only while the item is at the location the review judged.
    func runCommand(
        _ command: PlannedCommand, context: CleanupContext, reviewed: ReviewRecord.Row?, run: inout Run
    ) -> (CleanupOutcome, String) {
        let name = command.arguments.first ?? ""
        let found = runner.locate(name)
        if let reviewed, reviewed.executable != found {
            return (.changedSinceReview(CleanupExecutor.foundElsewhere(name, now: found)), "")
        }
        let item = itemTarget(of: command)
        if let reviewed, reviewed.location != item?.location {
            return (.changedSinceReview(CleanupExecutor.notWhereReviewed), "")
        }
        let verdict = verdict(for: command, context: context, executable: found, item: item)
        if let refused = CleanupExecutor.refusal(verdict, reviewed: reviewed) { return (refused, "") }
        if context.isAutomatic && (run.budget == 0 || command.estimatedBytes > run.budget) { return (overBudget(), "") }
        guard let executable = found else { return (.skipped(reason: "'\(name)' is not installed", kind: .refused), "") }
        let kind: Shell.RunKind = context.isAutomatic ? .automatic : .manual
        let docker = DockerCLI(path: executable, runner: runner, kind: kind)
        if name == "docker", let refusal = commandTrust.dockerRefusal(command.arguments, docker: docker) {
            return (.skipped(reason: refusal, kind: .refused), "")
        }
        if run.dryRun { return (.wouldRemove(bytes: command.estimatedBytes), "") }

        let before = measure(command.measurePaths) ?? 0
        let result = runner.run(
            executable, Array(command.arguments.dropFirst()), timeout: CleanupExecutor.commandTimeout, separateErrors: false, kind: kind)
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
