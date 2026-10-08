import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Cleanup executor")
struct CleanupExecutorTests {
    @Test("Dry runs touch nothing")
    func dryRun() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/app/build/out.o", bytes: 10_000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/app/build"), size: 10_000)], useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree), dryRun: true)
        #expect(report.items.map(\.outcome) == [.wouldRemove(bytes: 10_000)])
        #expect(FileManager.default.fileExists(atPath: tree.path("home/Projects/app/build/out.o")))
        #expect(Journal(file: tree.path("state/journal.jsonl")).entries().isEmpty)
    }

    @Test("Removes, journals and reports")
    func removes() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/app/build/out.o", bytes: 10_000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/app/build"), size: 10_000)], useTrash: false)
        // Reported and journaled sizes are measured at removal time: allocated blocks, not the plan's figure.
        let allocated = tree.allocated("home/Projects/app/build/out.o")
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.freedBytes == allocated)
        #expect(!FileManager.default.fileExists(atPath: tree.path("home/Projects/app/build")))
        #expect(FileManager.default.fileExists(atPath: tree.path("home/Projects/app")))
        let entries = Journal(file: tree.path("state/journal.jsonl")).entries()
        #expect(entries.count == 1)
        #expect(entries.first?.bytes == allocated)
        #expect(entries.first?.automatic == false)
    }

    @Test("Unconfirmed warnings and blocks are skipped, not removed")
    func skips() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/app/notes.txt", bytes: 100)
        try tree.directory("home/Projects/app/.git")
        let items = [
            CleanupItem(path: tree.path("home/Projects/app"), size: 100, isRepository: true),
            CleanupItem(path: tree.path("home"), size: 100),
        ]
        let plan = CleanupPlan(items: items, useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree), acceptingWarnings: false)
        #expect(report.freedBytes == 0)
        #expect(report.skipped.count == 2)
        #expect(FileManager.default.fileExists(atPath: tree.path("home/Projects/app/notes.txt")))
    }

    @Test("Automatic runs stop at the byte budget")
    func budget() throws {
        let tree = try TempTree()
        let rule = Rule(
            id: "dd", name: "DD", paths: [tree.path("home/dd")], granularity: .children,
            safety: SafetySpec(level: .safe, trash: false), action: ActionSpec(remove: true))
        try tree.file("home/dd/a/x", bytes: 6000)
        try tree.file("home/dd/b/y", bytes: 6000)
        let items = [
            CleanupItem(path: tree.path("home/dd/a"), size: 6000, ruleID: "dd"),
            CleanupItem(path: tree.path("home/dd/b"), size: 6000, ruleID: "dd"),
        ]
        let allocated = tree.allocated("home/dd/a/x")
        let report = sandboxExecutor(tree, rules: [rule], budget: ByteCount(10_000))
            .execute(AutomaticPlan(CleanupPlan(items: items, useTrash: false), automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.freedBytes == allocated)
        #expect(report.skipped.count == 1)
    }

    @Test("Loose files are removed without touching subfolders")
    func looseFiles() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a.tmp", bytes: 1000)
        try tree.file("home/cache/b.tmp", bytes: 1000)
        try tree.file("home/cache/sub/keep.bin", bytes: 1000)
        let item = CleanupItem(
            path: tree.path("home/cache"), kind: .looseFiles, size: 2000, looseFileNames: ["a.tmp", "b.tmp"], scanStarted: Date())
        let plan = CleanupPlan(items: [item], useTrash: false)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: tree.path("home/cache/a.tmp")))
        #expect(FileManager.default.fileExists(atPath: tree.path("home/cache/sub/keep.bin")))
    }

    @Test("Untrusted commands don't run")
    func untrustedCommand() throws {
        let tree = try TempTree()
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "x", arguments: ["/bin/rm", "-rf", tree.root], estimatedBytes: 1)])
        let report = manualRun(plan, with: sandboxExecutor(tree))
        if case .skipped = report.commands.first?.outcome {} else { Issue.record("rm must not run") }
        #expect(FileManager.default.fileExists(atPath: tree.root))
    }
}

@Suite("Config")
struct ConfigTests {
    @Test("The starter template parses and validates")
    func template() throws {
        let config = try ConfigStore.parse(ConfigStore.template)
        #expect(config.jobs.count == 3)
        #expect(config.jobs[0].mode == .automatic)
        #expect(config.jobs[0].when.sizeAbove == .gb(30))
        #expect(config.jobs[0].when.keepRecent == .days(14))
        #expect(config.jobs[0].schedule.weekday == .sunday)
        #expect(config.safety.trash == .always)
    }

    @Test("Empty and comment-only files give defaults")
    func empty() throws {
        #expect(try ConfigStore.parse("") == SpaceKitConfig())
        #expect(try ConfigStore.parse("# nothing yet\n") == SpaceKitConfig())
    }

    @Test("Saving round-trips")
    func roundTrip() throws {
        let tree = try TempTree()
        let store = ConfigStore(file: tree.path("config.yaml"))
        var config = try ConfigStore.parse(ConfigStore.template)
        config.safety.protectedPaths = ["~/Work"]
        config.jobs[1].enabled = false
        try store.save(config)
        #expect(try store.load() == config)
        try store.save(config)
        #expect(FileManager.default.fileExists(atPath: tree.path("config.yaml.bak")))
    }

    @Test("Mistakes are reported with their location")
    func errors() {
        #expect(throws: (any Error).self) { try ConfigStore.parse("safety:\n  maxBytesPerRun: lots\n") }
        #expect(throws: (any Error).self) { try ConfigStore.parse("jobs:\n  - name: x\n") }
        #expect(throws: (any Error).self) { try ConfigStore.parse("jobs:\n  - name: x\n    rules: [a]\n    schedule: sometimes\n") }
    }

    @Test("Sizes and ages parse in human units")
    func units() {
        #expect(ByteCount.parse("30GB") == .gb(30))
        #expect(ByteCount.parse("1.5 TB") == .tb(1.5))
        #expect(ByteCount.parse("512MiB")?.bytes == 512 * 1_048_576)
        #expect(ByteCount.parse("lots") == nil)
        #expect(ByteCount.format(34_800_000_000) == "34.8 GB")
        #expect(ByteCount.format(143_000_000_000) == "143 GB")
        #expect(ByteCount.gb(30).compact == "30GB")
        #expect(Age.parse("14d") == .days(14))
        #expect(Age.parse("2w") == .days(14))
        #expect(Age.parse("3mo") == .days(90))
        #expect(Age.parse("60 days") == .days(60))
        #expect(Age.days(14).description == "2w")
    }

    @Test("Schedules parse and compute the next run")
    func schedules() throws {
        let sunday = try #require(Schedule.parse("sunday 03:00"))
        #expect(sunday.every == .weekly)
        #expect(sunday.weekday == .sunday)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let wednesday = Date(timeIntervalSince1970: 1_791_331_200)  // 2026-10-07 00:00 UTC, a Wednesday
        let next = sunday.nextRun(after: wednesday, calendar: calendar)
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: next)
        #expect(parts.weekday == 1 && parts.hour == 3 && parts.minute == 0)
        #expect(Schedule.parse("daily at 02:30")?.at == "02:30")
        #expect(Schedule.parse("monthly")?.day == 1)
        #expect(Schedule.parse("whenever") == nil)
    }

    @Test("Modes order by what a job does on its own, schedules by the time between runs, weekdays from Sunday = 1")
    func orderings() {
        #expect(Job.Mode.allCases.sorted() == [.observe, .suggest, .automatic])
        #expect(Job.Mode.observe < .suggest && Job.Mode.suggest < .automatic && !(Job.Mode.automatic < .automatic))
        #expect(Schedule.Frequency.allCases.sorted() == [.hourly, .daily, .weekly, .monthly])
        #expect(Schedule.Frequency.hourly < .monthly && !(Schedule.Frequency.weekly < .daily))
        #expect(Weekday.allCases.map(\.number) == Array(1...7))
        #expect(Weekday.sunday.number == 1 && Weekday.saturday.number == 7)
    }
}

@Suite("History")
struct HistoryTests {
    @Test("Usage deltas and what grew")
    func growth() throws {
        let tree = try TempTree()
        let store = HistoryStore(file: tree.path("history.jsonl"))
        let now = Date()
        let start = now.addingTimeInterval(-20 * 86_400)
        try store.append(
            HistoryRecord(
                date: start, kind: .snapshot, total: 1000, used: 700, available: 300, purgeable: 0,
                categories: nil, groups: ["Xcode": 100, "Ollama": 50, "Docker": 80]))
        try store.append(
            HistoryRecord(
                date: now, kind: .snapshot, total: 1000, used: 773, available: 227, purgeable: 0,
                categories: nil, groups: ["Xcode": 131, "Ollama": 68, "Docker": 70]))
        #expect(store.usedDelta(over: .days(30), now: now) == 73)
        let grew = store.whatGrew(over: .days(30), now: now)
        #expect(grew.map(\.name) == ["Xcode", "Ollama", "Docker"])
        #expect(grew.first?.delta == 31)
    }
}
