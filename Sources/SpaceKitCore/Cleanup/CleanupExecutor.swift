import Foundation

/// Why a row was left alone, as a value: reports decide what counts as a problem from it, never from the wording.
public enum SkipKind: Sendable, Equatable, CaseIterable {
    /// The check at removal time raised a reason the review didn't show, or the row isn't where the review judged it,
    /// or the review was made with another executor. The person never saw that, so it's a problem.
    case changedSinceReview
    /// The review showed warnings the person didn't accept: a selected row left undone, so it's a problem.
    case notAccepted
    /// Refused for a reason a preview shows too: the guard's verdict in an automatic run, which nobody acknowledges, a
    /// Docker endpoint, a tool that isn't installed.
    case refused
    /// Nothing is left to remove: the item is gone, or none of the loose files the scan saw are.
    case gone
    /// Not covered by the scan it came from: saved without what its scan saw, or changed since that scan.
    case notScanned
    /// Past an automatic run's byte budget.
    case overBudget

    /// The run didn't do something the person reviewed and said go to.
    public var isProblem: Bool { self == .changedSinceReview || self == .notAccepted }
}

public enum CleanupOutcome: Sendable, Equatable {
    case removed(bytes: UInt64, trashedTo: String?)
    /// Dry run: what would have happened.
    case wouldRemove(bytes: UInt64)
    /// Left alone. `reason` is what front ends show; `kind` is what they and the report decide by.
    case skipped(reason: String, kind: SkipKind)
    case failed(reason: String)

    /// A reviewed row skipped because of `detail`, which the review didn't show.
    static func changedSinceReview(_ detail: String) -> CleanupOutcome {
        .skipped(reason: CleanupExecutor.changedSinceReview + detail, kind: .changedSinceReview)
    }

    /// A reviewed row skipped because the person didn't accept the warnings `reasons` the review showed.
    static func notAccepted(_ reasons: String) -> CleanupOutcome {
        .skipped(reason: CleanupExecutor.notAccepted + reasons, kind: .notAccepted)
    }

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
    /// What a run left on purpose inside a loose-files item it otherwise removed: files the check at removal time
    /// refused, and files past an automatic run's budget. Shown like a refused item, and like one not a problem: the
    /// review judges the folder's files as a whole, so it couldn't have shown a reason that belongs to one file.
    public var notes: [String] = []
    /// Trash destinations of loose files moved to the Trash, keyed by the folder (the loose-files item's `path`).
    public var trashedLooseFiles: [String: [String]] = [:]
    /// Bytes deleted from items that failed part way, keyed by the item's `path`. Their outcome is `.failed`; these
    /// bytes are gone all the same, so they count in `freedBytes` and were journaled and charged to the budget.
    public var partiallyFreed: [String: UInt64] = [:]
    /// Folders left inside removed items because another volume is mounted on them, keyed by the item's `path`. The
    /// item's outcome is `.removed` with the bytes that went; its folder stays, holding the volume.
    public var leftOnOtherVolumes: [String: [String]] = [:]
    /// The plan was reviewed with another executor (the settings changed since), so nothing ran: every row is skipped
    /// with `CleanupExecutor.outdatedReview`. Review the plan again to run it.
    public var reviewOutdated = false

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
            if case .skipped(let reason, _) = entry.outcome { return (entry.item, reason) }
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
///
/// The settings are fixed when the executor is built (a context builds one per reading of the config), and the
/// executor is identified by that build: a `ReviewedPlan` runs only on the executor its review was made with.
public struct CleanupExecutor: Sendable {
    public internal(set) var safety: SafetyGuard
    public internal(set) var journal: Journal?
    public internal(set) var rules: [String: Rule]
    /// Which tool commands may run (`safety.allowedCommands` on top of the built-in trusted list).
    public internal(set) var commandTrust: CommandTrust
    /// Upper bound for one automatic run.
    public internal(set) var maxBytesPerAutomaticRun: UInt64
    /// Set when the config file exists but couldn't be read. Every removal and command is then refused, because
    /// the defaults in use lack the person's protected paths, allowed commands and disabled rules.
    public internal(set) var configError: String?
    /// `safety.trash: always`: items are moved to the Trash even when a plan asks to delete them. Entries already in
    /// the Trash can still be deleted (that's emptying it).
    public internal(set) var alwaysTrash: Bool
    /// Made once per built executor; copies share it. A review records it, so a plan reviewed under other settings
    /// (protected paths added, the Trash made mandatory, the config broken since) never runs under these.
    let executorID = UUID()
    /// Moves a path to the Trash and returns where it went.
    var trash: @Sendable (String) throws -> String? = CleanupExecutor.moveToTrash
    /// Resolves the folder an item is removed from. Tests replace it to swap symlinks at the worst moment.
    var resolve: @Sendable (String) -> String? = PathUtil.realpath
    /// Reads the device of a folder open while deleting. Tests can't mount a volume, so they replace it to stand one in.
    var device: SafeRemoval.DeviceReader = SafeRemoval.device(of:)
    /// Whether the volume of a folder open while trashing keeps a file's inode when the file moves. Tests can't make a
    /// FAT or exFAT volume, so they replace it to stand one in.
    var keepsInodes: @Sendable (Int32) -> Bool = SafeRemoval.keepsInodes(on:)
    /// Finds and runs tools. Tests replace it with a recorder, so trust and budget checks run without real tools.
    var runner: any ProcessRunner = SystemProcessRunner()
    /// What the person could change on the way to a tool, which keeps it out of automatic runs. Tests can't make files
    /// they don't own, so they replace it to stand in the system's folders.
    var changeable: @Sendable (String) -> String? = CommandTrust.changeablePart(of:)
    /// The link to the developer folder xcrun starts tools from. Tests can't choose the system's, so they stand in a link
    /// of their own.
    var developerFolderLink = CommandTrust.developerFolderLink
    /// Reads the mount table at the start of each run. The guard keeps the table it was built with, and a context
    /// (with its guard) lives as long as the app or TUI does; a run reads it again so a volume mounted since is still a
    /// mount point the guard refuses. `nil` keeps the guard's own table: tests hand the guard theirs.
    var readMounts: (@Sendable () -> VolumeTable)?

    public static let commandTimeout: TimeInterval = 600

    public init(
        safety: SafetyGuard, journal: Journal?, rules: [Rule], allowedCommands: Set<String> = [],
        maxBytesPerAutomaticRun: UInt64 = ByteCount.gb(100).bytes, configError: String? = nil, alwaysTrash: Bool = false
    ) {
        self.safety = safety
        self.journal = journal
        self.rules = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.commandTrust = CommandTrust(allowedCommands: allowedCommands)
        self.maxBytesPerAutomaticRun = maxBytesPerAutomaticRun
        self.configError = configError
        self.alwaysTrash = alwaysTrash
    }

    /// Checks one item without touching it, using what the plan recorded about it.
    public func verdict(for item: CleanupItem, context: CleanupContext) -> SafetyVerdict {
        verdict(for: remover.target(of: item, probingRepositories: false), ruleID: item.ruleID, context: context)
    }

    /// The guard's verdict on a removal target, refused outright while the config is invalid, and for something in the
    /// Trash that the removal module wouldn't let this run take (`Remover.method`), so a preview's verdicts and totals
    /// match what the run does.
    func verdict(for target: RemovalTarget, ruleID: String?, context: CleanupContext) -> SafetyVerdict {
        let rule = ruleID.flatMap { rules[$0] }
        var verdict = safety.evaluate(target, rule: rule, context: context)
        refuseIfConfigInvalid(&verdict)
        let remover = self.remover
        if remover.method(inTrash: remover.isInsideTrash(target), useTrash: true, rule: rule, context: context) == nil {
            verdict.raise(.block, CleanupExecutor.trashedNotRegenerable)
        }
        return verdict
    }

    /// Why an automatic run leaves something in the Trash (`Remover.method`).
    static let trashedNotRegenerable = "Automatic runs delete things already in the Trash only when a regenerable (safe) rule covers them"

    /// True when the run's circumstances block every row, whatever the row: an invalid config, or SpaceKit running as
    /// root. Fixing them unblocks the rows, so rows blocked then aren't blocked for good.
    var blocksEverything: Bool { configError != nil || safety.isRunningAsRoot }

    func refuseIfConfigInvalid(_ verdict: inout SafetyVerdict) {
        if let configError {
            verdict.raise(.block, "Config file is invalid: \(configError). Fix it (spacekit config validate) before cleaning.")
        }
    }

    public typealias ProgressHandler = @Sendable (_ completed: Int, _ total: Int, _ current: String) -> Void

    /// Runs a plan a person reviewed and said go to. Each item and command is checked again first, and a warning
    /// the review didn't show for that row skips it.
    ///
    /// A plan reviewed with another executor runs none of its rows: the person judged it under settings that are no
    /// longer the ones in force. Every row is skipped with `outdatedReview` and the report is `reviewOutdated`, so
    /// the front end can review the plan again with this executor.
    public func execute(_ reviewed: ReviewedPlan, dryRun: Bool, onProgress: ProgressHandler? = nil) -> CleanupReport {
        guard reviewed.review.executorID == executorID else { return CleanupExecutor.outdated(reviewed.plan, dryRun: dryRun) }
        return execute(reviewed.plan, context: .manual, review: reviewed.review, dryRun: dryRun, onProgress: onProgress)
    }

    private static func outdated(_ plan: CleanupPlan, dryRun: Bool) -> CleanupReport {
        var report = CleanupReport(dryRun: dryRun)
        let skipped = CleanupOutcome.skipped(reason: outdatedReview, kind: .changedSinceReview)
        report.items = plan.items.map { ($0, skipped) }
        report.commands = plan.commands.map { ($0, skipped, "") }
        report.reviewOutdated = true
        return report
    }

    /// Runs an automatic job's plan under the automation limits. Nobody acknowledged anything, so whatever needs
    /// confirmation is skipped.
    func execute(_ automatic: AutomaticPlan, dryRun: Bool, onProgress: ProgressHandler? = nil) -> CleanupReport {
        execute(automatic.plan, context: .automatic(automatic.automation), review: nil, dryRun: dryRun, onProgress: onProgress)
    }

    private func execute(
        _ plan: CleanupPlan, context: CleanupContext, review: ReviewRecord?, dryRun: Bool, onProgress: ProgressHandler?
    ) -> CleanupReport {
        // Read once per run, so every row is judged against the same disk: mounts since the guard was built, and the
        // capacity each item's share of the disk is taken of, before this run removes anything.
        var current = self
        if let readMounts { current.safety = current.safety.mounted(readMounts()) }
        current.safety = current.safety.capacities(readNowFor: CleanupExecutor.volumePaths(of: plan))
        return current.executeRows(of: plan, context: context, review: review, dryRun: dryRun, onProgress: onProgress)
    }

    /// Where the guard reads the capacity for the plan's rows: the folder holding each item (and the folder of loose
    /// files), and the folder holding each item a command names.
    private static func volumePaths(of plan: CleanupPlan) -> [String] {
        plan.items.flatMap { [PathUtil.parent($0.path), $0.path] } + plan.commands.compactMap(\.itemPath).map(PathUtil.parent)
    }

    private func executeRows(
        of plan: CleanupPlan, context: CleanupContext, review: ReviewRecord?, dryRun: Bool, onProgress: ProgressHandler?
    ) -> CleanupReport {
        var run = Run(report: CleanupReport(dryRun: dryRun), budget: context.isAutomatic ? maxBytesPerAutomaticRun : .max)
        let total = plan.items.count + plan.commands.count
        var completed = 0

        for item in plan.items {
            onProgress?(completed, total, item.path)
            completed += 1
            let reviewed = review.map { $0.items[item.id] ?? .unseen }
            let outcome = removeItem(item, plan: plan, context: context, reviewed: reviewed, run: &run)
            run.report.items.append((item, outcome))
        }
        for command in plan.commands {
            onProgress?(completed, total, command.displayString)
            completed += 1
            let reviewed = review.map { $0.commands[command.id] ?? .unseen }
            let (outcome, output) = runCommand(command, context: context, reviewed: reviewed, run: &run)
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

    static func jobID(_ context: CleanupContext) -> String? {
        if case .automatic(let automation) = context { return automation.jobID }
        return nil
    }

    /// Why the run may not act on `verdict`, or `nil` when it may. `reviewed`: what the person's review showed for
    /// this row; `nil` in an automatic run, which acknowledges nothing.
    ///
    /// A reviewed row may need confirmation only for reasons the review showed and the person accepted. A reason it
    /// didn't show (a repository that appeared, a folder that grew past the share of the disk it was shown with, a
    /// block such as a volume mounted since) skips the row as changed since the review, which counts as a problem. So
    /// does a row whose shown warnings the person didn't accept (`--yes` without `--accept-warnings`): it was selected
    /// and left undone.
    ///
    /// `unseen` makes the outcome of a reason the review couldn't show; by default the row changed since the review.
    static func refusal(
        _ verdict: SafetyVerdict, reviewed: ReviewRecord.Row?, unseen: (String) -> CleanupOutcome = CleanupOutcome.changedSinceReview
    ) -> CleanupOutcome? {
        let reasons = verdict.reasons.joined(separator: "; ")
        switch verdict.decision {
        case .allow:
            return nil
        case .block:
            // A review never passes a blocked row on, so a block in a reviewed run is new.
            guard reviewed != nil else { return .skipped(reason: "Blocked: " + reasons, kind: .refused) }
            return unseen("Blocked: " + reasons)
        case .confirm:
            guard let reviewed else { return .skipped(reason: "Needs confirmation: " + reasons, kind: .refused) }
            let notShown = verdict.reasons.filter { !reviewed.showed($0) }
            if !notShown.isEmpty { return unseen(notShown.joined(separator: "; ")) }
            return reviewed.accepted ? nil : .notAccepted(reasons)
        }
    }

    /// Starts the skip reason of a row that changed after the review: it gained a reason the review didn't show, or
    /// isn't at the location the review judged. Reports treat it as a problem, because the person never saw that.
    public static let changedSinceReview = "Changed since you reviewed it: "

    /// Starts the skip reason of a reviewed row whose warnings the person saw and didn't accept. Reports treat it as a
    /// problem: the row was selected and didn't run.
    public static let notAccepted = "Warnings not accepted: "

    /// Why every row of a plan reviewed with another executor is skipped.
    public static let outdatedReview = changedSinceReview + "SpaceKit's settings changed after the review. Review it again."

    func overBudget() -> CleanupOutcome {
        let budget = ByteCount.format(maxBytesPerAutomaticRun)
        return .skipped(reason: "Over this run's budget of \(budget) (safety.maxBytesPerRun)", kind: .overBudget)
    }

    static func moveToTrash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }
}
