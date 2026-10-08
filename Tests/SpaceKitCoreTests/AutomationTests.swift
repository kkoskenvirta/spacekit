import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// Collects notifications instead of posting them.
final class RecordingNotifier: Notifier {
    let posted = Mutex<[(title: String, body: String)]>([])

    func notify(title: String, body: String) {
        posted.withLock { $0.append((title, body)) }
    }

    var count: Int { posted.withLock { $0.count } }
}

/// A job runner whose state, rules and removals all stay inside a temporary tree.
struct RunnerFixture {
    let tree: TempTree
    let notifier = RecordingNotifier()
    var rules: [Rule] = []
    var config = SpaceKitConfig()
    var stateDirectory: String

    init() throws {
        tree = try TempTree()
        stateDirectory = tree.path("state")
        config.safety.trash = .rules
        config.automation.snapshot = nil
    }

    var context: SpaceKitContext {
        SpaceKitContext(
            paths: SpaceKitPaths(configFile: tree.path("config/config.yaml"), stateDirectory: stateDirectory), config: config,
            library: RuleLibrary(rules: rules))
    }

    var runner: JobRunner {
        JobRunner(context: context, executor: sandboxExecutor(tree, rules: rules, protectedRules: rules), notifier: notifier)
    }

    func rule(_ id: String, _ relative: String, level: SafetyLevel, action: ActionSpec = ActionSpec(remove: true)) -> Rule {
        Rule(
            id: id, name: id, category: "developer.cache", paths: [tree.path(relative)], granularity: .children,
            safety: SafetySpec(level: level, trash: false), action: action)
    }
}

@Suite("Job runner")
struct JobRunnerTests {
    @Test("A job's plan run by hand goes through the review: its warnings run only once the person accepts them")
    func manualRunsNeedConfirmation() throws {
        var fixture = try RunnerFixture()
        try fixture.tree.file("home/models/a/weights.bin", bytes: 4096)
        fixture.rules = [fixture.rule("models", "home/models", level: .review)]
        let job = Job(id: "models", name: "Models", rules: ["models"], action: .delete)
        let runner = fixture.runner
        let review = CleanupReview(runner.plan(for: try runner.evaluate(job)), executor: runner.executor)
        #expect(review.needsAcknowledgement)

        let unconfirmed = runner.executor.execute(review.acknowledge(acceptingWarnings: false), dryRun: false)
        #expect(unconfirmed.freedBytes == 0)
        #expect(unconfirmed.skipped.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.tree.path("home/models/a")))

        let confirmed = runner.executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(confirmed.freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.tree.path("home/models/a")))
    }

    @Test("The agent's log names the built-in rules a person's own rule files replace")
    func agentNamesOverrides() throws {
        let fixture = try RunnerFixture()
        try fixture.tree.directory("rules")
        let cache = fixture.tree.path("home/cache")
        let file = fixture.tree.path("rules/cache.yaml")
        try "id: base.cache\nname: Cache\npath: \(cache)\nsafety: safe\nexclusions: [\"*/keep\"]\naction: remove\n".write(
            toFile: file, atomically: true, encoding: .utf8)
        let builtin = BuiltinRules(files: [
            RuleFileText(
                source: "built-in rules/base.yaml", yaml: "id: base.cache\nname: Cache\npath: \(cache)\nsafety: safe\naction: remove\n")
        ])
        let library = RuleLibrary.load(builtin: builtin, directories: [fixture.tree.path("rules")])
        #expect(library.overrides.map(\.id) == ["base.cache"])

        var config = fixture.config
        config.jobs = [Job(id: "cache", name: "Cache", rules: ["base.cache"], mode: .observe)]
        let context = SpaceKitContext(
            paths: SpaceKitPaths(configFile: fixture.tree.path("config/config.yaml"), stateDirectory: fixture.stateDirectory),
            config: config,
            library: library)
        let runner = JobRunner(context: context, notifier: fixture.notifier)
        let start = Date()
        _ = runner.runDue(now: start)
        var lines: [String] = []
        let results = runner.runDue(now: start.addingTimeInterval(30 * 86_400)) { lines.append($0) }
        #expect(results.count == 1)
        #expect(lines.contains { $0.contains("base.cache") && $0.contains(PathUtil.abbreviate(file)) }, "\(lines)")
    }

    @Test("Automatic runs clean safe items, notify even with notifications off, and record state")
    func automaticRun() throws {
        var fixture = try RunnerFixture()
        try fixture.tree.file("home/build/app/out.o", bytes: 8192)
        fixture.rules = [fixture.rule("build", "home/build", level: .safe)]
        fixture.config.automation.notifications = false
        let job = Job(id: "build", name: "Build", rules: ["build"], mode: .automatic, action: .delete)

        let result = fixture.runner.run(job)
        guard case .cleaned(let report) = result.action else {
            Issue.record("expected a cleanup")
            return
        }
        #expect(report.freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.tree.path("home/build/app")))
        #expect(fixture.notifier.count == 1)
        #expect(result.recordError == nil)
        let state = try #require(fixture.context.jobStates.load()["build"])
        // The state file stores whole seconds.
        #expect(abs(try #require(state.lastRun).timeIntervalSince(result.date)) < 1)
        #expect(state.lastOutcome == result.summary)
        let journal = Journal(file: fixture.tree.path("state/journal.jsonl")).entries()
        #expect(journal.first?.automatic == true)
        #expect(journal.first?.jobID == "build")
    }

    @Test("Skipped commands count as something to report")
    func skippedCommands() throws {
        var fixture = try RunnerFixture()
        try fixture.tree.file("home/tool/cache/blob", bytes: 4096)
        fixture.rules = [
            fixture.rule("tool", "home/tool", level: .safe, action: ActionSpec(command: ["spacekit-test-missing-tool", "prune"]))
        ]
        let job = Job(id: "tool", name: "Tool", rules: ["tool"], mode: .automatic)

        let result = fixture.runner.run(job)
        #expect(result.summary.contains("1 command skipped"))
        #expect(fixture.notifier.count == 1)
        #expect(fixture.notifier.posted.withLock { $0.first?.body.contains("1 command skipped") } == true)
    }

    @Test("Observe runs respect automation.notifications")
    func observeNotifications() throws {
        var fixture = try RunnerFixture()
        try fixture.tree.file("home/logs/a/log.txt", bytes: 4096)
        fixture.rules = [fixture.rule("logs", "home/logs", level: .safe)]
        let job = Job(id: "logs", name: "Logs", rules: ["logs"], mode: .observe)

        fixture.config.automation.notifications = false
        _ = fixture.runner.run(job)
        #expect(fixture.notifier.count == 0)
        fixture.config.automation.notifications = true
        _ = fixture.runner.run(job)
        #expect(fixture.notifier.count == 1)
    }

    @Test("A state or suggestion that can't be saved is reported, not swallowed")
    func surfacedWriteErrors() throws {
        var fixture = try RunnerFixture()
        try fixture.tree.file("home/logs/a/log.txt", bytes: 4096)
        try fixture.tree.file("blocker", bytes: 1)
        fixture.stateDirectory = fixture.tree.path("blocker/state")
        fixture.rules = [fixture.rule("logs", "home/logs", level: .safe)]

        let observed = fixture.runner.run(Job(id: "logs", name: "Logs", rules: ["logs"], mode: .observe))
        #expect(observed.recordError != nil)

        let suggested = fixture.runner.run(Job(id: "logs", name: "Logs", rules: ["logs"], mode: .suggest))
        guard case .failed(let message) = suggested.action else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("suggestion"))
        #expect(fixture.notifier.count == 1)  // only the observe run's
    }

    @Test("Rule-following jobs tell the guard their own folders go to the Trash")
    func usesTrashForRuleAction() throws {
        let fixture = try RunnerFixture()
        let job = Job(id: "dl", name: "Old downloads", paths: [fixture.tree.path("home/Downloads/old")], action: .rule)
        #expect(fixture.runner.automationContext(for: job).usesTrash)
        #expect(!fixture.runner.automationContext(for: Job(id: "d", name: "D", paths: ["~/x"], action: .delete)).usesTrash)
    }

    @Test("A job's own folders get a documented category")
    func customCategory() throws {
        let fixture = try RunnerFixture()
        try fixture.tree.file("home/Work/scratch/a.txt", bytes: 4096)
        let job = Job(id: "scratch", name: "Scratch", paths: [fixture.tree.path("home/Work/scratch")])
        let evaluation = try fixture.runner.evaluate(job)
        let category = try #require(evaluation.findings.first?.rule.category)
        #expect(["developer", "ai", "cache", "system", "personal"].contains(String(category.split(separator: ".")[0])))
    }
}

@Suite("Automation stores")
struct AutomationStoreTests {
    @Test("Concurrent job-state updates don't lose each other's changes")
    func lockedJobState() throws {
        let tree = try TempTree()
        let store = JobStateStore(file: tree.path("state/jobs-state.json"))
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            try? store.update("job\(index)") { $0.lastOutcome = "ran \(index)" }
        }
        #expect(store.load().count == 40)
    }

    @Test("Concurrent suggestions don't lose each other")
    func lockedSuggestions() throws {
        let tree = try TempTree()
        let store = SuggestionStore(file: tree.path("state/suggestions.json"))
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            try? store.add(Suggestion(jobID: "job\(index)", jobName: "Job", plan: CleanupPlan()))
        }
        #expect(store.all().count == 40)
    }

    @Test("Suggestions are found by exact id or a unique prefix of at least 4 characters")
    func suggestionLookup() throws {
        let tree = try TempTree()
        let store = SuggestionStore(file: tree.path("suggestions.json"))
        for (id, job) in [("abcd1234", "a"), ("abcd9999", "b"), ("ffee0011", "c")] {
            var suggestion = Suggestion(jobID: job, jobName: job, plan: CleanupPlan())
            suggestion.id = id
            try store.add(suggestion)
        }
        #expect(store.get("abcd1234")?.jobID == "a")
        #expect(store.get("ffee")?.jobID == "c")
        #expect(store.get("abcd") == nil)  // ambiguous
        #expect(store.get("ffe") == nil)  // too short
        #expect(store.get("") == nil)
    }
}
