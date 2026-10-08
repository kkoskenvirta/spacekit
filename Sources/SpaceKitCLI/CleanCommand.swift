import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Preview and run a cleanup by rule id or path. Previews by default; add --yes to clean.",
        discussion: """
            Examples:
              spacekit clean xcode.derived-data --keep-recent 14d
              spacekit clean node.node-modules --older-than 60d
              spacekit clean --safety safe                 everything regenerable
              spacekit clean ~/Downloads/old-vm.utm        a specific path (asks for confirmation)

            Removed items go to the Trash unless your config sets safety.trash: rules and the rule allows deletion,
            or you pass --permanent. With safety.trash: always, --permanent is refused. Paths you name go to the
            Trash unless you pass --permanent. Every item is checked by the safety guard; blocked items are listed
            and skipped. On a terminal you're asked after the preview, and answering yes accepts its warnings. --yes
            runs without asking, but only what the guard allows outright; items with warnings (paths no rule
            recognises, review rules, repositories) also need --accept-warnings. The exit status is nonzero when
            anything failed, a row's warnings weren't accepted or a warning was raised.
            """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Rule ids or paths.")
    var targets: [String] = []
    @Option(name: .long, help: "Only rules with this safety level: safe or review.")
    var safety: SafetyLevel?
    @Option(name: .long, help: "Only items unused for at least this long (e.g. 60d). Rule ids only.", transform: Parse.retention)
    var olderThan: Age?
    @Option(name: .long, help: "Keep items used within this window (e.g. 14d). Rule ids only.", transform: Parse.retention)
    var keepRecent: Age?
    @Flag(name: .long, help: "Delete permanently instead of moving to the Trash.")
    var permanent = false
    @OptionGroup var acknowledgement: AcknowledgementOptions
    @Flag(name: .long, help: "Machine-readable plan and result on stdout; the preview goes to stderr.")
    var json = false

    func validate() throws {
        guard !targets.isEmpty || safety != nil else {
            throw ValidationError("Name rule ids or paths to clean, or use --safety safe. See `spacekit dev`.")
        }
        if safety == .protected { throw ValidationError("--safety must be safe or review") }
    }

    func run() throws {
        let started = Date()
        let context = global.loadContext()
        if permanent && context.config.safety.trashesEverything {
            throw ValidationError("--permanent is turned off because your config sets safety.trash: always.")
        }
        let (rules, paths) = try resolve(targets, in: context)
        if !paths.isEmpty && (olderThan != nil || keepRecent != nil) {
            throw ValidationError("--older-than and --keep-recent filter what rules find; they can't apply to the paths you named.")
        }

        var plan = try rulePlan(rules, context: context)
        if !paths.isEmpty {
            let index = context.ruleIndex
            plan.items += try paths.map { try pathItem($0, context: context, index: index, scanStarted: started) }
            // A path someone names isn't covered by a rule's permission to delete.
            plan.useTrash = !permanent
        }

        guard !plan.isEmpty || !plan.manualSteps.isEmpty else {
            if json {
                try Output.json(RunJSON(plan: PlanJSON(CleanupReview(plan, executor: context.executor))))
            } else {
                print("Nothing to clean.")
            }
            return
        }
        guard
            let report = try CleanupOutput.session(
                plan, executor: context.executor, acknowledgement: acknowledgement, json: json, interactive: true,
                hint: "Preview only. Run again with --yes to clean.")
        else { return }
        try CleanupOutput.exitIfProblems(report)
    }

    /// Splits targets into rules (named or by `--safety`) and absolute paths.
    private func resolve(_ targets: [String], in context: SpaceKitContext) throws -> (rules: [Rule], paths: [String]) {
        var rules: [Rule] = []
        var paths: [String] = []
        for target in targets {
            if let rule = context.library.rule(id: target) {
                rules.append(rule)
                continue
            }
            let path = PathUtil.expandArgument(target)
            var st = stat()
            guard target.hasPrefix("/") || target.hasPrefix("~") || target.hasPrefix(".") || lstat(path, &st) == 0 else {
                throw ValidationError("'\(Output.safe(target))' is neither a rule id nor an existing path. See `spacekit rules list`.")
            }
            paths.append(path)
        }
        if let safety {
            rules += context.library.rules.filter { $0.safety.level == safety && $0.action.isCleanable && !rules.contains($0) }
        }
        return (rules, paths)
    }

    private func rulePlan(_ rules: [Rule], context: SpaceKitContext) throws -> CleanupPlan {
        guard !rules.isEmpty else { return CleanupPlan() }
        let analysis = try ProgressReporter.run("Analysing") { try context.analyzer.analyzeSync(rules: rules, progress: $0) }
        for finding in analysis.findings where !finding.isCleanable {
            Output.warn(Output.safe(finding.rule.name + " is report-only" + (finding.rule.action.manual.map { ": \($0)" } ?? "")))
        }
        return CleanupPlan.make(
            findings: analysis.findings.filter(\.isCleanable),
            trashPreference: permanent ? false : context.trashPreference(for: .rule),
            scanStarted: analysis.scanStarted
        ) { finding in
            finding.eligibleItems(olderThan: olderThan, keepRecent: keepRecent)
        }
    }

    /// One named path as a plan item. A symlink is the link itself, measured as such, because that is what the
    /// executor removes. `scanStarted` is when the command started, before the path was looked at.
    private func pathItem(_ path: String, context: SpaceKitContext, index: RuleIndex, scanStarted: Date) throws -> CleanupItem {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ValidationError("No such file or folder: \(Output.safe(path))") }
        let isFolder = (st.st_mode & S_IFMT) == S_IFDIR
        let kind: FindingItem.Kind = isFolder ? .directory : .file
        let rule = index.rule(for: path)
        // Ask the guard about the location before measuring, so `clean /` doesn't scan the whole disk just to refuse.
        // The review judges the item, size and repositories included, once it's measured.
        if context.safetyGuard.locationRefusal(of: path, rule: rule, context: .manual) != nil {
            return CleanupItem(path: path, kind: kind, size: 0, ruleID: rule?.id, scanStarted: scanStarted)
        }
        var options = context.scanOptions
        options.minFileSize = .max
        guard isFolder, let tree = try? Scanner(options: options).scan(path) else {
            return CleanupItem(path: path, kind: kind, size: FileSize.allocated(st), ruleID: rule?.id, scanStarted: scanStarted)
        }
        let repository = tree.root.repositoryFlags(tree.markers)
        return CleanupItem(
            path: path, kind: .directory, size: tree.root.size, ruleID: rule?.id,
            isRepository: repository.isRepository, containsRepository: repository.containsRepository, scanStarted: scanStarted)
    }
}
