import Foundation
import Testing

@testable import SpaceKitCore

@Suite("AI model removal")
struct AIModelRemovalTests {
    func rule(_ tree: TempTree, builtin: Bool = true, removeCommand: [String]? = ["swift", "{name}"]) -> Rule {
        var rule = Rule(
            id: "ai.models", name: "Models", paths: [tree.path("models")], safety: SafetySpec(level: .review),
            ai: AISpec(tool: "Tool", layout: "ollama", removeCommand: removeCommand))
        rule.isBuiltin = builtin
        return rule
    }

    func model(name: String = "llama:8b", command: [String]? = ["swift", "llama:8b"], paths: [String] = []) -> AIModel {
        AIModel(name: name, kind: .model, size: 500, lastUsed: nil, paths: paths, removeCommand: command, ruleID: "ai.models")
    }

    func outcome(_ tree: TempTree, rule: Rule, plan: CleanupPlan, confirmed: Bool = true, root: Bool = false) -> CleanupOutcome? {
        manualRun(plan, with: sandboxExecutor(tree, rules: [rule], root: root), acceptingWarnings: confirmed, dryRun: true)
            .commands.first?.outcome
    }

    func isSkipped(_ outcome: CleanupOutcome?) -> Bool {
        if case .skipped = outcome { return true }
        return false
    }

    @Test("The rule's ai.removeCommand names each model; without one the shared blobs aren't offered")
    func inspectorUsesTemplate() throws {
        let tree = try TempTree()
        let manifest = tree.path("models/manifests/registry.ollama.ai/library/llama/8b")
        try FileManager.default.createDirectory(atPath: PathUtil.parent(manifest), withIntermediateDirectories: true)
        try Data(#"{"layers":[{"digest":"sha256:a","size":10}]}"#.utf8).write(to: URL(fileURLWithPath: manifest))
        try tree.file("models/blobs/sha256-a", bytes: 4_000)
        let item = FindingItem(path: tree.path("models"), kind: .directory, name: "models", size: 0)

        let withCommand = AIInspector.ollamaModels(finding: Finding(rule: rule(tree, removeCommand: ["ollama", "rm", "{name}"]), items: [item]))
        #expect(withCommand.first?.removeCommand == ["ollama", "rm", "llama:8b"])

        let without = try #require(AIInspector.ollamaModels(finding: Finding(rule: rule(tree, removeCommand: nil), items: [item])).first)
        #expect(without.removeCommand == nil)
        #expect(!without.isRemovable)
        #expect(CleanupPlan.removing(without, scanStarted: Date()) == nil)
    }

    @Test("A model with a command plans that command, which passes the executor's gates")
    func commandPlan() throws {
        let tree = try TempTree()
        let plan = try #require(CleanupPlan.removing(model(), scanStarted: Date()))
        #expect(plan.items.isEmpty)
        let command = try #require(plan.commands.first)
        #expect(command.arguments == ["swift", "llama:8b"])
        #expect(command.modelName == "llama:8b")
        #expect(command.estimatedBytes == 500)

        if case .wouldRemove = outcome(tree, rule: rule(tree), plan: plan) {} else { Issue.record("expected the command to run") }
        // Review rule: needs confirmation in a manual run.
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan, confirmed: false)))
        // Built-in trust only.
        #expect(isSkipped(outcome(tree, rule: rule(tree, builtin: false), plan: plan)))
        // Never as root.
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan, root: true)))
        // The rule no longer declares this command.
        #expect(isSkipped(outcome(tree, rule: rule(tree, removeCommand: ["swift", "rm", "{name}"]), plan: plan)))
        #expect(isSkipped(outcome(tree, rule: rule(tree, removeCommand: nil), plan: plan)))
    }

    @Test("Arguments that don't match the rule's template for the model are refused")
    func forgedArguments() throws {
        let tree = try TempTree()
        var plan = try #require(CleanupPlan.removing(model(), scanStarted: Date()))
        plan.commands[0].arguments = ["swift", "other:1b"]
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan)))
    }

    @Test("A model name that looks like an option is refused")
    func optionLikeName() throws {
        let tree = try TempTree()
        let plan = try #require(CleanupPlan.removing(model(name: "--version", command: ["swift", "--version"]), scanStarted: Date()))
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan)))
    }

    @Test("A model without a command plans its files and folders as they are on disk")
    func pathPlan() throws {
        let tree = try TempTree()
        let file = try tree.file("hub/a.bin", bytes: 8_000)
        try tree.directory("hub/b")
        let named = model(name: "org/model", command: nil, paths: [tree.path("hub/b")])
        let single = try #require(CleanupPlan.removing(named, scanStarted: Date()))
        #expect(single.items.map(\.kind) == [.directory])
        #expect(single.items.first?.name == "org/model")
        #expect(single.items.first?.size == 500)
        #expect(single.useTrash)

        let several = try #require(CleanupPlan.removing(model(command: nil, paths: [file, tree.path("hub/b")]), scanStarted: Date()))
        #expect(several.items.map(\.kind) == [.file, .directory])
        #expect(several.items.map(\.name) == ["a.bin", "b"])
        #expect(several.items.first?.size == tree.allocated("hub/a.bin"))
        #expect(CleanupPlan.removing(model(command: nil, paths: []), scanStarted: Date()) == nil)
    }

    @Test("ai.removeCommand is validated like other commands and can't use {path}")
    func validation() {
        func issues(_ command: [String]) -> [RuleIssue] {
            var rule = Rule(id: "x", name: "x", paths: ["~/.tool/models"], ai: AISpec(tool: "T", layout: "ollama", removeCommand: command))
            rule.isBuiltin = true
            return RuleLibrary.issues(for: rule).filter { $0.severity == .error }
        }
        #expect(issues(["ollama", "rm", "{name}"]).isEmpty)
        #expect(!issues(["/usr/bin/ollama", "rm", "{name}"]).isEmpty)
        #expect(!issues(["ollama", "rm", "{path}"]).isEmpty)
    }

    func aiRule(_ id: String, _ path: String, layout: String, granularity: Granularity = .whole) -> Rule {
        Rule(
            id: id, name: id, paths: [path], granularity: granularity, safety: SafetySpec(level: .safe, trash: false),
            action: ActionSpec(remove: true), ai: AISpec(tool: "Tool", layout: layout))
    }

    @Test("A cache spread over a folder's entries removes those entries, never the folder another rule shares")
    func cacheLayoutKeepsSharedFolder() throws {
        let tree = try TempTree()
        try tree.file("home/tool/loose.log", bytes: 20_000)
        try tree.file("home/tool/sessions/s.json", bytes: 30_000)
        try tree.file("home/tool/models/m.bin", bytes: 40_000)
        let cache = aiRule("tool.cache", tree.path("home/tool"), layout: "cache", granularity: .children)
        let models = Rule(
            id: "tool.models", name: "Models", paths: [tree.path("home/tool/models")], safety: SafetySpec(level: .review),
            action: ActionSpec(remove: true))
        let scanned = try scan(tree.root)
        let findings = RuleEngine(rules: [cache, models]).evaluate(scanned)
        let model = try #require(AIInspector.report(findings: findings, tree: scanned).tools.first?.models.first)
        let plan = try #require(CleanupPlan.removing(model, useTrash: false, scanStarted: scanned.scanStarted))
        #expect(plan.items.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.directory, .looseFiles])
        #expect(plan.items.allSatisfy { $0.size > 0 })

        let report = manualRun(plan, with: sandboxExecutor(tree, rules: [cache, models]))
        #expect(report.removedAnything)
        #expect(onDisk(tree.path("home/tool/models/m.bin")))
        #expect(!onDisk(tree.path("home/tool/loose.log")))
        #expect(!onDisk(tree.path("home/tool/sessions")))
    }

    @Test("The rest of a Hugging Face cache is removed without the models listed beside it")
    func huggingFaceRemainderKeepsModels() throws {
        let tree = try TempTree()
        try tree.file("home/hf/hub/models--org--name/blob.bin", bytes: 40_000)
        try tree.file("home/hf/hub/.locks/l", bytes: 8_000)
        try tree.file("home/hf/token.cache", bytes: 8_000)
        let rule = aiRule("hf", tree.path("home/hf"), layout: "huggingface")
        let scanned = try scan(tree.root)
        let findings = RuleEngine(rules: [rule]).evaluate(scanned)
        let models = AIInspector.report(findings: findings, tree: scanned).tools.first?.models ?? []
        let remainder = try #require(models.first { $0.kind == .cache })
        let plan = try #require(CleanupPlan.removing(remainder, useTrash: false, scanStarted: scanned.scanStarted))
        #expect(plan.totalBytes == remainder.size)

        _ = manualRun(plan, with: sandboxExecutor(tree, rules: [rule]))
        #expect(onDisk(tree.path("home/hf/hub/models--org--name/blob.bin")))
        #expect(!onDisk(tree.path("home/hf/hub/.locks")))
        #expect(!onDisk(tree.path("home/hf/token.cache")))
    }
}
