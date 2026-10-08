import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Front-end support")
struct FrontEndSupportTests {
    @Test("Rule docs open only as https links")
    func docsLinks() {
        func url(_ docs: String?) -> URL? { Rule(id: "r", name: "r", docs: docs).docsURL }
        #expect(url("https://docs.example.com/cache")?.host == "docs.example.com")
        #expect(url("HTTPS://example.com") != nil)
        #expect(url(nil) == nil)
        #expect(url("http://example.com") == nil)
        #expect(url("file:///Applications/Calculator.app") == nil)
        #expect(url("x-apple.systempreferences:com.apple.preference.security") == nil)
        #expect(url("javascript:alert(1)") == nil)
        #expect(url("https:///no-host") == nil)
        #expect(url("not a url") == nil)
    }

    @Test("Emptying the Trash plans each top-level entry and the loose files, deleted, under the Trash rule")
    func trashPlan() throws {
        let tree = try TempTree()
        let home = tree.path("home")
        try tree.file("home/.Trash/old project/a.bin", bytes: 8_000)
        try tree.file("home/.Trash/loose.dmg", bytes: 4_000)
        try tree.directory("home/.Trash/empty")
        let rule = Rule(id: "system.trash", name: "Trash", paths: ["~/.Trash"])
        let other = Rule(id: "other", name: "Other", paths: ["~/Downloads"])
        #expect(Trash.rules(in: [other, rule], home: home).map(\.id) == ["system.trash"])

        let created = Date()
        let plan = Trash.emptyingPlan(try scan(Trash.path(home: home)), rules: [other, rule], created: created, home: home)
        #expect(!plan.useTrash)
        #expect(plan.created == created)
        #expect(plan.items.map(\.kind) == [.directory, .looseFiles])
        #expect(plan.items.map(\.path) == [tree.path("home/.Trash/old project"), tree.path("home/.Trash")])
        #expect(plan.items.allSatisfy { $0.ruleID == "system.trash" })
    }

    @Test("Spinner frames cycle, also for negative ticks")
    func spinner() {
        #expect(Spinner.frame(0) == Spinner.frames[0])
        #expect(Spinner.frame(Spinner.frames.count + 1) == Spinner.frames[1])
        #expect(Spinner.frames.contains(Spinner.frame(-3)))
    }

    @Test("An Explore entry becomes a cleanup item with its git facts; the smaller-files block can't")
    func diskItemConversion() throws {
        let tree = try TempTree()
        try tree.file("root/work/app/.git/HEAD", bytes: 100)
        try tree.file("root/work/app/main.swift", bytes: 4_000)
        try tree.file("root/big.bin", bytes: 40_000)
        try tree.file("root/tiny.txt", bytes: 10)
        let scanned = try scan(tree.path("root"), minFileSize: 20_000, markers: [".git"])
        let items = scanned.root.items
        let work = try #require(items.first { $0.name == "work" })
        let converted = try #require(CleanupItem(work, markers: scanned.markers, ruleID: "r"))
        #expect(converted.kind == .directory && converted.ruleID == "r")
        #expect(!converted.isRepository && converted.containsRepository)
        let appEntry = try #require(work.directory?.items.first { $0.name == "app" })
        let app = try #require(CleanupItem(appEntry, markers: scanned.markers, ruleID: nil))
        #expect(app.isRepository)
        #expect(CleanupItem(work, markers: nil, ruleID: nil)?.containsRepository == false)
        let fileEntry = try #require(items.first { $0.name == "big.bin" })
        let file = try #require(CleanupItem(fileEntry, markers: scanned.markers, ruleID: nil))
        #expect(file.kind == .file && file.path == tree.path("root/big.bin"))
        let others = try #require(items.first { if case .otherFiles = $0 { return true } else { return false } })
        #expect(CleanupItem(others, markers: scanned.markers, ruleID: nil) == nil)
    }

    @Test("Finding facts list what applies, in order")
    func findingFacts() {
        let now = Date()
        var rule = Rule(
            id: "r", name: "R", paths: ["~/x"], safety: SafetySpec(level: .review), action: ActionSpec(command: ["brew", "cleanup"]))
        rule.recreatedBy = "brew"
        let items = [
            FindingItem(path: "/a", kind: .directory, name: "a", size: 1_000_000, lastUsed: now.addingTimeInterval(-3 * 86_400)),
            FindingItem(path: "/b", kind: .directory, name: "b", size: 1_000_000),
        ]
        let facts = Finding(rule: rule, items: items).facts(now: now)
        #expect(facts.map(\.kind) == [.reclaimable, .risk, .recreatedBy, .lastUsed, .items, .cleansWith])
        #expect(facts.first { $0.kind == .cleansWith }?.value == "brew cleanup")
        #expect(facts.first { $0.kind == .items }?.label == "Items")

        let reportOnly = Rule(id: "p", name: "P", paths: ["~/y"], safety: SafetySpec(level: .protected))
        let single = Finding(rule: reportOnly, items: [items[1]]).facts(now: now)
        #expect(single.map(\.kind) == [.risk])
    }

    @Test("AI model status and disk fullness")
    func statusAndFullness() {
        let now = Date()
        func model(_ kind: AIModel.Kind, used: Date?) -> AIModel {
            AIModel(name: "m", kind: kind, size: 1, lastUsed: used, paths: [], removeCommand: nil, ruleID: "r")
        }
        #expect(model(.model, used: now).status(within: .days(90), now: now) == .active)
        #expect(model(.dataset, used: nil).status(within: .days(90), now: now) == .idle)
        #expect(model(.cache, used: now).status(within: .days(90), now: now) == .cache)
        #expect(model(.orphaned, used: now).status(within: .days(90), now: now) == .orphaned)

        func disk(usedPercent: UInt64) -> VolumeCapacity {
            VolumeCapacity(name: "d", mountPoint: "/", total: 100, freeNow: 100 - usedPercent, available: 100 - usedPercent)
        }
        #expect(disk(usedPercent: 50).fullness == .comfortable)
        #expect(disk(usedPercent: 80).fullness == .filling)
        #expect(disk(usedPercent: 95).fullness == .nearlyFull)
    }

    @Test("Explore notes name the rule first; plain entries get none")
    func diskItemNotes() throws {
        let tree = try TempTree()
        try tree.file("root/folder/a.bin", bytes: 4_000)
        let scanned = try scan(tree.path("root"))
        let folder = try #require(scanned.root.items.first { $0.name == "folder" })
        let rule = Rule(id: "r", name: "R", paths: [tree.path("root/folder")])
        guard case .rule(let noted)? = folder.note(rule: rule) else {
            Issue.record("expected the rule")
            return
        }
        #expect(noted.id == "r")
        #expect(folder.note(rule: nil) == nil)
    }

    @Test("Tool homes count as developer or AI storage and are never searched by pattern rules")
    func toolHomes() {
        let home = "/Users/tester"
        let locations = CategoryBreakdown.locations(home: home)
        #expect(locations["/Users/tester/.volta"] == .developer)
        #expect(locations["/Users/tester/.cargo"] == .developer)
        #expect(locations["/Users/tester/.ollama"] == .ai)
        let excludes = Set(RuleEngine.defaultPatternExcludes)
        #expect(Set(ToolHomes.developer + ToolHomes.ai).isSubset(of: excludes))
        #expect(excludes.contains("~/Library") && excludes.contains("~/.claude"))
    }
}
