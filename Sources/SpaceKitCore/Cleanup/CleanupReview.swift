import Foundation

/// A plan as a person reviews it before anything is removed: the guard's verdict on every item and command, the rows
/// they untick, what the selection adds up to and where it goes. The app's review sheet, the TUI's dialog and the
/// CLI's preview render it and ask; only `acknowledge(acceptingWarnings:)` turns it into the `ReviewedPlan` that
/// `CleanupExecutor` runs by hand.
///
/// Verdicts are computed once, here. Blocked rows can't be selected and never reach the executor, which checks
/// everything else again right before removal.
public struct CleanupReview: Sendable {
    /// An item or a command with the guard's verdict, as the review shows it.
    public struct Row<Subject: Identifiable & Sendable>: Sendable, Identifiable where Subject.ID == String {
        public let subject: Subject
        public let verdict: SafetyVerdict
        fileprivate let key: Key

        public var id: String { subject.id }
        /// May run only once the person has seen `verdict.reasons` and accepted them.
        public var needsAcknowledgement: Bool { verdict.decision == .confirm }
    }

    /// Where the selected items end up.
    public enum Disposal: Sendable, Equatable {
        case moveToTrash
        case delete
        /// Every selected item is already in the Trash: removing it deletes it for good.
        case deleteFromTrash
        /// Some selected items are already in the Trash and are deleted for good; the rest are moved to the Trash.
        case moveToTrashAndDeleteFromTrash

        /// Something selected is deleted for good, not moved to the Trash. Front ends mark the wording as a warning.
        public var isPermanent: Bool { self != .moveToTrash }
    }

    /// Items and commands can share an id, so each kind keeps its own.
    fileprivate enum Key: Hashable, Sendable {
        case item(String)
        case command(String)
    }

    /// Largest first, the order every preview lists them in.
    public let items: [Row<CleanupItem>]
    public let commands: [Row<PlannedCommand>]
    /// Steps to take in another app. Shown, never run.
    public let manualSteps: [String]
    /// Whether items go to the Trash instead of being deleted.
    public private(set) var useTrash: Bool
    /// `false` when the config moves everything to the Trash (`safety.trash: always`), whatever `useTrash` says.
    public let canChooseTrash: Bool
    /// Ids of items already in the Trash.
    private let trashed: Set<String>
    /// Where each item was judged, by id: the reviewed plan binds the person's go-ahead to it.
    private let locations: [String: RemovalTarget.Location]
    /// Where each command's tool was found, by id, for the same reason. Missing for a tool that isn't installed.
    private let executables: [String: String]
    /// Where the item each item command names was judged, by command id, for the same reason.
    private let commandLocations: [String: RemovalTarget.Location]
    /// Decides where items go, for the wording.
    private let remover: Remover
    /// The executor the verdicts came from; only it runs the reviewed plan.
    private let executorID: UUID
    private var unticked: Set<Key> = []

    public init(_ plan: CleanupPlan, executor: CleanupExecutor) {
        let remover = executor.remover
        // One target per item, as the plan recorded it, for both the verdict and where the item ends up.
        let targets = plan.itemsLargestFirst.map { ($0, remover.target(of: $0, probingRepositories: false)) }
        items = targets.map { item, target in
            Row(subject: item, verdict: executor.verdict(for: target, ruleID: item.ruleID, context: .manual), key: .item(item.id))
        }
        // Each tool, and the item an item command names, looked up once, for the verdict and for the record, so the
        // review shows the program a run would start on the item it would act on.
        let found = plan.commands.map { ($0, executor.runner.locate($0.arguments.first ?? ""), executor.itemTarget(of: $0)) }
        commands = found.map { command, executable, item in
            let verdict = executor.verdict(for: command, context: .manual, executable: executable, item: item)
            return Row(subject: command, verdict: verdict, key: .command(command.id))
        }
        let located = found.compactMap { command, executable, _ in executable.map { (command.id, $0) } }
        executables = Dictionary(located, uniquingKeysWith: { first, _ in first })
        let commandItems = found.compactMap { command, _, item in item.map { (command.id, $0.location) } }
        commandLocations = Dictionary(commandItems, uniquingKeysWith: { first, _ in first })
        manualSteps = plan.manualSteps
        useTrash = plan.useTrash
        canChooseTrash = remover.method(inTrash: false, useTrash: false, rule: nil, context: .manual) == .delete
        trashed = Set(targets.filter { remover.isInsideTrash($1) }.map { $0.0.id })
        locations = Dictionary(targets.map { ($0.id, $1.location) }, uniquingKeysWith: { first, _ in first })
        self.remover = remover
        executorID = executor.executorID
    }

    // MARK: Selection

    /// Selected: not blocked, and not unticked by the person.
    public func isIncluded<Subject>(_ row: Row<Subject>) -> Bool {
        !row.verdict.isBlocked && !unticked.contains(row.key)
    }

    /// This review with `row` ticked or unticked. Ticking a blocked row changes nothing.
    public func setting<Subject>(_ row: Row<Subject>, included: Bool) -> CleanupReview {
        var review = self
        if included { review.unticked.remove(row.key) } else { review.unticked.insert(row.key) }
        return review
    }

    /// This review with items going to the Trash (`true`) or deleted.
    public func usingTrash(_ useTrash: Bool) -> CleanupReview {
        var review = self
        review.useTrash = useTrash
        return review
    }

    /// This review with the choices the person made in `previous`, a review of the same plan made before (with another
    /// executor, after a settings change): the rows they unticked stay unticked, and the Trash choice stays where the
    /// person may still choose it. Rows `previous` didn't have start ticked.
    public func keepingChoices(of previous: CleanupReview) -> CleanupReview {
        var review = self
        let keys = Set(items.map(\.key) + commands.map(\.key))
        review.unticked = previous.unticked.intersection(keys)
        if canChooseTrash { review.useTrash = previous.useTrash }
        return review
    }

    public var selectedItems: [CleanupItem] { items.filter(isIncluded).map(\.subject) }
    public var selectedCommands: [PlannedCommand] { commands.filter(isIncluded).map(\.subject) }
    public var isEmpty: Bool { selectedItems.isEmpty && selectedCommands.isEmpty }

    // MARK: Counts and totals

    /// Selected rows whose warnings the person must accept before they run.
    public var warningCount: Int {
        items.filter { isIncluded($0) && $0.needsAcknowledgement }.count
            + commands.filter { isIncluded($0) && $0.needsAcknowledgement }.count
    }

    public var needsAcknowledgement: Bool { warningCount > 0 }

    public var blockedCount: Int {
        items.filter(\.verdict.isBlocked).count + commands.filter(\.verdict.isBlocked).count
    }

    /// Bytes of the selected items, as the scan measured them.
    public var itemBytes: UInt64 { selectedItems.reduce(0) { $0 &+ $1.size } }

    /// What the selected tool commands are expected to free; each tool decides what's unused.
    public var commandBytes: UInt64 { selectedCommands.reduce(0) { $0 &+ $1.estimatedBytes } }

    // MARK: Wording

    public var disposal: Disposal {
        let selected = selectedItems
        let inTrash = selected.filter { trashed.contains($0.id) }
        if !selected.isEmpty && inTrash.count == selected.count { return .deleteFromTrash }
        guard movesToTrash else { return .delete }
        return inTrash.isEmpty ? .moveToTrash : .moveToTrashAndDeleteFromTrash
    }

    /// Items not already in the Trash go there, as the removal module decides for a manual run with `useTrash`.
    private var movesToTrash: Bool {
        remover.method(inTrash: false, useTrash: useTrash, rule: nil, context: .manual) == .trash
    }

    /// "1.2 GB will be moved to the Trash." `nil` with no item selected.
    public var disposalSummary: String? {
        guard !selectedItems.isEmpty else { return nil }
        let size = ByteCount.format(itemBytes)
        switch disposal {
        case .moveToTrash: return "\(size) will be moved to the Trash."
        case .delete: return "\(size) will be deleted permanently, not moved to the Trash."
        case .deleteFromTrash: return "\(size) is already in the Trash and will be deleted permanently."
        case .moveToTrashAndDeleteFromTrash:
            let inTrash = selectedItems.filter { trashed.contains($0.id) }.reduce(0) { $0 &+ $1.size }
            return "\(ByteCount.format(itemBytes - inTrash)) will be moved to the Trash; "
                + "\(ByteCount.format(inTrash)) already in the Trash will be deleted permanently."
        }
    }

    /// "2 tool commands will run; …" `nil` with no command selected.
    public var commandSummary: String? {
        let count = selectedCommands.count
        guard count > 0 else { return nil }
        return "\(count) tool command\(count == 1 ? "" : "s") will run; each removes only what its tool knows is unused."
    }

    // MARK: Acknowledgement

    /// The plan to run now that the person said go: the selected rows, without blocked or unticked ones.
    ///
    /// `acceptingWarnings`: the person was shown every reason of every selected row that needs acknowledgement and
    /// accepted them all, once for the whole plan. Without it, such rows stay in the plan and the executor skips them
    /// as needing confirmation, so the report lists them.
    ///
    /// The reviewed plan records, for every selected row, the reasons the review showed and, for an item or the item a
    /// command names, the location it was judged at. The executor holds the run to that record: a reason the review
    /// didn't show for the row, or an item no longer at that location, skips the row as changed since the review.
    public func acknowledge(acceptingWarnings: Bool) -> ReviewedPlan {
        func record<Subject>(
            _ rows: [Row<Subject>], location: (Row<Subject>) -> RemovalTarget.Location? = { _ in nil },
            executable: (Row<Subject>) -> String? = { _ in nil }
        ) -> [String: ReviewRecord.Row] {
            let selected = rows.filter(isIncluded).map { row in
                let accepted = acceptingWarnings || !row.needsAcknowledgement
                let shown = Set(row.verdict.reasons)
                return (row.id, ReviewRecord.Row(shown: shown, accepted: accepted, location: location(row), executable: executable(row)))
            }
            // Two rows with one id (the same path listed twice) hold the run to what both of them showed.
            return Dictionary(selected, uniquingKeysWith: { $0.intersecting($1) })
        }
        // The plan says what the removal module will do: with `safety.trash: always`, the Trash whatever `useTrash` says.
        let plan = CleanupPlan(items: selectedItems, commands: selectedCommands, manualSteps: manualSteps, useTrash: movesToTrash)
        let review = ReviewRecord(
            executorID: executorID, items: record(items, location: { locations[$0.id] }),
            commands: record(commands, location: { commandLocations[$0.id] }, executable: { executables[$0.id] }))
        return ReviewedPlan(plan: plan, review: review)
    }
}

/// A plan a person reviewed and said go to. `CleanupReview.acknowledge(acceptingWarnings:)` alone makes one, and it is
/// the only plan `CleanupExecutor` runs by hand, so no front end can reach "manual and confirmed" without a review.
public struct ReviewedPlan: Sendable {
    /// The selected items and commands.
    public let plan: CleanupPlan
    let review: ReviewRecord

    fileprivate init(plan: CleanupPlan, review: ReviewRecord) {
        self.plan = plan
        self.review = review
    }
}

extension ReviewedPlan {
    /// Only the rows that are also in `plan`, with what the review recorded for them.
    func limited(to plan: CleanupPlan) -> ReviewedPlan {
        ReviewedPlan(plan: self.plan.narrowed(to: plan), review: review)
    }
}

/// What a person's review showed for each row, by item and command id, and which executor showed it. The executor
/// holds a manual run to it; automatic runs have none.
struct ReviewRecord: Sendable {
    /// One row as the review showed it.
    struct Row: Sendable {
        /// Every reason the review showed; none for a row it allowed outright.
        let shown: Set<String>
        /// The person accepted `shown` (or there was nothing to accept).
        let accepted: Bool
        /// Where the review judged an item, or the item a command names. `nil` for any other command.
        let location: RemovalTarget.Location?
        /// Where the review found a command's tool, the program its warnings named. `nil` for an item, or a tool that
        /// wasn't installed.
        let executable: String?

        /// What two rows for the same thing both showed and the person accepted for both.
        func intersecting(_ other: Row) -> Row {
            Row(shown: shown.intersection(other.shown), accepted: accepted && other.accepted, location: location, executable: executable)
        }

        /// A row with no record: everything about it is unseen.
        static let unseen = Row(shown: [], accepted: false, location: nil, executable: nil)

        /// Whether `reason`, raised at removal time, is one the review showed: the same text, or the same text with
        /// every number in it no larger. An item shown as holding 12% of the disk is the same warning at 11%, not
        /// at 45%: the person accepted removing that much, not more.
        func showed(_ reason: String) -> Bool {
            if shown.contains(reason) { return true }
            let raised = ReviewRecord.numbers(in: reason)
            return shown.contains { candidate in
                let seen = ReviewRecord.numbers(in: candidate)
                return seen.text == raised.text && seen.values.count == raised.values.count
                    && zip(raised.values, seen.values).allSatisfy { $0 <= $1 }
            }
        }
    }

    /// `CleanupExecutor.executorID` of the executor whose verdicts the review showed.
    let executorID: UUID
    let items: [String: Row]
    let commands: [String: Row]

    /// `reason` without its digits, and the numbers it holds in order.
    static func numbers(in reason: String) -> (text: String, values: [UInt64]) {
        let digits = #/[0-9]+/#
        return (reason.replacing(digits, with: ""), reason.matches(of: digits).compactMap { UInt64($0.output) })
    }
}
