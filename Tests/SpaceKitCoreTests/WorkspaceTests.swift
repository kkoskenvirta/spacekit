import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// A workspace whose steps run on whichever thread hands them over, recording every event they return.
private final class Recorder: Sendable {
    let events = Mutex<[Workspace.Event]>([])

    var deliver: Workspace.Deliver {
        { step in
            let delivered = step()
            self.events.withLock { $0 += delivered }
        }
    }

    var all: [Workspace.Event] { events.withLock { $0 } }

    var changes: [Workspace.Change] {
        all.compactMap { event in
            if case .changed(let change) = event { return change }
            return nil
        }
    }

    var analysed: [Workspace.State] {
        all.compactMap { event in
            if case .analysed(let state) = event { return state }
            return nil
        }
    }

    var refreshed: [Workspace.State] {
        all.compactMap { event in
            if case .refreshed(let state) = event { return state }
            return nil
        }
    }

    /// Waits up to five seconds for `condition` to hold.
    func wait(until condition: (Recorder) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(self) {
            guard Date() < deadline else { return false }
            usleep(2_000)
        }
        return true
    }
}

/// An analysis that has read the tree and then holds on until the test lets it finish, so a cleanup can land while
/// it runs.
private final class HeldAnalysis: Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var analyze: Workspace.Analyze {
        { context, tree, progress in
            let analysis = try context.analyzer.analyzeSync(reusing: tree, progress: progress)
            self.started.signal()
            self.release.wait()
            return analysis
        }
    }
}

/// Targeted re-evaluations that read the disk as they start, then hold on until the test lets each one finish, so
/// two of them for the same rule can end in either order.
private final class HeldRefreshes: Sendable {
    let started = DispatchSemaphore(value: 0)
    let releases = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    private let calls = Atomic<Int>(0)

    var reevaluate: Workspace.Reevaluate {
        { context, rules in
            let analysis = try context.analyzer.analyzeSync(rules: rules)
            let index = self.calls.wrappingAdd(1, ordering: .relaxed).oldValue
            self.started.signal()
            self.releases[index].wait()
            return analysis
        }
    }
}

/// `home/cache/<name>/blob` folders a safe rule cleans, a folder no rule claims, and a context reading them.
private struct Fixture {
    let tree = try! TempTree()
    let caches: [String]
    let rule: Rule
    let context: SpaceKitContext

    init(caches: Int = 3, bytes: Int = 120_000) throws {
        self.caches = (0..<caches).map { "c\($0)" }
        for name in self.caches { try tree.file("home/cache/\(name)/blob", bytes: bytes) }
        try tree.file("home/docs/keep.txt", bytes: 50_000)
        try tree.directory("home/.Trash")
        rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        context = SpaceKitContext(
            paths: SpaceKitPaths(configFile: tree.path("config/config.yaml"), stateDirectory: tree.path("state")),
            config: SpaceKitConfig(), library: RuleLibrary(rules: [rule]))
    }

    func scanHome() throws -> ScanTree { try Scanner(options: context.scanOptions).scan(tree.path("home")) }

    /// Removes `names` (folders under `home/cache`) the way a person's cleanup does.
    func clean(_ names: [String], useTrash: Bool = false) -> CleanupReport {
        let items = names.map { name in
            CleanupItem(path: tree.path("home/cache/\(name)"), size: tree.allocated("home/cache/\(name)/blob"), ruleID: rule.id)
        }
        return manualRun(CleanupPlan(items: items, useTrash: useTrash), with: sandboxExecutor(tree, rules: [rule]))
    }

    /// What a fresh scan and analysis of the disk find now: each item's path and size.
    func freshFindings() throws -> [String: UInt64] {
        items(try context.analyzer.analyzeSync(reusing: scanHome()).findings)
    }

    func items(_ findings: [Finding]) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: findings.flatMap(\.items).map { ($0.path, $0.size) })
    }
}

/// When a cleanup reaches the workspace, relative to the scan shown next.
enum CleanupTiming: CaseIterable, Sendable {
    /// While an analysis reads the old tree, so its removals wait.
    case waitingForReader
    /// With nothing reading, so its removals change the old tree straight away.
    case appliedToOldTree
    /// While no tree is shown (the TUI during a scan).
    case betweenScans
}

@Suite("Workspace: the Explore tree and its analysis, kept current")
struct WorkspaceTests {
    @Test("A cleanup that lands while the analysis runs is applied once it ends, to the tree and the new findings")
    func cleanupDuringAnalysis() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let held = HeldAnalysis()
        let workspace = Workspace(deliver: recorder.deliver, analyze: held.analyze)
        workspace.show(try fixture.scanHome())
        workspace.analyze(fixture.context)
        held.started.wait()

        workspace.apply(fixture.clean(["c0", "c1"]), context: fixture.context)

        // The analysis is still reading the tree, so the removal waits.
        #expect(workspace.read { $0?.node(at: fixture.tree.path("home/cache/c0")) != nil })
        #expect(recorder.changes.isEmpty)

        held.release.signal()
        #expect(recorder.wait { !$0.analysed.isEmpty })

        let changes = recorder.changes
        #expect(changes.count == 1)
        #expect(changes.first?.removals.map(\.path).sorted() == ["c0", "c1"].map { fixture.tree.path("home/cache/\($0)") })
        workspace.read { tree in
            #expect(tree?.inconsistencies() == [])
            #expect(tree?.node(at: fixture.tree.path("home/cache/c0")) == nil)
        }
        let result = try #require(workspace.state.result)
        #expect(fixture.items(result.analysis.findings) == (try fixture.freshFindings()))
        #expect(recorder.analysed.last.map { fixture.items($0.result?.analysis.findings ?? []) } == (try fixture.freshFindings()))
    }

    @Test("With nothing reading the tree, a cleanup is applied straight away and announced once")
    func cleanupWhileIdle() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        workspace.analyze(fixture.context)
        #expect(recorder.wait { !$0.analysed.isEmpty })

        workspace.apply(fixture.clean(["c2"], useTrash: true), context: fixture.context)

        #expect(recorder.changes.count == 1)
        #expect(recorder.changes.first?.treeChanged == true)
        workspace.read { tree in
            #expect(tree?.inconsistencies() == [])
            #expect(tree?.node(at: fixture.tree.path("home/.Trash/c2")) != nil)
        }
        #expect(fixture.items(workspace.state.result?.analysis.findings ?? []) == (try fixture.freshFindings()))
    }

    @Test("Readers never see a cleanup half applied")
    func readersSeeWholeChanges() throws {
        let fixture = try Fixture(caches: 200, bytes: 8_000)
        let workspace = Workspace(deliver: Recorder().deliver)
        workspace.show(try fixture.scanHome())
        let before = workspace.read { $0?.root.size ?? 0 }
        let removed = fixture.caches.dropFirst(10).map { fixture.tree.allocated("home/cache/\($0)/blob") }.reduce(0, +)

        let done = Atomic<Bool>(false)
        let seen = Mutex<Set<UInt64>>([])
        let problems = Mutex<[String]>([])
        // A write running alongside would show up as a total that moves during one read. Reads last a while, like an
        // analysis's, so a write that doesn't wait for them overlaps one.
        let check: @Sendable (ScanTree?) -> Void = { tree in
            guard let tree else { return }
            let first = tree.root.size
            usleep(10_000)
            let found = tree.inconsistencies(limit: .max)
            let last = tree.root.size
            if !found.isEmpty || first != last { problems.withLock { $0 += found + ["total \(first) → \(last)"] } }
            _ = seen.withLock { $0.insert(last) }
        }
        let reader = Thread {
            while !done.load(ordering: .acquiring) { workspace.read(check) }
        }
        reader.start()
        let report = fixture.clean(Array(fixture.caches.dropFirst(10)))
        workspace.apply(report, context: fixture.context)
        usleep(20_000)
        done.store(true, ordering: .releasing)
        while !reader.isFinished { usleep(1_000) }

        #expect(problems.withLock { $0 } == [])
        #expect(seen.withLock { $0 }.isSubset(of: [before, before - removed]))
        #expect(workspace.read { $0?.root.size } == before - removed)
    }

    @Test("A read begun on the front end's thread holds changes back until the work it was handed to ends it")
    func readLease() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        let c0 = fixture.tree.path("home/cache/c0")

        // The map layout begins its read before it hands nodes to a background task, so a change that lands before
        // that task starts can't take (and free) them.
        let lease = workspace.beginRead()
        workspace.apply(fixture.clean(["c0"]), context: fixture.context)
        #expect(recorder.changes.isEmpty)
        let seen = Mutex(false)
        let background = Thread { seen.withLock { $0 = lease.tree?.node(at: c0) != nil } }
        background.start()
        while !background.isFinished { usleep(1_000) }
        #expect(seen.withLock { $0 })
        #expect(recorder.changes.isEmpty)

        lease.end()
        #expect(recorder.changes.count == 1)
        // Ending twice counts once: the next change still finds no reader and lands straight away.
        lease.end()
        workspace.apply(fixture.clean(["c1"]), context: fixture.context)
        #expect(recorder.changes.count == 2)
        // A lease let go of without `end` still ends.
        _ = workspace.beginRead()
        workspace.apply(fixture.clean(["c2"]), context: fixture.context)
        #expect(recorder.changes.count == 3)
        workspace.read { #expect($0?.inconsistencies() == []) }
    }

    @Test("Focus falls back to the nearest folder that's still there")
    func survivor() throws {
        let fixture = try Fixture()
        try fixture.tree.file("home/cache/c0/deep/er/blob", bytes: 10_000)
        try fixture.tree.file("home/cache/c1/deep/blob", bytes: 10_000)
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        let scanned = try fixture.scanHome()
        workspace.show(scanned)
        let deleted = try #require(scanned.node(at: fixture.tree.path("home/cache/c0/deep/er")))
        let trashed = try #require(scanned.node(at: fixture.tree.path("home/cache/c1/deep")))
        let kept = try #require(scanned.node(at: fixture.tree.path("home/docs")))

        workspace.apply(fixture.clean(["c0"]), context: fixture.context)
        workspace.apply(fixture.clean(["c1"], useTrash: true), context: fixture.context)

        let changes = recorder.changes
        try #require(changes.count == 2)
        let cache = scanned.node(at: fixture.tree.path("home/cache"))
        #expect(changes[0].survivor(of: deleted) === cache)
        #expect(changes[0].isGone(fixture.tree.path("home/cache/c0/deep")))
        // Moved to the Trash: the folder lives on there, but where the person was looking it's gone.
        #expect(changes[1].survivor(of: trashed) === cache)
        #expect(changes[1].isGone(trashed.path))
        #expect(changes[1].survivor(of: kept) === kept)
        #expect(!changes[1].isGone(kept.path))
    }

    @Test("A scan shown while an analysis runs drops that analysis's result")
    func newScanDropsAnalysis() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let held = HeldAnalysis()
        let workspace = Workspace(deliver: recorder.deliver, analyze: held.analyze)
        workspace.show(try fixture.scanHome())
        workspace.analyze(fixture.context)
        held.started.wait()

        let newer = try fixture.scanHome()
        workspace.show(newer)
        held.release.signal()
        usleep(50_000)

        #expect(recorder.analysed.isEmpty)
        #expect(workspace.state.result == nil)
        #expect(workspace.state.tree === newer)
    }

    @Test("Only the latest analysis records a History snapshot")
    func supersededAnalysisRecordsNoHistory() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let held = HeldAnalysis()
        let workspace = Workspace(deliver: recorder.deliver, analyze: held.analyze)
        workspace.show(try fixture.scanHome())
        workspace.analyze(fixture.context)
        held.started.wait()

        workspace.show(try fixture.scanHome())
        // Lands once the superseded analysis stops reading, which is after it would have recorded its snapshot.
        workspace.apply(CleanupReport(dryRun: false), context: fixture.context)
        held.release.signal()
        #expect(recorder.wait { !$0.changes.isEmpty })
        #expect(fixture.context.history.lastSnapshotDate() == nil)

        workspace.analyze(fixture.context)
        held.started.wait()
        held.release.signal()
        #expect(recorder.wait { !$0.analysed.isEmpty })
        #expect(fixture.context.history.lastSnapshotDate() != nil)
    }

    @Test("A scan that started after a cleanup finished isn't changed by that cleanup's removals, still waiting for the old tree")
    func newScanDropsQueuedRemovals() throws {
        let fixture = try Fixture()
        // A small file beside the removed folder: a removal that misses its folder takes a file of that name instead,
        // and with none, a share of the small files.
        try fixture.tree.file("home/cache/index.db", bytes: 40_960)
        let recorder = Recorder()
        let held = HeldAnalysis()
        let workspace = Workspace(deliver: recorder.deliver, analyze: held.analyze)
        workspace.show(try fixture.scanHome())
        workspace.analyze(fixture.context)
        held.started.wait()
        let report = fixture.clean(["c0"])
        // The new scan started after the cleanup finished, so it already shows it.
        let newer = try fixture.scanHome()
        let expected = try fixture.scanHome()
        // The cleanup lands while the analysis reads the old tree, so its removals wait.
        workspace.apply(report, finished: newer.scanStarted.addingTimeInterval(-1), context: fixture.context)

        workspace.show(newer)
        // A change for the new tree, applied once the old analysis stops reading: everything queued before it has
        // been handled by then.
        workspace.apply(CleanupReport(dryRun: false), context: fixture.context)
        held.release.signal()
        #expect(recorder.wait { !$0.changes.isEmpty })

        #expect(recorder.changes.allSatisfy { $0.removals.isEmpty })
        expectTree(workspace, is: newer, like: expected, fixture)
    }

    @Test(
        "A cleanup that finished after the shown scan started is applied to it, however it reached the workspace",
        arguments: [CleanupTiming.waitingForReader, .appliedToOldTree, .betweenScans])
    func newScanKeepsLaterRemovals(_ timing: CleanupTiming) throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let held = HeldAnalysis()
        let workspace = Workspace(deliver: recorder.deliver, analyze: held.analyze)
        workspace.show(try fixture.scanHome())
        if timing == .waitingForReader {
            workspace.analyze(fixture.context)
            held.started.wait()
        }
        if timing == .betweenScans { workspace.show(nil) }
        // The new scan walked c0 before the cleanup removed it.
        let newer = try fixture.scanHome()
        let report = fixture.clean(["c0"])
        let expected = try fixture.scanHome()
        workspace.apply(report, finished: newer.scanStarted.addingTimeInterval(1), context: fixture.context)

        // Applied as the tree is shown, before anything reads it.
        let shown = workspace.show(newer)
        #expect(shown.tree === newer && newer.node(at: fixture.tree.path("home/cache/c0")) == nil)
        held.release.signal()
        expectTree(workspace, is: newer, like: expected, fixture)
    }

    /// The app and the TUI show a finished scan and start its analysis at once. The analysis reads the tree, so a cleanup
    /// waiting for readers would wait for it, and the analysis and its History snapshot would count what was removed.
    @Test("A scan shown and analysed at once is analysed without what a cleanup carried over to it removed")
    func showThenAnalyze() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let c0 = fixture.tree.path("home/cache/c0")
        let sawRemoved = Mutex<Bool?>(nil)
        let analyze: Workspace.Analyze = { context, tree, progress in
            sawRemoved.withLock { $0 = tree?.node(at: c0) != nil }
            return try context.analyzer.analyzeSync(reusing: tree, progress: progress)
        }
        let workspace = Workspace(deliver: recorder.deliver, analyze: analyze)
        workspace.show(try fixture.scanHome())
        let newer = try fixture.scanHome()
        let report = fixture.clean(["c0"])
        workspace.apply(report, finished: newer.scanStarted.addingTimeInterval(1), context: fixture.context)

        workspace.show(newer)
        workspace.analyze(fixture.context)

        #expect(recorder.wait { !$0.analysed.isEmpty })
        #expect(sawRemoved.withLock { $0 } == false)
        let findings = fixture.items(try #require(recorder.analysed.last?.result).analysis.findings)
        let fresh = try fixture.freshFindings()
        #expect(findings[c0] == nil && findings == fresh)
    }

    /// A small file is counted only in its folder's total, so whether the scan already counted a trashed loose file in
    /// the Trash can't be told: the Trash is scanned again instead.
    @Test("Loose files a carried cleanup trashed are counted in the Trash once, from a fresh scan of it")
    func carriedTrashedLooseFiles() throws {
        let fixture = try Fixture()
        let (cache, trash) = (fixture.tree.path("home/cache"), fixture.tree.path("home/.Trash"))
        let names = ["a.tmp", "b.tmp"]
        for name in names { try fixture.tree.file("home/cache/\(name)", bytes: 8_000) }
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        // The cleanup moves the files before the new scan reaches the Trash: it counts them there, in its small files.
        for name in names { try FileManager.default.moveItem(atPath: "\(cache)/\(name)", toPath: "\(trash)/\(name)") }
        let newer = try fixture.scanHome()
        let expected = try fixture.scanHome()
        var report = CleanupReport(dryRun: false)
        let item = CleanupItem(path: cache, kind: .looseFiles, size: 16_000, looseFileNames: names, scanStarted: Date())
        report.items = [(item, .removed(bytes: 16_000, trashedTo: trash))]
        report.trashedLooseFiles[cache] = names.map { "\(trash)/\($0)" }
        workspace.apply(report, finished: newer.scanStarted.addingTimeInterval(1), context: fixture.context)

        workspace.show(newer)
        usleep(200_000)

        expectTree(workspace, is: newer, like: expected, fixture)
    }

    @Test("A carried removal keeps only the removal from where the item was, and names the Trash to scan again")
    func carriedRemovals() throws {
        let fixture = try Fixture()
        try fixture.tree.file("home/cache/a.tmp", bytes: 8_000)
        let tree = try fixture.scanHome()
        let (cache, trash) = (fixture.tree.path("home/cache"), fixture.tree.path("home/.Trash"))
        let item = Removal(path: "\(cache)/c0", kind: .directory, bytes: 1, trashedTo: "\(trash)/c0")
        #expect(item.carried(over: tree) == Removal(path: "\(cache)/c0", kind: .directory, bytes: 1))
        #expect(item.trashFolders == [trash])
        let loose = Removal(path: cache, kind: .looseFiles, bytes: 8_000, trashedTo: trash, trashedFiles: ["\(trash)/a.tmp"])
        #expect(loose.carried(over: tree) == Removal(path: cache, kind: .looseFiles, bytes: 8_000))
        #expect(loose.trashFolders == [trash])
        // Not where it was in this tree: nothing to carry.
        #expect(Removal(path: "\(cache)/gone", kind: .directory, bytes: 1).carried(over: tree) == nil)
    }

    /// The scan may have walked the Trash before the cleanup moved an item there, so it shows the item nowhere once the
    /// removal is carried over; the fresh scan of the Trash brings it back.
    @Test("An item a carried cleanup trashed after the scan walked the Trash arrives there from a fresh scan of it")
    func carriedTrashedItem() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        let newer = try fixture.scanHome()
        let report = fixture.clean(["c1"], useTrash: true)
        let expected = try fixture.scanHome()
        let trashed = try #require(report.items.first?.outcome.trashedTo)
        #expect(PathUtil.parent(trashed) == fixture.tree.path("home/.Trash"))
        workspace.apply(report, finished: newer.scanStarted.addingTimeInterval(1), context: fixture.context)

        workspace.show(newer)

        let trash = fixture.tree.path("home/.Trash")
        #expect(recorder.wait { $0.changes.contains { $0.rescanned == [trash] } })
        expectTree(workspace, is: newer, like: expected, fixture)
        workspace.read { #expect($0?.node(at: trashed) != nil) }
    }

    @Test("A cleanup that finished after the shown scan started changes only what that scan still shows where it was")
    func newScanThatSawTheRemoval() throws {
        let fixture = try Fixture()
        try fixture.tree.file("home/cache/index.db", bytes: 40_960)
        try fixture.tree.file("home/.Trash/c1/blob", bytes: 120_000)
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        // The scan started before the cleanup finished. It reached c0 after the cleanup deleted it, and c1 before the
        // cleanup moved it to the Trash, but the Trash after (c1 stays on disk here, standing in for both places).
        let deleted = fixture.clean(["c0"])
        let newer = try fixture.scanHome()
        let c1 = fixture.tree.path("home/cache/c1")
        let c1Size = try #require(newer.node(at: c1)?.size)
        let (cache, trash) = (fixture.tree.path("home/cache"), fixture.tree.path("home/.Trash"))
        let before = (root: newer.root.size, cache: newer.node(at: cache)?.size, trash: newer.node(at: trash)?.size)
        var report = deleted
        report.items.append(
            (item: CleanupItem(path: c1, size: c1Size), outcome: .removed(bytes: c1Size, trashedTo: fixture.tree.path("home/.Trash/c1"))))
        workspace.apply(report, finished: newer.scanStarted.addingTimeInterval(1), context: fixture.context)

        workspace.show(newer)
        // The Trash is scanned again, and holds what it held when the scan walked it.
        usleep(200_000)

        // c0 is left as the scan found it, and c1 leaves the cache without arriving in the Trash a second time.
        workspace.read { tree in
            #expect(tree?.inconsistencies() == [])
            #expect(tree?.root.size == before.root - c1Size)
            #expect(tree?.node(at: cache)?.size == before.cache.map { $0 - c1Size })
            #expect(tree?.node(at: trash)?.size == before.trash)
            #expect(tree?.node(at: c1) == nil)
        }
    }

    /// The workspace shows `tree`, whose totals match `expected`, a scan of the disk as it is now.
    private func expectTree(_ workspace: Workspace, is tree: ScanTree, like expected: ScanTree, _ fixture: Fixture) {
        workspace.read { shown in
            #expect(shown === tree)
            #expect(shown?.inconsistencies() == [])
            #expect(shown?.root.size == expected.root.size)
            for folder in ["home/cache", "home/.Trash"] {
                #expect(shown?.node(at: fixture.tree.path(folder))?.size == expected.node(at: fixture.tree.path(folder))?.size)
            }
        }
    }

    /// Starts two re-evaluations of the fixture's rule, each after a re-synced Trash, with `between` run in between
    /// (once the first has read the disk).
    private func twoRefreshes(
        _ fixture: Fixture, _ recorder: Recorder, _ held: HeldRefreshes, between: () throws -> Void = {}
    ) throws -> Workspace {
        try fixture.tree.file("home/.Trash/a/blob", bytes: 40_000)
        try fixture.tree.file("home/.Trash/b/blob", bytes: 40_000)
        let workspace = Workspace(deliver: recorder.deliver, analyze: Workspace.analyzeAll, reevaluate: held.reevaluate)
        workspace.show(try fixture.scanHome())
        workspace.analyze(fixture.context)
        #expect(recorder.wait { !$0.analysed.isEmpty })
        let trash = fixture.tree.path("home/.Trash")
        for name in ["a", "b"] {
            try FileManager.default.removeItem(atPath: fixture.tree.path("home/.Trash/\(name)"))
            workspace.resync(
                try Scanner(options: fixture.context.scanOptions).scan(trash), at: trash, over: workspace.state,
                context: fixture.context, reevaluating: [fixture.rule.id])
            held.started.wait()
            if name == "a" { try between() }
        }
        #expect(workspace.state.refreshingRules == [fixture.rule.id])
        return workspace
    }

    @Test("An older re-evaluation of a rule that ends first leaves the spinner of the newer one running")
    func olderRefreshEndsFirst() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let held = HeldRefreshes()
        let workspace = try twoRefreshes(fixture, recorder, held)

        held.releases[0].signal()
        #expect(recorder.wait { $0.refreshed.count == 1 })
        #expect(workspace.state.refreshingRules == [fixture.rule.id])

        held.releases[1].signal()
        #expect(recorder.wait { $0.refreshed.count == 2 })
        #expect(workspace.state.refreshingRules.isEmpty)
    }

    @Test("An older re-evaluation of a rule that ends last doesn't put back findings the newer one no longer has")
    func olderRefreshEndsLast() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        let held = HeldRefreshes()
        // The rule's tool removed c0 after the first re-evaluation read the disk.
        let workspace = try twoRefreshes(fixture, recorder, held) {
            try FileManager.default.removeItem(atPath: fixture.tree.path("home/cache/c0"))
        }

        held.releases[1].signal()
        #expect(recorder.wait { $0.refreshed.count == 1 })
        held.releases[0].signal()
        #expect(recorder.wait { $0.refreshed.count == 2 })

        #expect(workspace.state.refreshingRules.isEmpty)
        let findings = fixture.items(workspace.state.result?.analysis.findings ?? [])
        #expect(findings[fixture.tree.path("home/cache/c0")] == nil)
        #expect(findings[fixture.tree.path("home/cache/c1")] != nil)
    }

    @Test("Re-syncing a folder emptied elsewhere splices it in")
    func resync() throws {
        let fixture = try Fixture()
        try fixture.tree.file("home/.Trash/old/blob", bytes: 80_000)
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        try FileManager.default.removeItem(atPath: fixture.tree.path("home/.Trash/old"))

        let trash = fixture.tree.path("home/.Trash")
        workspace.resync(
            try Scanner(options: fixture.context.scanOptions).scan(trash), at: trash, over: workspace.state, context: fixture.context)

        #expect(recorder.wait { !$0.changes.isEmpty })
        #expect(recorder.changes.first?.rescanned == [trash])
        workspace.read { tree in
            #expect(tree?.inconsistencies() == [])
            #expect(tree?.node(at: fixture.tree.path("home/.Trash/old")) == nil)
        }
    }

    @Test("A folder scanned before a newer tree was shown isn't spliced into it")
    func resyncOfAnOlderTree() throws {
        let fixture = try Fixture()
        try fixture.tree.file("home/.Trash/old/blob", bytes: 80_000)
        let recorder = Recorder()
        let workspace = Workspace(deliver: recorder.deliver)
        workspace.show(try fixture.scanHome())
        let trash = fixture.tree.path("home/.Trash")
        // The Trash scan starts while the first tree is shown; it is older than anything scanned after it.
        let shown = workspace.state
        let older = try Scanner(options: fixture.context.scanOptions).scan(trash)
        try fixture.tree.file("home/.Trash/new/blob", bytes: 80_000)
        let newer = try fixture.scanHome()
        workspace.show(newer)

        workspace.resync(older, at: trash, over: shown, context: fixture.context)

        #expect(recorder.changes.isEmpty)
        workspace.read { tree in
            #expect(tree === newer)
            #expect(tree?.node(at: fixture.tree.path("home/.Trash/new")) != nil)
        }
    }
}
