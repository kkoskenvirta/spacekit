import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Rule loading")
struct RuleLoadingTests {
    /// A built-in rule directory and a user rule directory in a temporary tree.
    struct Folders {
        let tree: TempTree
        var builtin: String { tree.path("builtin") }
        var user: String { tree.path("user") }

        init() throws {
            tree = try TempTree()
            try tree.directory("builtin")
            try tree.directory("user")
            try write(
                "builtin/base.yaml",
                """
                group: Base
                category: developer.cache
                rules:
                  - id: base.keys
                    name: Keys
                    path: ~/.base-keys
                    safety: protected
                  - id: base.models
                    name: Models
                    path: ~/.base/models
                    safety: review
                    action: remove
                  - id: base.cache
                    name: Cache
                    path: ~/.base/cache
                    safety: safe
                    action:
                      command: [brew, cleanup]
                """)
        }

        func write(_ relative: String, _ text: String) throws {
            try text.write(toFile: tree.path(relative), atomically: true, encoding: .utf8)
        }

        func load(disabled: Set<String> = []) -> RuleLibrary {
            RuleLibrary.load(builtinDirectory: builtin, directories: [user], disabled: disabled)
        }
    }

    func errors(_ library: RuleLibrary, _ id: String) -> [RuleIssue] {
        library.issues.filter { $0.severity == .error && $0.ruleID == id }
    }

    @Test("Rules from the built-in directory are marked built-in; user rules are not")
    func builtinFlag() throws {
        let folders = try Folders()
        try folders.write("user/mine.yaml", "id: mine.cache\nname: Mine\npath: ~/.mine/cache\nsafety: safe\naction: remove\n")
        let library = folders.load()
        #expect(library.rule(id: "base.cache")?.isBuiltin == true)
        #expect(library.rule(id: "mine.cache")?.isBuiltin == false)
        let decoded = try #require(try RuleLibrary.parse(yaml: "name: x\npath: ~/.x/y\nisBuiltin: true\n").first)
        #expect(!decoded.isBuiltin)
    }

    @Test("A user rule can't replace a built-in protected rule")
    func protectedOverride() throws {
        let folders = try Folders()
        try folders.write("user/evil.yaml", "id: base.keys\nname: Keys\npath: ~/.base-keys\nsafety: safe\naction: remove\n")
        let library = folders.load()
        let rule = try #require(library.rule(id: "base.keys"))
        #expect(rule.safety.level == .protected)
        #expect(rule.isBuiltin)
        #expect(!errors(library, "base.keys").isEmpty)
    }

    @Test("A user rule can't lower a built-in rule's safety level, but may raise it")
    func loweredSafety() throws {
        let folders = try Folders()
        try folders.write("user/a.yaml", "id: base.models\nname: Models\npath: ~/.base/models\nsafety: safe\naction: remove\n")
        try folders.write("user/b.yaml", "id: base.cache\nname: Cache\npath: ~/.base/cache\nsafety: review\naction: remove\n")
        let library = folders.load()
        #expect(library.rule(id: "base.models")?.safety.level == .review)
        #expect(library.rule(id: "base.models")?.isBuiltin == true)
        #expect(!errors(library, "base.models").isEmpty)
        #expect(library.rule(id: "base.cache")?.safety.level == .review)
        #expect(library.rule(id: "base.cache")?.isBuiltin == false)
        #expect(errors(library, "base.cache").isEmpty)
    }

    @Test("A second user override can't lower the level below the built-in either")
    func chainedOverride() throws {
        let folders = try Folders()
        try folders.write("user/a.yaml", "id: base.models\nname: Models\npath: ~/.base/models\nsafety: protected\n")
        try folders.write("user/b.yaml", "id: base.models\nname: Models\npath: ~/.base/models\nsafety: safe\naction: remove\n")
        let library = folders.load()
        #expect(library.rule(id: "base.models")?.safety.level == .protected)
    }

    @Test("rules.disabled never disables a protected rule")
    func disablingProtected() throws {
        let folders = try Folders()
        let library = folders.load(disabled: ["base.keys", "base.models"])
        #expect(library.rule(id: "base.keys") != nil)
        #expect(library.rule(id: "base.models") == nil)
        #expect(library.issues.contains { $0.severity == .warning && $0.ruleID == "base.keys" })
    }

    @Test("Rules with errors are reported but not loaded")
    func invalidRulesNotLoaded() throws {
        let folders = try Folders()
        try folders.write(
            "user/bad.yaml",
            """
            rules:
              - id: bad.home
                name: Home
                path: "~"
                safety: safe
                action: remove
              - id: bad.everything
                name: Everything
                path: ~/*
                safety: safe
                action: remove
              - id: bad.prefix
                name: Prefix
                path: ~/Do*
                safety: safe
                action: remove
              - id: bad.manual
                name: Manual
                path: ~/.keys
                safety: protected
                action:
                  manual: Delete it by hand
              - id: good.cache
                name: Good
                path: ~/.good/cache
                safety: safe
                action: remove
            """)
        let library = folders.load()
        for id in ["bad.home", "bad.everything", "bad.prefix", "bad.manual"] {
            #expect(library.rule(id: id) == nil, "\(id) must not load")
            #expect(!errors(library, id).isEmpty, "\(id) must be reported")
        }
        #expect(library.rule(id: "good.cache") != nil)
    }

    @Test("Command executables must be bare names; user rules need allowedCommands")
    func commandValidation() {
        func issues(_ command: [String], builtin: Bool = false) -> [RuleIssue] {
            var rule = Rule(id: "c", name: "C", paths: ["~/.c/cache"], safety: SafetySpec(level: .safe), action: ActionSpec(command: command))
            rule.isBuiltin = builtin
            return RuleLibrary(rules: [rule]).validate()
        }
        for command in [["/bin/rm", "-rf", "/"], ["../bin/brew"], ["..", "x"], ["bin/brew"], ["{name}"], [""]] {
            #expect(issues(command).contains { $0.severity == .error }, "\(command)")
        }
        #expect(issues(["brew", "cleanup"], builtin: true).isEmpty)
        let user = issues(["brew", "cleanup"])
        #expect(user.count == 1)
        #expect(user.first?.severity == .warning && user.first?.message.contains("safety.allowedCommands") == true)
        #expect(Shell.isBareName("brew"))
        #expect(!Shell.isBareName("/opt/homebrew/bin/brew"))
    }

    @Test("Unknown AI layouts are flagged")
    func aiLayout() {
        let rule = Rule(id: "ai", name: "AI", paths: ["~/.ai/models"], ai: AISpec(tool: "AI", layout: "olama"))
        #expect(RuleLibrary(rules: [rule]).validate().contains { $0.message.contains("olama") })
    }

    @Test("Undocumented safety aliases and action words are rejected")
    func strictWords() {
        #expect(throws: (any Error).self) { try RuleLibrary.parse(yaml: "name: x\npath: ~/.x/y\nsafety: green\n") }
        #expect(throws: (any Error).self) { try RuleLibrary.parse(yaml: "name: x\npath: ~/.x/y\naction: trash\n") }
        #expect(SafetyLevel(alias: "regenerable") == .safe)
    }
}

@Suite("Built-in rule directory")
struct BuiltinDirectoryTests {
    @Test("Debug builds also look for rules in the source checkout they were built from")
    func sourceCheckoutInDebug() {
        #expect(RuleLibrary.builtinCandidates().contains(PathUtil.standardize(RuleLibrary.sourceCheckoutRules)))
    }
}

@Suite("Rule scaffold and rule folders")
struct RuleScaffoldTests {
    @Test("The scaffold is a valid custom rule that parses back from its YAML")
    func scaffold() throws {
        let rule = RuleScaffold.rule(name: "My tool's cache", paths: ["~/Library/Caches/com.example.tool"])
        #expect(rule.id == "custom." + Rule.slug("My tool's cache"))
        #expect(rule.category == "personal.custom" && rule.safety.level == .review && rule.action.remove)
        #expect(!RuleLibrary.issues(for: rule).contains { $0.severity == .error })
        let yaml = try RuleScaffold.yaml(rule, note: "save, then Reload")
        #expect(yaml.hasPrefix("# Schema: docs/RULES.md · save, then Reload\n"))
        #expect(try RuleLibrary.parse(yaml: yaml, source: "x.yaml").map(\.id) == [rule.id])

        let pattern = RuleScaffold.rule(name: "Build", match: "build", sibling: "Makefile", safety: .protected)
        #expect(pattern.match?.names == ["build"] && pattern.match?.sibling == ["Makefile"])
        #expect(pattern.action.isEmpty)
    }

    @Test("User rules load from the configured folders plus the standard one, once")
    func ruleDirectories() {
        let paths = SpaceKitPaths(configFile: "/tmp/sk/config.yaml", stateDirectory: "/tmp/sk/state")
        var config = SpaceKitConfig()
        config.rules.directories = ["/tmp/sk/extra"]
        let context = SpaceKitContext(paths: paths, config: config, library: RuleLibrary(rules: []))
        #expect(context.ruleDirectories == ["/tmp/sk/extra", paths.userRulesDirectory])
        config.rules.directories = [paths.userRulesDirectory]
        #expect(SpaceKitContext(paths: paths, config: config, library: RuleLibrary(rules: [])).ruleDirectories == [paths.userRulesDirectory])
    }
}

