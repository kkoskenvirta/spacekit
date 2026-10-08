import Foundation

public enum CleanupOutcome: Sendable, Equatable {
    case removed(bytes: UInt64, trashedTo: String?)
    /// Dry run: what would have happened.
    case wouldRemove(bytes: UInt64)
    case skipped(reason: String)
    case failed(reason: String)

    /// Bytes taken off their original location (deleted, or moved to the Trash).
    public var freedBytes: UInt64 {
        if case .removed(let bytes, _) = self { return bytes }
        return 0
    }

    public var isRemoved: Bool {
        if case .removed = self { return true }
        return false
    }

    public var isWouldRemove: Bool {
        if case .wouldRemove = self { return true }
        return false
    }

    public var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Where a trashed item went. `nil` if it was deleted permanently (or not removed).
    public var trashedTo: String? {
        if case .removed(_, let trashedTo) = self { return trashedTo }
        return nil
    }
}

public struct CleanupReport: Sendable {
    public var items: [(item: CleanupItem, outcome: CleanupOutcome)] = []
    public var commands: [(command: PlannedCommand, outcome: CleanupOutcome, output: String)] = []
    public var dryRun: Bool
    /// Problems that didn't stop an item but must not go unnoticed: journal writes that failed, and loose
    /// files that couldn't be removed while the rest of their folder was.
    public var warnings: [String] = []
    /// Trash destinations of loose files moved to the Trash, keyed by the folder (the loose-files item's `path`).
    public var trashedLooseFiles: [String: [String]] = [:]
    /// Bytes deleted from items that failed part way, keyed by the item's `path`. Their outcome is `.failed`; these
    /// bytes are gone all the same, so they count in `freedBytes` and were journaled and charged to the budget.
    public var partiallyFreed: [String: UInt64] = [:]

    /// Everything taken off its original location, including what went to the Trash.
    public var freedBytes: UInt64 {
        let itemBytes = items.reduce(0) { $0 &+ $1.outcome.freedBytes }
        let commandBytes = commands.reduce(0) { $0 &+ $1.outcome.freedBytes }
        let partialBytes = partiallyFreed.values.reduce(0, &+)
        return itemBytes &+ commandBytes &+ partialBytes
    }

    /// Moved to the Trash: still using disk space until the Trash is emptied.
    public var trashedBytes: UInt64 {
        items.reduce(0) { $0 &+ ($1.outcome.trashedTo != nil ? $1.outcome.freedBytes : 0) }
    }

    /// Actually released: deleted permanently or removed by tool commands. (On a Mac with local Time Machine
    /// snapshots this shows up as purgeable space first; see `VolumeCapacity`.)
    public var deletedBytes: UInt64 { freedBytes - trashedBytes }

    /// "Freed 1.0 GB", "Moved 4.0 GB to the Trash", or both. Never calls trashed bytes "freed".
    public var summary: String {
        var parts: [String] = []
        if deletedBytes > 0 || trashedBytes == 0 { parts.append("Freed \(ByteCount.format(deletedBytes))") }
        if trashedBytes > 0 { parts.append("\(parts.isEmpty ? "Moved" : "moved") \(ByteCount.format(trashedBytes)) to the Trash") }
        return parts.joined(separator: " and ")
    }

    public var skipped: [(item: CleanupItem, reason: String)] {
        items.compactMap { entry in
            if case .skipped(let reason) = entry.outcome { return (entry.item, reason) }
            return nil
        }
    }

    public var failures: [(item: CleanupItem, reason: String)] {
        items.compactMap { entry in
            if case .failed(let reason) = entry.outcome { return (entry.item, reason) }
            return nil
        }
    }
}

/// Carries out cleanup plans. Every item is re-checked by the `SafetyGuard` immediately before it is
/// touched, every removal is journaled as it happens, and automatic runs stop at the configured byte budget.
public struct CleanupExecutor: Sendable {
    public var safety: SafetyGuard
    public var journal: Journal?
    public var rules: [String: Rule]
    /// Executables allowed beyond `RuleLibrary.trustedCommands`. The only executables rules from outside the
    /// built-in library may run.
    public var extraAllowedCommands: Set<String>
    /// Upper bound for one automatic run.
    public var maxBytesPerAutomaticRun: UInt64
    /// Set when the config file exists but couldn't be read. Every removal and command is then refused, because
    /// the defaults in use lack the person's protected paths, allowed commands and disabled rules.
    public var configError: String?
    /// `safety.trash: always`: items are moved to the Trash even when a plan asks to delete them. Entries already in
    /// the Trash can still be deleted (that's emptying it).
    public var alwaysTrash: Bool
    /// Moves a path to the Trash and returns where it went.
    var trash: @Sendable (String) throws -> String? = CleanupExecutor.moveToTrash
    /// Resolves the folder an item is removed from. Tests replace it to swap symlinks at the worst moment.
    var resolve: @Sendable (String) -> String? = PathUtil.realpath

    public static let commandTimeout: TimeInterval = 600

    public init(
        safety: SafetyGuard, journal: Journal?, rules: [Rule], extraAllowedCommands: Set<String> = [],
        maxBytesPerAutomaticRun: UInt64 = ByteCount.gb(100).bytes, configError: String? = nil, alwaysTrash: Bool = false
    ) {
        self.safety = safety
        self.journal = journal
        self.rules = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.extraAllowedCommands = extraAllowedCommands
        self.maxBytesPerAutomaticRun = maxBytesPerAutomaticRun
        self.configError = configError
        self.alwaysTrash = alwaysTrash
    }

    /// Checks one item without touching it, using what the plan recorded about it.
    public func verdict(for item: CleanupItem, context: CleanupContext) -> SafetyVerdict {
        verdict(
            for: item, size: item.size, isRepository: item.isRepository, containsRepository: item.containsRepository, context: context)
    }

    /// `checkedDirectory`: the resolved folder the removal will act in. The item is judged there too, so the guard
    /// has seen the exact location that changes, whatever a symlink in the item's path points at by then.
    func verdict(
        for item: CleanupItem, size: UInt64, isRepository: Bool, containsRepository: Bool, context: CleanupContext,
        checkedDirectory: String? = nil
    ) -> SafetyVerdict {
        let rule = item.ruleID.flatMap { rules[$0] }
        // Loose files are judged as "something inside the folder", not as the folder itself.
        let path = item.kind == .looseFiles ? CleanupItem.looseFilesPath(in: item.path) : item.path
        let name = item.kind == .looseFiles ? "*" : PathUtil.lastComponent(item.path)
        var verdict = CleanupExecutor.judge(path, checked: checkedDirectory.map { PathUtil.join($0, name) }) { candidate in
            safety.evaluate(
                path: candidate, size: size, rule: rule, context: context, isRepository: isRepository,
                containsRepository: containsRepository)
        }
        refuseIfConfigInvalid(&verdict)
        return verdict
    }

    /// The verdict on `path` and, if it's spelled differently, on the same entry in the folder that was resolved
    /// and checked: the guard sees the exact location that changes, whatever a symlink in `path` points at by then.
    static func judge(_ path: String, checked: String?, _ evaluate: (String) -> SafetyVerdict) -> SafetyVerdict {
        let verdict = evaluate(path)
        guard let checked, checked != path else { return verdict }
        return verdict.merging(evaluate(checked))
    }

    func refuseIfConfigInvalid(_ verdict: inout SafetyVerdict) {
        if let configError {
            verdict.raise(.block, "Config file is invalid: \(configError). Fix it (spacekit config validate) before cleaning.")
        }
    }

    public func execute(
        _ plan: CleanupPlan,
        context: CleanupContext,
        dryRun: Bool,
        onProgress: (@Sendable (_ completed: Int, _ total: Int, _ current: String) -> Void)? = nil
    ) -> CleanupReport {
        var run = Run(report: CleanupReport(dryRun: dryRun), budget: context.isAutomatic ? maxBytesPerAutomaticRun : .max)
        let total = plan.items.count + plan.commands.count
        var completed = 0

        for item in plan.items {
            onProgress?(completed, total, item.path)
            completed += 1
            let outcome = removeItem(item, plan: plan, context: context, run: &run)
            run.report.items.append((item, outcome))
        }
        for command in plan.commands {
            onProgress?(completed, total, command.displayString)
            completed += 1
            let (outcome, output) = runCommand(command, context: context, run: &run)
            run.report.commands.append((command, outcome, output))
        }
        onProgress?(total, total, "")
        return run.report
    }

    /// State carried through one execution.
    struct Run {
        var report: CleanupReport
        var budget: UInt64
        var dryRun: Bool { report.dryRun }

        mutating func charge(_ bytes: UInt64) { budget -= min(budget, bytes) }
    }

    /// Writes one journal entry right away, so a run that is interrupted still leaves a record of what it removed.
    func record(_ entry: JournalEntry, in run: inout Run) {
        guard let journal, !run.dryRun else { return }
        do {
            try journal.append([entry])
        } catch {
            run.report.warnings.append(
                "Couldn't write to the journal \(PathUtil.abbreviate(journal.file)): \(error.localizedDescription). "
                    + "\(PathUtil.abbreviate(entry.path)) was removed but isn't recorded there.")
        }
    }

    func entry(
        path: String, bytes: UInt64, method: JournalEntry.Method, ruleID: String?, context: CleanupContext, trashedTo: String? = nil
    ) -> JournalEntry {
        JournalEntry(
            path: path, bytes: bytes, method: method, ruleID: ruleID, jobID: CleanupExecutor.jobID(context),
            automatic: context.isAutomatic, trashedTo: trashedTo)
    }

    static func isConfirmed(_ context: CleanupContext) -> Bool {
        if case .manual(let confirmed) = context { return confirmed }
        return false
    }

    static func jobID(_ context: CleanupContext) -> String? {
        if case .automatic(let automation) = context { return automation.jobID }
        return nil
    }

    static func refusal(_ verdict: SafetyVerdict) -> CleanupOutcome {
        let prefix = verdict.decision == .confirm ? "Needs confirmation: " : "Blocked: "
        return .skipped(reason: prefix + verdict.reasons.joined(separator: "; "))
    }

    func overBudget() -> CleanupOutcome {
        .skipped(reason: "Over this run's budget of \(ByteCount.format(maxBytesPerAutomaticRun)) (safety.maxBytesPerRun)")
    }

    static func moveToTrash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }
}
