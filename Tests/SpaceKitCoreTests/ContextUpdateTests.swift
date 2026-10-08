import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// A config file and a user rules folder inside a temp tree, as every front end loads them.
private struct ConfigFixture {
    let tree: TempTree
    var paths: SpaceKitPaths { SpaceKitPaths(configFile: tree.path("config/config.yaml"), stateDirectory: tree.path("state")) }
    var file: String { paths.configFile }

    init() throws {
        tree = try TempTree()
        try tree.directory("config/rules")
    }

    func write(_ text: String) throws {
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    func text() throws -> String { try String(contentsOfFile: file, encoding: .utf8) }

    /// `context`'s executor, moving what it trashes into the temp tree's own `.Trash`, never the real one.
    func executor(of context: SpaceKitContext) -> CleanupExecutor {
        var executor = context.executor
        executor.trash = sandboxTrash(home: tree.root)
        return executor
    }

    /// A user rule that only a library loaded after this call contains.
    func addRule(_ id: String) throws {
        try "id: \(id)\nname: \(id)\npath: ~/.\(id)/cache\nsafety: safe\naction: remove\n"
            .write(toFile: paths.userRulesDirectory + "/\(id).yaml", atomically: true, encoding: .utf8)
    }
}

@Suite("Config changes through the context")
struct ContextUpdateTests {
    @Test("A plan reviewed before a settings change is refused by the new context's executor; an unchanged one runs")
    func reviewOutlivesNoChange() throws {
        let fixture = try ConfigFixture()
        try fixture.tree.file("work/old/x", bytes: 1_000)
        let context = SpaceKitContext.load(paths: fixture.paths)
        let plan = CleanupPlan(items: [CleanupItem(path: fixture.tree.path("work/old"), size: 1_000)], useTrash: false)
        let reviewed = CleanupReview(plan, executor: fixture.executor(of: context)).acknowledge(acceptingWarnings: true)

        let reread = context.rereadingConfig()
        #expect(!fixture.executor(of: reread).execute(reviewed, dryRun: true).reviewOutdated, "nothing changed, so the review holds")

        let changed = try context.applying { $0.safety.protectedPaths = ["~/Work"] }
        let refused = fixture.executor(of: changed).execute(reviewed, dryRun: true)
        #expect(refused.reviewOutdated)
        #expect(refused.items.map(\.outcome) == [.skipped(reason: CleanupExecutor.outdatedReview, kind: .changedSinceReview)])
    }

    @Test("Changing jobs keeps the loaded rule library")
    func jobsKeepLibrary() throws {
        let fixture = try ConfigFixture()
        let context = SpaceKitContext.load(paths: fixture.paths)
        try fixture.addRule("late.rule")

        let changed = try context.applying { $0.upsertJob(Job(id: "a", name: "A", rules: ["x"]), replacing: nil) }

        #expect(changed.config.jobs.map(\.id) == ["a"])
        #expect(changed.library.rule(id: "late.rule") == nil)
        #expect(try fixture.text().contains("id: a"))
    }

    @Test("Changing disabled rules reloads the rule library")
    func disabledReloadsLibrary() throws {
        let fixture = try ConfigFixture()
        try fixture.addRule("first.rule")
        let context = SpaceKitContext.load(paths: fixture.paths)
        #expect(context.library.rule(id: "first.rule") != nil)
        try fixture.addRule("late.rule")

        let changed = try context.applying { $0.rules.disabled = ["first.rule"] }

        #expect(changed.library.rule(id: "first.rule") == nil)
        #expect(changed.library.rule(id: "late.rule") != nil)
    }

    @Test("A change adopts a config file fixed since the context loaded it invalid")
    func adoptsFixedFile() throws {
        let fixture = try ConfigFixture()
        try fixture.write("safety:\n  trash: sometimes\n")
        let context = SpaceKitContext.load(paths: fixture.paths)
        #expect(context.configError != nil)
        try fixture.write("safety:\n  protectedPaths: [~/Work]\njobs:\n  - id: a\n    name: A\n    rules: [x]\n")

        let changed = try context.applying { $0.upsertJob(Job(id: "b", name: "B", rules: ["y"]), replacing: nil) }

        #expect(changed.configError == nil)
        #expect(changed.executor.configError == nil)
        #expect(changed.config.safety.protectedPaths == ["~/Work"])
        #expect(changed.config.jobs.map(\.id) == ["a", "b"])
        #expect(try ConfigStore(file: fixture.file).load() == changed.config)
    }

    @Test("A change to a file that is invalid now is refused with its problem, and the file stays as it is")
    func refusesInvalidFile() throws {
        let fixture = try ConfigFixture()
        try fixture.write("ui:\n  mapDepth: 5\n")
        let context = SpaceKitContext.load(paths: fixture.paths)
        #expect(context.configError == nil)
        let broken = "safety:\n  trash: sometimes\n"
        try fixture.write(broken)

        let error = try #require(throws: ConfigError.self) { try context.applying { $0.ui.mapDepth = 3 } }

        #expect(error.localizedDescription.contains("trash"))
        #expect(try fixture.text() == broken)
        #expect(!FileManager.default.fileExists(atPath: fixture.file + ".bak"))
    }

    @Test("A context loaded invalid refuses a change while the file is still invalid")
    func stillInvalidRefused() throws {
        let fixture = try ConfigFixture()
        let broken = "safety:\n  protectedPaths: [~/Work]\n  trash: sometimes\n"
        try fixture.write(broken)
        let context = SpaceKitContext.load(paths: fixture.paths)

        #expect(throws: ConfigError.self) { try context.applying { $0.ui.mapDepth = 3 } }
        #expect(try fixture.text() == broken)
    }

    @Test("Re-reading picks up edits made elsewhere, and an invalid file stops cleaning")
    func rereadFollowsFile() throws {
        let fixture = try ConfigFixture()
        try fixture.write("ui:\n  mapDepth: 5\n")
        let context = SpaceKitContext.load(paths: fixture.paths)
        try fixture.addRule("late.rule")

        try fixture.write("ui:\n  mapDepth: 5\njobs:\n  - id: a\n    name: A\n    rules: [x]\n")
        let edited = context.rereadingConfig()
        #expect(edited.config.jobs.map(\.id) == ["a"])
        #expect(edited.library.rule(id: "late.rule") == nil)

        try fixture.write("safety:\n  trash: sometimes\n")
        let broken = edited.rereadingConfig()
        #expect(broken.configError != nil)
        #expect(broken.executor.configError == broken.configError)
    }

    @Test("A front end relabels findings only for rule settings, and rebuilds its labels for those or developer roots")
    func relabelling() throws {
        let fixture = try ConfigFixture()
        let context = SpaceKitContext.load(paths: fixture.paths)

        let jobs = try context.applying { $0.upsertJob(Job(id: "a", name: "A", rules: ["x"]), replacing: nil) }
        #expect(jobs.relabelling(since: context) == .init(reindex: false, rebuildIndex: false))
        let roots = try jobs.applying { $0.scan.devRoots = ["~/Work"] }
        #expect(roots.relabelling(since: jobs) == .init(reindex: false, rebuildIndex: true))
        let rules = try roots.applying { $0.rules.disabled = ["x"] }
        #expect(rules.relabelling(since: roots) == .init(reindex: true, rebuildIndex: true))
    }

    @Test("Saving to an unchanged file keeps the context's config")
    func unchangedKeepsConfig() throws {
        let fixture = try ConfigFixture()
        try fixture.write("ui:\n  mapDepth: 5\n")
        let context = SpaceKitContext.load(paths: fixture.paths)

        let same = try context.applying { $0.ui.mapDepth = 5 }

        #expect(same.config == context.config)
        #expect(try fixture.text() == "ui:\n  mapDepth: 5\n")
    }
}

@Suite("Mount table freshness")
struct MountTableTests {
    @Test("A run reads the mount table once, so a volume mounted after the review is still never removed")
    func runReadsMounts() throws {
        let tree = try TempTree()
        try tree.file("home/mnt/data", bytes: 1000)
        let mountPoint = try #require(PathUtil.realpath(tree.path("home/mnt")))
        let reads = Mutex(0)
        var executor = sandboxExecutor(tree)
        let mounted = MountedVolume(mountPoint: mountPoint, device: "/dev/disk9s1", fileSystem: "apfs", deviceID: 99, isBrowsable: true)
        executor.readMounts = {
            reads.withLock { $0 += 1 }
            return VolumeTable(volumes: [mounted], firmlinks: [])
        }
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/mnt"), size: 1000)], useTrash: false)

        let review = CleanupReview(plan, executor: executor)
        #expect(review.blockedCount == 0)
        #expect(reads.withLock { $0 } == 0)

        let report = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)

        #expect(reads.withLock { $0 } == 1)
        // The review didn't show the block, so it is reported as a change since the review, which is a problem.
        #expect(report.skipped.first?.reason.hasPrefix(CleanupExecutor.changedSinceReview + "Blocked") == true)
        #expect(report.hasProblems)
        #expect(onDisk(tree.path("home/mnt/data")))
    }

    @Test("A context's executor reads the mount table per run")
    func contextExecutorReadsMounts() throws {
        let tree = try TempTree()
        let context = SpaceKitContext.load(paths: SpaceKitPaths(configFile: tree.path("config.yaml"), stateDirectory: tree.path("state")))
        #expect(context.executor.readMounts != nil)
    }
}
