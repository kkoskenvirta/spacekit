import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Rules")
struct RuleTests {
    @Test("The storage-rule format from the project brief parses as-is")
    func briefFormat() throws {
        let yaml = """
            name: Xcode DerivedData
            category: developer.build
            path:
              - ~/Library/Developer/Xcode/DerivedData

            policy:
              type: size
              threshold: 30GB

            safety:
              level: safe
              trash: true

            exclusions:
              - active_projects

            action:
              remove: true
            """
        let rules = try RuleLibrary.parse(yaml: yaml)
        let rule = try #require(rules.first)
        #expect(rule.id == "xcode-deriveddata")
        #expect(rule.paths == ["~/Library/Developer/Xcode/DerivedData"])
        #expect(rule.policy?.threshold == .gb(30))
        #expect(rule.safety.level == .safe)
        #expect(rule.safety.trash)
        #expect(rule.action.remove)
        #expect(rule.exclusions == ["active_projects"])
    }

    @Test("List files apply group and category defaults; shorthands decode")
    func listFile() throws {
        let yaml = """
            group: JavaScript
            category: developer.cache
            rules:
              - id: node.npm-cache
                name: npm cache
                path: ~/.npm/_cacache
                safety: regenerable
                action: remove
              - id: node.node-modules
                name: node_modules
                category: developer.build
                match:
                  name: node_modules
                  sibling: package.json
            """
        let rules = try RuleLibrary.parse(yaml: yaml)
        #expect(rules.count == 2)
        #expect(rules[0].group == "JavaScript")
        #expect(rules[0].category == "developer.cache")
        #expect(rules[0].safety.level == .safe)
        #expect(rules[1].category == "developer.build")
        #expect(rules[1].match?.names == ["node_modules"])
        #expect(rules[1].match?.sibling == ["package.json"])
        #expect(!rules[1].action.isCleanable)
    }

    @Test("Validation rejects dangerous or broken rules")
    func validation() {
        let tooBroad = Rule(id: "bad.home", name: "Home", paths: ["~"], safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let root = Rule(id: "bad.root", name: "Root", paths: ["/"], safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let relative = Rule(id: "bad.relative", name: "Relative", paths: ["Library/Caches"])
        let protectedWithAction = Rule(
            id: "bad.protected", name: "Keys", paths: ["~/.ssh"], safety: SafetySpec(level: .protected), action: ActionSpec(remove: true))
        let nothing = Rule(id: "bad.empty", name: "Empty")
        let shell = Rule(id: "bad.shell", name: "Shell", paths: ["~/.cache/x"], action: ActionSpec(command: ["brew", "cleanup;", "rm"]))
        let issues = RuleLibrary(rules: [tooBroad, root, relative, protectedWithAction, nothing, shell]).validate()
        let errored = Set(issues.filter { $0.severity == .error }.compactMap(\.ruleID))
        #expect(errored == ["bad.home", "bad.root", "bad.relative", "bad.protected", "bad.empty", "bad.shell"])
    }

    @Test("The built-in library loads without errors")
    func builtinLibrary() throws {
        let library = RuleLibrary.load(builtin: .embedded, directories: [])
        #expect(library.rules.count > 10)
        let errors = library.issues.filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.description).joined(separator: "\n"))")
        let ids = library.rules.map(\.id)
        #expect(Set(ids).count == ids.count, "rule ids must be unique")
        // Ids referenced by the starter config.
        for id in ["xcode.derived-data", "node.node-modules", "node.npm-cache", "node.pnpm-store", "homebrew.cache"] {
            #expect(library.rule(id: id) != nil, "missing \(id)")
        }
    }
}

@Suite("Rule engine")
struct RuleEngineTests {
    @Test("Fixed paths with children granularity yield one item per entry")
    func childrenGranularity() throws {
        let tree = try TempTree()
        try tree.file("DerivedData/AppA-123/Build/a.o", bytes: 200_000)
        try tree.file("DerivedData/AppB-456/Build/b.o", bytes: 100_000)
        let rule = Rule(
            id: "dd", name: "DerivedData", paths: [tree.path("DerivedData")], granularity: .children,
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let result = try scan(tree.root)
        let findings = RuleEngine(rules: [rule]).evaluate(result)
        let finding = try #require(findings.first)
        #expect(finding.items.count == 2)
        #expect(finding.items.first?.name == "AppA-123")
        #expect(finding.size == result.node(at: tree.path("DerivedData"))!.size)
    }

    @Test("Pattern rules require their marker and stop at the first match")
    func patterns() throws {
        let tree = try TempTree()
        try tree.file("proj/package.json", bytes: 10)
        try tree.file("proj/node_modules/lib/node_modules/inner/x.js", bytes: 50_000)
        try tree.file("notes/node_modules/y.js", bytes: 50_000)  // no package.json: not a project
        try tree.file("Tool.app/Contents/node_modules/z.js", bytes: 50_000)
        let rule = Rule(
            id: "nm", name: "node_modules", match: PatternSpec(names: ["node_modules"], sibling: ["package.json"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let result = try scan(tree.root, markers: ["package.json"])
        let findings = RuleEngine(rules: [rule], devRoots: [tree.root]).evaluate(result)
        let items = findings.first?.items ?? []
        #expect(items.map(\.path) == [tree.path("proj/node_modules")])
        #expect(items.first?.project == tree.path("proj"))
    }

    @Test("Project activity drives last-used for pattern matches")
    func projectActivity() throws {
        let tree = try TempTree()
        let old = Date().addingTimeInterval(-200 * 86_400)
        try tree.file("proj/package.json", bytes: 10, modified: old)
        try tree.file("proj/src/index.js", bytes: 10, modified: old)
        try tree.file("proj/node_modules/x.js", bytes: 10)  // fresh dates inside node_modules don't count
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: tree.path("proj/src"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: tree.path("proj/node_modules"))
        let rule = Rule(
            id: "nm", name: "node_modules", match: PatternSpec(names: ["node_modules"], sibling: ["package.json"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let result = try scan(tree.root, markers: ["package.json"])
        let finding = try #require(RuleEngine(rules: [rule], devRoots: [tree.root]).evaluate(result).first)
        let idle = try #require(finding.items.first?.idleDays())
        #expect(idle >= 199)
        #expect(finding.eligibleItems(olderThan: .days(60)).count == 1)
        #expect(finding.eligibleItems(olderThan: .days(365)).isEmpty)
    }

    @Test("Overlapping rules never count a byte twice")
    func overlaps() throws {
        let tree = try TempTree()
        try tree.file("cache/huggingface/hub/model.bin", bytes: 500_000)
        try tree.file("cache/pip/wheel.whl", bytes: 100_000)
        try tree.file("cache/loose.txt", bytes: 20_000)
        let generic = Rule(
            id: "generic", name: "Caches", paths: [tree.path("cache")], safety: SafetySpec(level: .review), action: ActionSpec(remove: true)
        )
        let specific = Rule(id: "hf", name: "Hugging Face", paths: [tree.path("cache/huggingface")], safety: SafetySpec(level: .review))
        let result = try scan(tree.root)
        let findings = RuleEngine(rules: [generic, specific]).evaluate(result)
        let total = findings.reduce(0) { $0 + $1.size }
        #expect(total == result.node(at: tree.path("cache"))!.size)
        let genericPaths = findings.first { $0.rule.id == "generic" }!.items.map(\.path)
        #expect(!genericPaths.contains { $0.hasPrefix(tree.path("cache/huggingface")) })
        #expect(genericPaths.contains(tree.path("cache/pip")))
    }

    @Test("Exclusion globs are honoured")
    func exclusions() throws {
        let tree = try TempTree()
        try tree.file("dd/Keep-1/a", bytes: 1000)
        try tree.file("dd/Drop-2/b", bytes: 1000)
        let rule = Rule(
            id: "dd", name: "DD", paths: [tree.path("dd")], granularity: .children, exclusions: [tree.path("dd/Keep-*")],
            action: ActionSpec(remove: true))
        let result = try scan(tree.root)
        let items = RuleEngine(rules: [rule]).evaluate(result).first?.items.map(\.name) ?? []
        #expect(items == ["Drop-2"])
    }
}

@Suite("Incremental updates")
struct IncrementalUpdateTests {
    func analysis() throws -> (TempTree, Analysis) {
        let tree = try TempTree()
        try tree.file("dd/AppA/a.o", bytes: 200_000)
        try tree.file("dd/AppB/b.o", bytes: 100_000)
        try tree.file("cache/x/blob", bytes: 300_000)
        try tree.file("cache/x/other", bytes: 50_000)
        let dd = Rule(id: "dd", name: "DD", paths: [tree.path("dd")], granularity: .children, action: ActionSpec(remove: true))
        let cache = Rule(id: "cache", name: "Cache", paths: [tree.path("cache")], action: ActionSpec(remove: true))
        let scanned = try scan(tree.root)
        return (tree, Analysis(findings: RuleEngine(rules: [dd, cache]).evaluate(scanned), tree: scanned))
    }

    @Test("Removed items disappear and untouched findings stay as they were")
    func removesItems() throws {
        let (tree, before) = try analysis()
        var after = before
        let touched = after.apply([Removal(path: tree.path("dd/AppA"), kind: .directory, bytes: 200_000)])
        #expect(touched == ["dd"])
        #expect(after.finding(ruleID: "dd")?.items.map(\.name) == ["AppB"])
        #expect(after.finding(ruleID: "cache")?.size == before.finding(ruleID: "cache")?.size)
    }

    @Test("Items shrink when something inside them is removed; empty findings go away")
    func shrinksAndDrops() throws {
        let (tree, before) = try analysis()
        var after = before
        let blob = tree.allocated("cache/x/blob")
        after.apply([Removal(path: tree.path("cache/x/blob"), kind: .file, bytes: blob)])
        #expect(after.finding(ruleID: "cache")!.size == before.finding(ruleID: "cache")!.size - blob)
        after.apply([Removal(path: tree.path("dd"), kind: .directory, bytes: 1)])
        #expect(after.finding(ruleID: "dd") == nil)
    }

    @Test("Targeted re-evaluation replaces only the named rules")
    func replaces() throws {
        let (_, before) = try analysis()
        var after = before
        after.replaceFindings(for: ["cache"], with: [])
        #expect(after.finding(ruleID: "cache") == nil)
        #expect(after.finding(ruleID: "dd") != nil)
    }
}

@Suite("AI report merge")
struct AIReportMergeTests {
    @Test("Refreshing one rule keeps other tools' models")
    func merge() {
        func model(_ name: String, _ rule: String, _ size: UInt64) -> AIModel {
            AIModel(name: name, kind: .model, size: size, lastUsed: nil, paths: [], removeCommand: nil, ruleID: rule)
        }
        let current = AIReport(
            tools: [
                AITool(name: "Ollama", models: [model("llama3", "ollama", 5)]),
                AITool(name: "Hugging Face", models: [model("org/a", "hf", 9), model("org/b", "hf", 3)]),
            ],
            activeWindow: .days(90))
        let partial = AIReport(tools: [AITool(name: "Hugging Face", models: [model("org/a", "hf", 9)])], activeWindow: .days(90))
        let merged = current.replacingModels(from: ["hf"], with: partial)
        #expect(merged.total == 14)
        #expect(merged.tools.map(\.name) == ["Hugging Face", "Ollama"])
        #expect(merged.tools[0].models.map(\.name) == ["org/a"])
    }
}
