import Foundation
import Testing

@testable import SpaceKitCore

/// The library checks an override where the engine looks for it when the rules load, but the engine resolves symlinks
/// again for every analysis, and a folder on the way can change in between.
extension RuleLoadingTests {
    @Test("The engine checks an override's paths again where it looks: a symlink retargeted after loading drops the path, with an issue")
    func overridePathRecheckedAtAnalysis() throws {
        let tree = try TempTree()
        try tree.file("caches/app/data/blob", bytes: 4_096)
        try tree.file("documents/data/thesis", bytes: 4_096)
        let link = tree.path("caches/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("caches/app"))
        try tree.directory("user")
        func yaml(_ path: String) -> String { "id: base.paths\nname: Paths\npath: [\"\(path)\"]\nsafety: safe\naction: remove\n" }
        try yaml(tree.path("caches/link/data")).write(toFile: tree.path("user/paths.yaml"), atomically: true, encoding: .utf8)
        let builtin = BuiltinRules(files: [RuleFileText(source: "built-in rules/paths.yaml", yaml: yaml(tree.path("caches/*/data")))])
        let library = RuleLibrary.load(builtin: builtin, directories: [tree.path("user")])
        #expect(errors(library, "base.paths").isEmpty && library.overrides.map(\.id) == ["base.paths"])

        // As loaded, the link leads into the built-in path, and the engine finds the cache there.
        let before = RuleEngine(rules: library.rules)
        #expect(before.issues.isEmpty)
        #expect(try before.evaluate(scan(tree.root)).flatMap(\.items).map(\.path) == [tree.path("caches/app/data")])

        // Before the next analysis, the link is pointed out of the built-in path.
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("documents"))
        let after = RuleEngine(rules: library.rules)
        #expect(after.rules.first { $0.id == "base.paths" }?.paths.isEmpty == true)
        let issue = after.issues.first { $0.ruleID == "base.paths" }
        #expect(issue?.severity == .error && issue?.message.contains("'\(tree.path("caches/link/data"))'") == true, "\(after.issues)")
        let scanned = try scan(tree.root)
        #expect(after.evaluate(scanned).isEmpty)

        // An analysis carries the engine's issues, and leaves the documents alone.
        let analysis = try StorageAnalyzer(library: library).analyzeSync(reusing: scanned)
        #expect(analysis.findings.isEmpty)
        #expect(analysis.ruleIssues.map(\.message) == after.issues.map(\.message))
    }

    /// The guard (`spacekit clean <path>`) and the rule index ask whether a rule covers a path through `RuleScope`, which
    /// must check the override again the same way the engine does.
    @Test("The guard checks an override's paths again: through a retargeted symlink, the override doesn't vouch for the item")
    func overridePathRecheckedByGuard() throws {
        let tree = try TempTree()
        try tree.file("caches/app/data/blob", bytes: 4_096)
        try tree.file("documents/data/thesis", bytes: 4_096)
        let link = tree.path("caches/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("caches/app"))
        try tree.directory("user")
        func yaml(_ path: String) -> String { "id: base.paths\nname: Paths\npath: [\"\(path)\"]\nsafety: safe\naction: remove\n" }
        try yaml(tree.path("caches/link/data")).write(toFile: tree.path("user/paths.yaml"), atomically: true, encoding: .utf8)
        let builtin = BuiltinRules(files: [RuleFileText(source: "built-in rules/paths.yaml", yaml: yaml(tree.path("caches/*/data")))])
        let library = RuleLibrary.load(builtin: builtin, directories: [tree.path("user")])
        let override = try #require(library.rule(id: "base.paths"))
        let guardian = testGuard(home: tree.path("home"))
        let unknown = "No SpaceKit rule recognises this"
        let item = tree.path("caches/link/data")
        #expect(!guardian.check(item, rule: override, context: .manual).reasons.contains { $0.contains(unknown) })

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("documents"))
        let verdict = guardian.check(item, rule: override, context: .manual)
        #expect(verdict.reasons.contains { $0.contains(unknown) }, "\(verdict.reasons)")
        let automatic = guardian.check(item, rule: override, context: .automatic(AutomationContext(jobID: "j")))
        #expect(automatic.reasons.contains { $0.contains("outside the locations rule base.paths covers") }, "\(automatic.reasons)")
    }
}
