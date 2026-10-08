import Foundation
import Synchronization

/// The Explore scan a person is looking at in the app or the TUI, with its analysis, kept current while they clean up.
///
/// A `DirNode` can't be read while it changes, and background work reads the tree for seconds at a time: an analysis
/// that reuses it, the app's map layout. The workspace is the one place that decides when the tree changes:
/// - Background work reads the tree only inside `read`, or during a lease begun with `beginRead` on the front end's
///   thread before nodes are handed over; either counts it as a reader. A tree being shown has none yet, so `show`
///   applies the cleanups it must carry over at once.
/// - Changes (a cleanup's removals, a re-synced folder) wait until no reader is left, then run in a step the front end
///   runs on its own thread (`Deliver`: the app's main actor, the TUI's loop), holding the gate so no reader starts
///   meanwhile. That thread may therefore read the tree directly, without `read`.
/// - An analysis's result is put in place at the moment it stops reading, so a cleanup that finished while it ran is
///   applied to the new findings, never lost under them.
///
/// Every step returns events (`Event`) that tell the front end what changed, so it can fix its own selection.
/// One-shot CLI commands don't need any of this and call `Scanner` and `StorageAnalyzer` directly.
public final class Workspace: Sendable {
    /// A piece of the workspace's work that may change the tree; it returns what it did.
    public typealias Step = @Sendable () -> [Event]
    /// Runs `step` on the thread that owns the front end's view of the tree, then handles the events it returns.
    /// Steps must run one at a time, in the order they are handed over.
    public typealias Deliver = @Sendable (_ step: @escaping Step) -> Void
    /// Evaluates every rule, reusing the tree when it covers what they need (a seam for tests).
    typealias Analyze = @Sendable (SpaceKitContext, ScanTree?, ScanProgress) throws -> Analysis
    /// Evaluates a few rules with a scan of only their locations (a seam for tests).
    typealias Reevaluate = @Sendable (SpaceKitContext, [Rule]) throws -> Analysis

    private let gate = Mutex(Shared())
    private let deliver: Deliver
    private let analyzeTree: Analyze
    private let reevaluateRules: Reevaluate

    public convenience init(deliver: @escaping Deliver) {
        self.init(deliver: deliver, analyze: Workspace.analyzeAll, reevaluate: Workspace.reevaluateOnly)
    }

    init(deliver: @escaping Deliver, analyze: @escaping Analyze, reevaluate: @escaping Reevaluate = Workspace.reevaluateOnly) {
        self.deliver = deliver
        self.analyzeTree = analyze
        self.reevaluateRules = reevaluate
    }

    static let analyzeAll: Analyze = { context, tree, progress in
        try context.analyzer.analyzeSync(reusing: tree, progress: progress)
    }

    private static let reevaluateOnly: Reevaluate = { context, rules in try context.analyzer.analyzeSync(rules: rules) }

    /// The tree and the analysis as they are now.
    public var state: State { gate.withLock { $0.state } }

    // MARK: Reading

    /// Runs `body` with the tree, which doesn't change until `body` returns; changes that arrive meanwhile wait for
    /// every reader to finish. Callable from any thread. Waits only while a change is being applied.
    public func read<T>(_ body: (ScanTree?) throws -> T) rethrows -> T {
        let lease = beginRead()
        defer { lease.end() }
        return try body(lease.tree)
    }

    /// Starts a read now that other work ends later (`ReadLease.end`). The front end's thread begins one before it
    /// hands nodes it holds to background work: a change could otherwise land on that thread before the work starts
    /// reading, and free the removed nodes (and the parents of the ones it holds) under it.
    public func beginRead() -> ReadLease {
        let tree = gate.withLock { shared in
            shared.readers += 1
            return shared.tree
        }
        return ReadLease(tree: tree) { [self] in endRead() }
    }

    private func endRead() {
        let drainNow = gate.withLock { shared in
            shared.readers -= 1
            return shared.readers == 0 && !shared.pending.isEmpty
        }
        if drainNow { deliver { [self] in drain() } }
    }

    // MARK: Scans and analyses

    /// Shows a finished scan (or none, while a new one runs): the previous tree's analysis is dropped and one still
    /// running is stopped, so its result never lands on this tree. Changes still waiting for the previous tree are
    /// dropped too: they were worked out on it. A cleanup that finished after this scan started is applied to it again
    /// (`Removal.carried(over:)`): the scan may have counted an item before it went, whether the cleanup was applied to
    /// the previous tree, still waited for it, or came while none was shown. Earlier ones are forgotten, since the scan
    /// shows them already. Call it on the front end's own thread, before anything reads the new tree: the cleanups are
    /// applied here and now, so an analysis started right after (and the History snapshot it records) never sees what
    /// they removed. No event announces them; the state returned shows them. A Trash such a cleanup moved anything into
    /// is scanned again and re-synced (`resync`), since whether this scan saw what arrived there can't be told.
    @discardableResult
    public func show(_ tree: ScanTree?) -> State {
        let (state, trashes) = gate.withLock { shared -> (State, [String: SpaceKitContext]) in
            shared.analysisProgress?.cancel()
            shared.analysisProgress = nil
            shared.analysisRun += 1
            shared.tree = tree
            shared.result = nil
            shared.refreshing = [:]
            shared.pending = []
            guard let tree else { return (shared.state, [:]) }
            shared.cleanups.removeAll { $0.finished <= tree.scanStarted }
            // Nothing reads this tree yet: readers counted now read the previous one, and new ones get it only after this.
            var trashes: [String: SpaceKitContext] = [:]
            for cleanup in shared.cleanups {
                _ = Workspace.perform(cleanup, carried: true, on: &shared)
                for folder in cleanup.removals.flatMap(\.trashFolders) where tree.covers(folder) { trashes[folder] = cleanup.context }
            }
            return (shared.state, trashes)
        }
        for (folder, context) in trashes { rescan(folder, over: state, context: context) }
        return state
    }

    /// Scans `folder`, a Trash shown in `shown`, again and re-syncs it, re-evaluating the rules that describe it.
    private func rescan(_ folder: String, over shown: State, context: SpaceKitContext) {
        guard let options = shown.tree.map({ Trash.scanOptions($0.options) }) else { return }
        let rules = Set(Trash.rules(in: context.library.rules, home: PathUtil.parent(folder)).map(\.id))
        Thread.detachNewThread { [self] in
            guard let fresh = try? Scanner(options: options).scan(folder), !fresh.root.flags.contains(.unreadable) else { return }
            resync(fresh, at: folder, over: shown, context: context, reevaluating: rules)
        }
    }

    /// Evaluates every rule of `context`, reusing the tree when it covers the locations they need, and records a
    /// History snapshot. Starting again stops the analysis in progress. Delivers `.analysed` or `.analysisFailed`.
    @discardableResult
    public func analyze(_ context: SpaceKitContext) -> ScanProgress {
        let progress = ScanProgress()
        let (tree, run) = gate.withLock { shared in
            shared.analysisProgress?.cancel()
            shared.analysisProgress = progress
            shared.analysisRun += 1
            shared.readers += 1
            return (shared.tree, shared.analysisRun)
        }
        let analyze = analyzeTree
        Thread.detachNewThread { [self] in
            let outcome = Result { () throws -> AnalysisResult? in
                let analysis = try analyze(context, tree, progress)
                // A newer scan or analysis replaced this one, so its findings are never shown nor recorded.
                guard gate.withLock({ $0.analysisRun == run }) else { return nil }
                // History reads the tree too, so it's recorded while this analysis still counts as a reader.
                try? context.history.recordSnapshot(analysis: analysis)
                return context.result(of: analysis)
            }
            finishAnalysis(run, outcome)
        }
        return progress
    }

    /// `outcome` is nil for an analysis that was replaced before it finished.
    private func finishAnalysis(_ run: Int, _ outcome: Result<AnalysisResult?, any Error>) {
        gate.withLock { shared in
            shared.readers -= 1
            guard shared.analysisRun == run else { return }
            shared.analysisProgress = nil
            if case .success(let result?) = outcome { shared.result = result }
        }
        deliver { [self] in
            // Removals that waited for this analysis are applied to its result first.
            var events = drain()
            guard gate.withLock({ $0.analysisRun == run }) else { return events }
            switch outcome {
            case .success: events.append(.analysed(state))
            case .failure(let error): events.append(.analysisFailed(error))
            }
            return events
        }
    }

    /// Labels folders with a reloaded rule library.
    @discardableResult
    public func reindex(rules: [Rule]) -> State {
        gate.withLock { shared in
            shared.result?.reindex(rules: rules)
            return shared.state
        }
    }

    // MARK: Changes

    /// Brings the tree and the findings up to date after a cleanup, without scanning or analysing everything again:
    /// removed items leave the tree (moved ones reappear in the Trash), partly removed ones are rescanned, findings
    /// lose what went, and rules whose tool command ran are re-evaluated alone. Delivers `.changed` once applied.
    public func apply(_ report: CleanupReport, context: SpaceKitContext) {
        // The cleanup finished before this call, so a scan that starts after it already shows what it removed.
        apply(report, finished: Date(), context: context)
    }

    /// `finished` is when the cleanup finished (a seam for tests).
    func apply(_ report: CleanupReport, finished: Date, context: SpaceKitContext) {
        let cleanup = FinishedCleanup(
            removals: Removal.from(report), finished: finished, reevaluate: report.rulesToReevaluate, context: context)
        enqueue(.cleanup(cleanup))
    }

    /// Replaces the folder at `path` in the trees that hold it with `fresh`, a scan of it (the Trash, emptied in
    /// Finder), then re-evaluates `ruleIDs`, whose findings live there. `shown` is the state from when that scan
    /// began: only its trees are changed, since a tree shown or analysed since is newer than `fresh`. Delivers
    /// `.changed` if a tree changed.
    public func resync(
        _ fresh: ScanTree, at path: String, over shown: State, context: SpaceKitContext, reevaluating ruleIDs: Set<String> = []
    ) {
        let (explore, analysed) = (shown.tree, shown.result?.analysis.tree)
        let separate = analysed.flatMap { $0 !== explore && $0.covers(path) ? $0 : nil }
        guard let separate else {
            enqueue(.resync(Resync(path: path, fresh: fresh, explore: explore, forAnalysis: nil, reevaluate: ruleIDs, context: context)))
            return
        }
        // Splicing hands the scanned nodes over to the tree, so the analysis tree needs a scan of its own.
        Thread.detachNewThread { [self] in
            let second = try? Scanner(options: fresh.options).scan(path)
            let resync = Resync(
                path: path, fresh: fresh, explore: explore, forAnalysis: second.map { ($0, separate) }, reevaluate: ruleIDs,
                context: context)
            enqueue(.resync(resync))
        }
    }

    private func enqueue(_ change: PendingChange) {
        let drainNow = gate.withLock { shared in
            // Kept for the next tree shown, which may have been scanned before the cleanup finished.
            if case .cleanup(let cleanup) = change { shared.cleanups.append(cleanup) }
            shared.pending.append(change)
            return shared.readers == 0
        }
        if drainNow { deliver { [self] in drain() } }
    }

    /// Applies every waiting change, unless something reads the tree (the last reader drains again when it ends).
    private func drain() -> [Event] {
        let (changes, refreshes) = gate.withLock { shared -> ([Change], [Refresh]) in
            guard shared.readers == 0, !shared.pending.isEmpty else { return ([], []) }
            let waiting = shared.pending
            shared.pending = []
            var changes: [Change] = []
            var refreshes: [Refresh] = []
            for pending in waiting {
                let (change, refresh) = Workspace.perform(pending, on: &shared)
                if let change { changes.append(change) }
                if let refresh { refreshes.append(refresh) }
            }
            return (changes, refreshes)
        }
        for refresh in refreshes { start(refresh) }
        return changes.map(Event.changed)
    }

    /// One change, made while the gate is held and no reader is left.
    private static func perform(_ pending: PendingChange, on shared: inout Shared) -> (Change?, Refresh?) {
        switch pending {
        case .cleanup(let cleanup):
            return perform(cleanup, carried: false, on: &shared)
        case .resync(let resync):
            return perform(resync, on: &shared)
        }
    }

    /// A cleanup's removals. `carried`: the tree was scanned before the cleanup finished (`show`), so only what it still
    /// shows where it was is removed.
    private static func perform(_ cleanup: FinishedCleanup, carried: Bool, on shared: inout Shared) -> (Change?, Refresh?) {
        let tree = shared.tree
        let removals = carried ? tree.map { tree in cleanup.removals.compactMap { $0.carried(over: tree) } } ?? [] : cleanup.removals
        let refresh = shared.markRefreshing(cleanup.reevaluate, context: cleanup.context)
        if carried && removals.isEmpty { return (nil, refresh) }
        let retired = tree.map { tree in removals.filter { $0.kind != .looseFiles }.flatMap { retiring($0.path, in: tree) } } ?? []
        let treeChanged = tree.map { Removal.apply(removals, to: $0) } ?? false
        shared.result?.apply(removals, exploreTree: tree)
        let change = Change(
            state: shared.state, removals: removals, rescanned: removals.filter(\.partial).map(\.path), treeChanged: treeChanged,
            retired: retired)
        return (change, refresh)
    }

    /// A folder scanned again, spliced into the trees it was scanned for.
    private static func perform(_ resync: Resync, on shared: inout Shared) -> (Change?, Refresh?) {
        var retired: [DirNode] = []
        var treeChanged = false
        if let tree = shared.tree, tree === resync.explore, tree.covers(resync.path),
            tree.node(at: resync.path)?.size != resync.fresh.root.size
        {
            retired = retiring(resync.path, in: tree)
            tree.splice(resync.fresh, at: resync.path)
            treeChanged = true
        }
        var analysisChanged = false
        if let (fresh, analysed) = resync.forAnalysis, shared.result?.analysis.tree === analysed {
            analysed.splice(fresh, at: resync.path)
            analysisChanged = true
        }
        guard treeChanged || analysisChanged else { return (nil, nil) }
        let refresh = shared.markRefreshing(resync.reevaluate, context: resync.context)
        let change = Change(
            state: shared.state, removals: [], rescanned: [resync.path], treeChanged: treeChanged, retired: retired)
        return (change, refresh)
    }

    /// The nodes a change at `path` takes out of the tree: the folder and its contents (a rescan replaces those).
    private static func retiring(_ path: String, in tree: ScanTree) -> [DirNode] {
        guard let node = tree.node(at: path) else { return [] }
        return [node] + node.children
    }

    // MARK: Targeted refreshes

    /// Re-evaluates a few rules with a scan of only their locations (it never reads the tree), then merges the result
    /// for the rules no newer re-evaluation has started for since.
    private func start(_ refresh: Refresh) {
        let reevaluate = reevaluateRules
        Thread.detachNewThread { [self] in
            // Built before taking the gate: the AI report and the rule index take a while, and the front end's thread
            // takes the gate for every state it shows.
            let fresh = (try? reevaluate(refresh.context, refresh.rules)).map(refresh.context.result(of:))
            gate.withLock { shared in
                // A newer re-evaluation of a rule (after another of its commands) owns its spinner and has newer findings.
                let owned = refresh.ruleIDs.filter { shared.refreshing[$0] == refresh.token }
                for id in owned { shared.refreshing[id] = nil }
                guard let fresh, !owned.isEmpty else { return }
                shared.result?.merge(fresh, for: owned)
            }
            deliver { [self] in [.refreshed(state)] }
        }
    }

    // MARK: Shared state

    private struct Shared {
        var tree: ScanTree?
        var result: AnalysisResult?
        /// Bumped by every analysis (and `show`): only the latest one's result is used.
        var analysisRun = 0
        var analysisProgress: ScanProgress?
        var readers = 0
        var pending: [PendingChange] = []
        /// Cleanups that finished after the shown tree's scan started (all of them while none is shown), for the next
        /// tree shown.
        var cleanups: [FinishedCleanup] = []
        /// Rules being re-evaluated, each with the re-evaluation that owns it (the latest started for it). `show`
        /// empties it, so re-evaluations started for an older tree own nothing.
        var refreshing: [String: Int] = [:]
        var refreshCount = 0

        var state: State { State(tree: tree, result: result, refreshingRules: Set(refreshing.keys)) }

        /// Marks the rules of `ruleIDs` that exist as being re-evaluated, if there are findings to merge them into.
        mutating func markRefreshing(_ ruleIDs: Set<String>, context: SpaceKitContext) -> Refresh? {
            let rules = ruleIDs.compactMap { context.library.rule(id: $0) }
            guard !rules.isEmpty, result != nil else { return nil }
            let refresh = Refresh(rules: rules, token: refreshCount + 1, context: context)
            refreshCount = refresh.token
            for id in refresh.ruleIDs { refreshing[id] = refresh.token }
            return refresh
        }
    }

    /// A change waiting for the readers to finish; applied, it becomes a `Change`.
    private enum PendingChange: Sendable {
        case cleanup(FinishedCleanup)
        case resync(Resync)
    }

    /// A cleanup's removals, and when it finished.
    private struct FinishedCleanup: Sendable {
        let removals: [Removal]
        let finished: Date
        /// Rules whose tool command ran.
        let reevaluate: Set<String>
        let context: SpaceKitContext
    }

    private struct Resync: Sendable {
        let path: String
        let fresh: ScanTree
        /// The Explore tree `fresh` was taken for; a newer scan already shows the folder as it is.
        let explore: ScanTree?
        /// A second scan of the folder for a separate analysis tree, and that tree.
        let forAnalysis: (ScanTree, ScanTree)?
        let reevaluate: Set<String>
        let context: SpaceKitContext
    }

    private struct Refresh: Sendable {
        let rules: [Rule]
        /// Which re-evaluation this is (`Shared.refreshing`).
        let token: Int
        let context: SpaceKitContext

        var ruleIDs: Set<String> { Set(rules.map(\.id)) }
    }
}
