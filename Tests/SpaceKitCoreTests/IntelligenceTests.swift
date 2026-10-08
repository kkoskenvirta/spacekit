import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Overlap resolution")
struct OverlapTests {
    @Test("An inner children rule keeps its loose files; the outer rule doesn't count them again")
    func innerLooseFiles() throws {
        let tree = try TempTree()
        try tree.file("Caches/JetBrains/loose.log", bytes: 40_000)
        try tree.file("Caches/JetBrains/IDEA/index.bin", bytes: 300_000)
        try tree.file("Caches/pip/wheel.bin", bytes: 200_000)
        try tree.file("Caches/top.db", bytes: 10_000)
        let outer = Rule(id: "user-caches", name: "Caches", paths: [tree.path("Caches")], granularity: .children)
        let inner = Rule(id: "jetbrains", name: "JetBrains", paths: [tree.path("Caches/JetBrains")], granularity: .children)
        let result = try scan(tree.root)

        let findings = RuleEngine(rules: [outer, inner]).evaluate(result)
        let total = findings.reduce(UInt64(0)) { $0 + $1.size }
        #expect(total == result.node(at: tree.path("Caches"))!.size)
        let outerItems = findings.first { $0.rule.id == "user-caches" }?.items.map(\.id) ?? []
        #expect(!outerItems.contains(tree.path("Caches/JetBrains") + "/*"))
        #expect(outerItems.contains(tree.path("Caches") + "/*"))
        let innerItems = findings.first { $0.rule.id == "jetbrains" }?.items.map(\.id) ?? []
        #expect(innerItems.contains(tree.path("Caches/JetBrains") + "/*"))
    }

    @Test("A single-file rule inside another rule's folder isn't counted twice")
    func innerFile() throws {
        let tree = try TempTree()
        try tree.file("Logs/app/big.log", bytes: 300_000)
        try tree.file("Logs/app/small.log", bytes: 20_000)
        try tree.file("Logs/other/x.log", bytes: 50_000)
        let outer = Rule(id: "logs", name: "Logs", paths: [tree.path("Logs")])
        let inner = Rule(id: "big", name: "Big log", paths: [tree.path("Logs/app/big.log")])
        let result = try scan(tree.root)

        let findings = RuleEngine(rules: [outer, inner]).evaluate(result)
        let total = findings.reduce(UInt64(0)) { $0 + $1.size }
        #expect(total == result.node(at: tree.path("Logs"))!.size)
        let outerFinding = try #require(findings.first { $0.rule.id == "logs" })
        #expect(outerFinding.items.first { $0.kind == .looseFiles }?.size == tree.allocated("Logs/app/small.log"))
    }
}

@Suite("Rule index scope")
struct RuleIndexScopeTests {
    @Test("A pattern match outside the rule's roots or inside an excluded tool home isn't recognised")
    func patternScope() throws {
        let tree = try TempTree()
        try tree.file("home/Code/app/package.json", bytes: 10)
        try tree.directory("home/Code/app/node_modules")
        try tree.file("home/.vscode/extensions/ext/package.json", bytes: 10)
        try tree.directory("home/.vscode/extensions/ext/node_modules")
        try tree.file("other/app/package.json", bytes: 10)
        try tree.directory("other/app/node_modules")
        let rule = Rule(
            id: "node.modules", name: "node_modules", match: PatternSpec(names: ["node_modules"], sibling: ["package.json"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let index = RuleIndex(rules: [rule], home: tree.path("home"))
        #expect(index.rule(for: tree.path("home/Code/app/node_modules"))?.id == "node.modules")
        #expect(index.rule(for: tree.path("home/.vscode/extensions/ext/node_modules")) == nil)
        #expect(index.rule(for: tree.path("other/app/node_modules")) == nil)
        let rooted = RuleIndex(rules: [rule], home: tree.path("home"), patternRoots: [tree.path("other")])
        #expect(rooted.rule(for: tree.path("other/app/node_modules"))?.id == "node.modules")
    }
}

@Suite("Loose files name what they counted")
struct LooseFileNameTests {
    @Test("A children rule's loose files leave out a single file another rule claims")
    func childrenRuleLeavesClaimedFile() throws {
        let tree = try TempTree()
        try tree.file("Logs/big.log", bytes: 300_000)
        try tree.file("Logs/small.log", bytes: 20_000)
        try tree.file("Logs/app/x.log", bytes: 50_000)
        let outer = Rule(id: "logs", name: "Logs", paths: [tree.path("Logs")], granularity: .children)
        let inner = Rule(id: "big", name: "Big log", paths: [tree.path("Logs/big.log")])
        let result = try scan(tree.root)

        let findings = RuleEngine(rules: [outer, inner]).evaluate(result)
        let total = findings.reduce(UInt64(0)) { $0 + $1.size }
        #expect(total == result.node(at: tree.path("Logs"))!.size)
        let loose = try #require(findings.first { $0.rule.id == "logs" }?.items.first { $0.kind == .looseFiles })
        #expect(loose.size == tree.allocated("Logs/small.log"))
        #expect(loose.looseFileNames == ["small.log"])
    }

    @Test("Removing an outer rule's loose files leaves a file an inner rule claims")
    func removalLeavesClaimedFile() throws {
        let tree = try TempTree()
        try tree.file("home/cache/big.log", bytes: 300_000)
        try tree.file("home/cache/small.tmp", bytes: 20_000)
        try tree.file("home/cache/sub/x.bin", bytes: 50_000)
        let outer = Rule(
            id: "cache", name: "Cache", paths: [tree.path("home/cache")], safety: SafetySpec(level: .safe, trash: false),
            action: ActionSpec(remove: true))
        let inner = Rule(
            id: "logs", name: "Logs", paths: [tree.path("home/cache/big.log")], safety: SafetySpec(level: .review),
            action: ActionSpec(remove: true))
        let result = try scan(tree.root)
        let findings = RuleEngine(rules: [outer, inner]).evaluate(result).filter { $0.rule.id == "cache" }
        let plan = CleanupPlan.make(findings: findings, trashPreference: false, created: Date())
        #expect(plan.items.first { $0.kind == .looseFiles }?.looseFileNames == ["small.tmp"])

        let report = sandboxExecutor(tree, rules: [outer, inner]).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.removedAnything)
        #expect(onDisk(tree.path("home/cache/big.log")))
        #expect(!onDisk(tree.path("home/cache/small.tmp")))
    }

    @Test("A saved loose-files item without names can't remove anything")
    func itemWithoutNames() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a.tmp", bytes: 1_000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let plan = CleanupPlan(
            items: [CleanupItem(path: tree.path("home/cache"), kind: .looseFiles, size: 1_000, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule]).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.skipped.first?.reason.contains("refresh") == true)
        #expect(onDisk(tree.path("home/cache/a.tmp")))
    }

    @Test("Emptying the Trash names the loose files it saw")
    func trashNamesFiles() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/a.tmp", bytes: 1_000)
        try tree.file("home/.Trash/dir/b", bytes: 1_000)
        let plan = Trash.emptyingPlan(try scan(tree.path("home/.Trash")), rules: [], created: Date(), home: tree.path("home"))
        #expect(plan.items.first { $0.kind == .looseFiles }?.looseFileNames == ["a.tmp"])
    }
}

@Suite("Incremental updates with loose files")
struct LooseFilesUpdateTests {
    func analysis() throws -> (TempTree, Analysis) {
        let tree = try TempTree()
        try tree.file("cache/a/blob", bytes: 300_000)
        try tree.file("cache/b/blob", bytes: 100_000)
        try tree.file("cache/top.bin", bytes: 40_000)
        try tree.file("cache/second.bin", bytes: 20_000)
        let rule = Rule(id: "cache", name: "Cache", paths: [tree.path("cache")], granularity: .children, action: ActionSpec(remove: true))
        let scanned = try scan(tree.root)
        return (tree, Analysis(findings: RuleEngine(rules: [rule]).evaluate(scanned), tree: scanned))
    }

    func looseSize(_ analysis: Analysis) -> UInt64? {
        analysis.finding(ruleID: "cache")?.items.first { $0.kind == .looseFiles }?.size
    }

    @Test("Removing a sibling folder leaves the folder's loose-files item alone")
    func siblingFolder() throws {
        let (tree, before) = try analysis()
        var after = before
        after.apply([Removal(path: tree.path("cache/a"), kind: .directory, bytes: tree.allocated("cache/a/blob"))])
        #expect(looseSize(after) == looseSize(before))
        #expect(after.finding(ruleID: "cache")?.items.contains { $0.path == tree.path("cache/a") } == false)
    }

    @Test("Removing a file directly in the folder shrinks the loose-files item")
    func directFile() throws {
        let (tree, before) = try analysis()
        var after = before
        let top = tree.allocated("cache/top.bin")
        after.apply([Removal(path: tree.path("cache/top.bin"), kind: .file, bytes: top)])
        #expect(looseSize(after) == looseSize(before)! - top)
    }

    @Test("Removing a file deeper down doesn't touch the loose-files item")
    func deeperFile() throws {
        let (tree, before) = try analysis()
        var after = before
        after.apply([Removal(path: tree.path("cache/b/blob"), kind: .file, bytes: tree.allocated("cache/b/blob"))])
        #expect(looseSize(after) == looseSize(before))
    }
}

@Suite("Ollama models")
struct OllamaTests {
    /// An Ollama `models` folder: two tags of one model sharing a weights blob, each with its own config blob.
    func models(brokenManifest: Bool) throws -> (TempTree, Finding) {
        let tree = try TempTree()
        func manifest(_ relative: String, layers: [(String, Int)]) throws {
            let list = layers.map { #"{"digest":"sha256:\#($0.0)","size":\#($0.1)}"# }.joined(separator: ",")
            let path = tree.path("models/manifests/registry.ollama.ai/library/" + relative)
            try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
            try Data(#"{"layers":[\#(list)]}"#.utf8).write(to: URL(fileURLWithPath: path))
        }
        try manifest("llama/8b", layers: [("shared", 1000), ("eight", 500)])
        try manifest("llama/latest", layers: [("shared", 1000), ("latest", 300)])
        for blob in ["shared", "eight", "latest", "stray"] { try tree.file("models/blobs/sha256-\(blob)", bytes: 4_000) }
        if brokenManifest {
            let path = tree.path("models/manifests/registry.ollama.ai/library/other/v1")
            try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))
        }
        let rule = Rule(id: "ollama", name: "Ollama models", paths: [tree.path("models")], ai: AISpec(tool: "Ollama", layout: "ollama"))
        let item = FindingItem(path: tree.path("models"), kind: .directory, name: "models", size: 0)
        return (tree, Finding(rule: rule, items: [item]))
    }

    @Test("Blobs shared by several tags are counted once")
    func sharedBlobs() throws {
        let (tree, finding) = try models(brokenManifest: false)
        let models = withExtendedLifetime(tree) { AIInspector.ollamaModels(finding: finding) }
        let size = { (name: String) in models.first { $0.name == name }?.size }
        #expect(size("llama:8b") == 500)
        #expect(size("llama:latest") == 300)
        let shared = try #require(models.first { $0.name.hasPrefix("Shared") })
        #expect(shared.size == 1000)
        #expect(shared.removeCommand == nil && shared.paths.isEmpty)
        #expect(models.filter { $0.kind != .orphaned }.reduce(UInt64(0)) { $0 + $1.size } == 1800)
        #expect(models.first { $0.kind == .orphaned }?.paths.map(PathUtil.lastComponent) == ["sha256-stray"])
    }

    @Test("No blob is called unreferenced when a manifest can't be read")
    func brokenManifest() throws {
        let (tree, finding) = try models(brokenManifest: true)
        let models = withExtendedLifetime(tree) { AIInspector.ollamaModels(finding: finding) }
        #expect(!models.contains { $0.kind == .orphaned })
        #expect(models.contains { $0.name == "llama:8b" })
    }
}

@Suite("Storage categories")
struct StorageCategoryTests {
    @Test(
        "Every documented top-level rule category maps to a breakdown category",
        arguments: [
            ("developer.build", StorageCategory.developer), ("ai.models", .ai), ("cache.browser", .caches),
            ("system.logs", .systemData), ("system.trash", .trash), ("system.installers", .applications),
            ("personal.downloads", .downloads), ("personal.photos", .media), ("personal.backups", .media),
            ("personal.mail", .mail), ("personal.messages", .mail), ("personal.code", .developer),
        ])
    func mapping(ruleCategory: String, expected: StorageCategory) {
        #expect(StorageCategory(ruleCategory: ruleCategory) == expected)
    }

    @Test("Categories that say nothing about the data leave it to the location", arguments: ["personal.credentials", "other", "custom", ""])
    func unmapped(ruleCategory: String) {
        #expect(StorageCategory(ruleCategory: ruleCategory) == nil)
    }

    @Test("The full breakdown and the per-path lookup agree")
    func consistent() throws {
        let tree = try TempTree()
        try tree.file("Documents/report.pdf", bytes: 100_000)
        try tree.file("Documents/app-logs/run.log", bytes: 200_000)
        try tree.file("Documents/Photos Backup/img.heic", bytes: 300_000)
        let logs = Rule(id: "logs", name: "Logs", category: "system.logs", paths: [tree.path("Documents/app-logs")])
        let photos = Rule(id: "photos", name: "Photos", category: "personal.photos", paths: [tree.path("Documents/Photos Backup")])
        let scanned = try scan(tree.root)
        let findings = RuleEngine(rules: [logs, photos]).evaluate(scanned)

        let slices = CategoryBreakdown.compute(tree: scanned, findings: findings, home: tree.root)
        let size = { (category: StorageCategory) in slices.first { $0.category == category }?.size }
        #expect(size(.systemData) == tree.allocated("Documents/app-logs/run.log"))
        #expect(size(.media) == tree.allocated("Documents/Photos Backup/img.heic"))
        #expect(size(.documents) == tree.allocated("Documents/report.pdf"))
        let locations = CategoryBreakdown.locations(home: tree.root, findings: findings)
        let lookup = { (relative: String) in CategoryBreakdown.nearestCategory(for: tree.path(relative), in: locations) ?? .other }
        #expect(lookup("Documents/app-logs/run.log") == .systemData)
        #expect(lookup("Documents/Photos Backup/img.heic") == .media)
        #expect(lookup("Documents/report.pdf") == .documents)
    }
}

@Suite("Rule index")
struct RuleIndexTests {
    @Test("Pattern rules are recognised only with their marker on disk")
    func patternMarkers() throws {
        let tree = try TempTree()
        try tree.file("app/package.json", bytes: 10)
        try tree.directory("app/node_modules")
        try tree.directory("loose/node_modules")
        let rule = Rule(id: "nm", name: "node_modules", match: PatternSpec(names: ["node_modules"], sibling: ["package.json"]))
        let index = RuleIndex(rules: [rule], home: tree.root)
        #expect(index.rule(for: tree.path("app/node_modules"))?.id == "nm")
        #expect(index.rule(for: tree.path("loose/node_modules")) == nil)
    }
}

@Suite("Storage analyzer")
struct StorageAnalyzerTests {
    @Test("Both entry points reuse a tree that covers what the rules need, and scan otherwise")
    func reuse() async throws {
        let tree = try TempTree()
        try tree.file("cache/a/blob", bytes: 100_000)
        try tree.file("elsewhere/b", bytes: 10_000)
        let rule = Rule(id: "cache", name: "Cache", paths: [tree.path("cache")], granularity: .children)
        let analyzer = StorageAnalyzer(library: RuleLibrary(rules: [rule]))
        let covering = try scan(tree.root)
        let outside = try scan(tree.path("elsewhere"))

        let sync = try analyzer.analyzeSync(reusing: covering)
        let async = try await analyzer.analyze(reusing: covering)
        #expect(sync.tree === covering && async.tree === covering)
        #expect(sync.findings.map(\.size) == async.findings.map(\.size))
        #expect(sync.finding(ruleID: "cache")?.items.count == 1)

        let rescanned = try analyzer.analyzeSync(reusing: outside)
        #expect(rescanned.tree !== outside)
        #expect(rescanned.tree.roots == [tree.path("cache")])
    }
}
