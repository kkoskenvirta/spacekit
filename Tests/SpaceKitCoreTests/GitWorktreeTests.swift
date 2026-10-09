import Foundation
import Testing

@testable import SpaceKitCore

/// Repositories and linked worktrees laid out the way `git worktree add` leaves them, without running git.
private struct Repositories {
    let tree: TempTree
    static let old = Date().addingTimeInterval(-90 * 86_400)

    /// A repository at `repo` with a `.git` folder.
    func repository(_ repo: String) throws {
        try write("\(repo)/.git/HEAD", "ref: refs/heads/main\n")
        try write("\(repo)/README.md", "readme\n")
    }

    /// A linked worktree of `repo` at `worktree`: its `.git` file names `<repo>/.git/worktrees/<name>`, which points back.
    func worktree(_ worktree: String, of repo: String, name: String? = nil, relative: Bool = false) throws {
        let name = name ?? PathUtil.lastComponent(worktree)
        let metadata = tree.path("\(repo)/.git/worktrees/\(name)")
        try write("\(repo)/.git/worktrees/\(name)/HEAD", "ref: refs/heads/\(name)\n")
        try write("\(repo)/.git/worktrees/\(name)/index", "index\n")
        try write("\(repo)/.git/worktrees/\(name)/gitdir", tree.path("\(worktree)/.git") + "\n")
        let gitdir = relative ? relativePath(from: tree.path(worktree), to: metadata) : metadata
        try write("\(worktree)/.git", "gitdir: \(gitdir)\n")
        try write("\(worktree)/src/main.swift", "print(1)\n")
    }

    func write(_ relative: String, _ text: String) throws {
        let full = tree.path(relative)
        try FileManager.default.createDirectory(atPath: PathUtil.parent(full), withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: false, encoding: .utf8)
    }

    /// Sets the modification date of `relative` and everything inside it, deepest first.
    func age(_ relative: String, to date: Date = Repositories.old) throws {
        let root = tree.path(relative)
        let inside = FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? []
        for path in inside.map({ root + "/" + $0 }).sorted(by: { $0.count > $1.count }) + [root] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    private func relativePath(from folder: String, to target: String) -> String {
        let base = PathUtil.components(folder)
        let goal = PathUtil.components(target)
        let shared = zip(base, goal).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: base.count - shared) + goal.dropFirst(shared)).joined(separator: "/")
    }
}

private let worktreeRule = Rule(
    id: "git.unused-worktrees", name: "Unused git worktrees", category: "developer.worktrees",
    match: PatternSpec(names: [], worktrees: WorktreeSpec(idleFor: .days(30))),
    safety: SafetySpec(level: .review), action: ActionSpec(remove: true))

private let nodeModulesRule = Rule(
    id: "nm", name: "node_modules", match: PatternSpec(names: ["node_modules"], sibling: ["package.json"]),
    safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))

@Suite("Git worktrees")
struct GitWorktreeTests {
    @Test("A linked worktree's .git file names its metadata folder in the repository")
    func linked() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("repo")
        try repos.worktree("wt/feature", of: "repo")
        try repos.worktree("wt/relative", of: "repo", relative: true)

        let feature = try #require(GitWorktree.at(tree.path("wt/feature")))
        #expect(feature.metadata == tree.path("repo/.git/worktrees/feature"))
        #expect(feature.repository == tree.path("repo"))
        #expect(!feature.isOrphaned)
        let relative = try #require(GitWorktree.at(tree.path("wt/relative")))
        #expect(relative.metadata == tree.path("repo/.git/worktrees/relative"))
        #expect(!relative.isOrphaned)
    }

    @Test("A worktree whose repository is gone, or no longer lists it, is orphaned")
    func orphaned() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("deleted")
        try repos.worktree("wt/a", of: "deleted")
        try repos.repository("pruned")
        try repos.worktree("wt/b", of: "pruned")
        try FileManager.default.removeItem(atPath: tree.path("deleted"))
        try FileManager.default.removeItem(atPath: tree.path("pruned/.git/worktrees/b"))

        #expect(GitWorktree.at(tree.path("wt/a"))?.isOrphaned == true)
        #expect(GitWorktree.at(tree.path("wt/b"))?.isOrphaned == true)
        #expect(GitWorktree.at(tree.path("wt/a"))?.lastGitActivity == nil)
    }

    @Test("A repository that can't be reached (its volume unmounted, a folder that can't be read) doesn't orphan its worktrees")
    func unreachable() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.write("wt/unmounted/.git", "gitdir: \(tree.path("Volumes/External/code/repo/.git/worktrees/unmounted"))\n")
        try repos.repository("locked/repo")
        try repos.worktree("wt/locked", of: "locked/repo")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.path("locked/repo/.git"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.path("locked/repo/.git")) }

        #expect(GitWorktree.at(tree.path("wt/unmounted")) == nil)
        #expect(GitWorktree.at(tree.path("wt/locked")) == nil)
    }

    @Test("A relative gitdir is resolved from the worktree's real location, as git does")
    func relativeThroughSymlink() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("real/repo")
        try repos.worktree("real/wt", of: "real/repo", relative: true)
        try FileManager.default.createSymbolicLink(atPath: tree.path("shortcut"), withDestinationPath: tree.path("real/wt"))

        let worktree = try #require(GitWorktree.at(tree.path("shortcut")))
        #expect(!worktree.isOrphaned)
        #expect(worktree.metadata == tree.path("real/repo/.git/worktrees/wt"))
    }

    @Test("Repositories, submodules, symlinked or unreadable .git entries aren't worktrees")
    func notWorktrees() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("repo")
        try repos.write("repo/.git/modules/lib/HEAD", "ref\n")
        try repos.write("repo/lib/.git", "gitdir: ../.git/modules/lib\n")
        try repos.write("notes/.git", "just some text\n")
        try repos.worktree("wt/real", of: "repo")
        try tree.directory("linked")
        try FileManager.default.createSymbolicLink(atPath: tree.path("linked/.git"), withDestinationPath: tree.path("wt/real/.git"))

        #expect(GitWorktree.at(tree.path("repo")) == nil)
        #expect(GitWorktree.at(tree.path("repo/lib")) == nil)
        #expect(GitWorktree.at(tree.path("notes")) == nil)
        #expect(GitWorktree.at(tree.path("linked")) == nil)
        #expect(GitWorktree.at(tree.path("missing")) == nil)
    }

    @Test("Git's own record of the worktree (index, HEAD, reflog) is its last git activity")
    func gitActivity() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("repo")
        try repos.worktree("wt", of: "repo")
        try repos.age("repo/.git/worktrees/wt")
        let recent = Date().addingTimeInterval(-2 * 86_400)
        try repos.write("repo/.git/worktrees/wt/logs/HEAD", "commit\n")
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: tree.path("repo/.git/worktrees/wt/logs/HEAD"))

        let activity = try #require(GitWorktree.at(tree.path("wt"))?.lastGitActivity)
        #expect(abs(activity.timeIntervalSince(recent)) < 2)
    }

    @Test("Unused worktrees are claimed whole; the engine searches active ones like any other folder")
    func engineClaimsUnused() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("repo")
        for name in ["idle", "active", "orphan"] {
            try repos.worktree("wt/\(name)", of: "repo")
            try repos.write("wt/\(name)/package.json", "{}\n")
            try tree.file("wt/\(name)/node_modules/lib/index.js", bytes: 20_000)
        }
        try repos.age("wt/idle")
        try repos.age("repo/.git/worktrees/idle")
        try FileManager.default.removeItem(atPath: tree.path("repo/.git/worktrees/orphan"))

        let scanned = try scan(tree.root, markers: ["package.json"])
        let findings = RuleEngine(rules: [worktreeRule, nodeModulesRule], devRoots: [tree.root]).evaluate(scanned)
        let worktrees = try #require(findings.first { $0.rule.id == "git.unused-worktrees" })
        #expect(Set(worktrees.items.map(\.path)) == [tree.path("wt/idle"), tree.path("wt/orphan")])
        let idle = try #require(worktrees.items.first { $0.path == tree.path("wt/idle") })
        #expect(idle.isRepository)
        #expect(idle.project == tree.path("repo"))
        #expect(idle.size == scanned.node(at: tree.path("wt/idle"))?.size)
        #expect((idle.idleDays() ?? 0) >= 89)
        let nodeModules = findings.first { $0.rule.id == "nm" }?.items.map(\.path)
        #expect(nodeModules == [tree.path("wt/active/node_modules")])
    }

    @Test("Recent git activity keeps a worktree in use even when its files are old")
    func gitActivityKeepsWorktree() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("repo")
        try repos.worktree("wt", of: "repo")
        try repos.age("wt")

        let scanned = try scan(tree.root)
        #expect(RuleEngine(rules: [worktreeRule], devRoots: [tree.root]).evaluate(scanned).isEmpty)
    }

    @Test("Rule files: match.worktrees replaces match.names, and idleFor is at least a day")
    func validation() throws {
        let yaml = "id: w\nname: W\nmatch:\n  worktrees:\n    idleFor: 30d\nsafety: review\naction: remove\n"
        let rule = try RuleLibrary.parse(yaml: yaml, source: "w.yaml").first
        #expect(rule?.match?.worktrees?.idleFor == .days(30))
        #expect(RuleLibrary.issues(for: try #require(rule)).isEmpty)

        let both = Rule(id: "b", name: "B", match: PatternSpec(names: ["wt"], worktrees: WorktreeSpec(idleFor: .days(30))))
        #expect(RuleLibrary.issues(for: both).contains { $0.severity == .error && $0.message.contains("match.worktrees") })
        let neither = Rule(id: "n", name: "N", match: PatternSpec(names: []))
        #expect(RuleLibrary.issues(for: neither).contains { $0.severity == .error && $0.message.contains("match.names") })
        let protected = Rule(
            id: "p", name: "P", match: PatternSpec(names: [], worktrees: WorktreeSpec(idleFor: .days(30))),
            safety: SafetySpec(level: .protected))
        #expect(RuleLibrary.issues(for: protected).contains { $0.severity == .error && $0.message.contains("protected") })
        let tooShort = "id: w\nname: W\nmatch:\n  worktrees:\n    idleFor: 1h\n"
        #expect(throws: (any Error).self) { try RuleLibrary.parse(yaml: tooShort, source: "w.yaml") }
    }

    @Test("An override may raise idleFor but not lower it, and can't add worktree matching to a name pattern")
    func overrides() throws {
        let builtin = Rule(id: "w", name: "W", match: PatternSpec(names: [], worktrees: WorktreeSpec(idleFor: .days(30))))
        func problems(_ match: PatternSpec) -> [String] {
            RuleLibrary.overrideProblems(builtin: builtin, override: Rule(id: "w", name: "W", match: match))
        }
        #expect(problems(PatternSpec(names: [], worktrees: WorktreeSpec(idleFor: .days(60)))).isEmpty)
        #expect(problems(PatternSpec(names: [], worktrees: WorktreeSpec(idleFor: .days(7)))).contains { $0.contains("idleFor") })

        let names = Rule(id: "n", name: "N", match: PatternSpec(names: ["build"]))
        let widened = Rule(id: "n", name: "N", match: PatternSpec(names: ["build"], worktrees: WorktreeSpec(idleFor: .days(30))))
        let added = RuleLibrary.overrideProblems(builtin: names, override: widened)
        #expect(added.contains { $0.contains("worktrees") })
    }

    @Test("The guard counts a worktree as the rule's, so removing one asks for a review, never for an unknown folder")
    func guardScope() throws {
        let tree = try TempTree()
        let repos = Repositories(tree: tree)
        try repos.repository("home/repo")
        try repos.worktree("home/wt", of: "home/repo")
        try repos.write("home/plain/file.txt", "x\n")
        let guardian = testGuard(home: tree.path("home"))

        let verdict = guardian.check(tree.path("home/wt"), rule: worktreeRule, context: .manual)
        #expect(verdict.reasons.contains { $0.contains("Unused git worktrees is marked “Review”") }, "\(verdict.reasons)")
        #expect(!verdict.reasons.contains { $0.contains("No SpaceKit rule recognises this") })
        let plain = guardian.check(tree.path("home/plain"), rule: worktreeRule, context: .manual)
        #expect(plain.reasons.contains { $0.contains("No SpaceKit rule recognises this") }, "\(plain.reasons)")
        let automation = AutomationContext(jobID: "j", allowReview: true)
        let automatic = guardian.check(tree.path("home/wt"), rule: worktreeRule, context: .automatic(automation), isRepository: true)
        #expect(automatic.decision == .block)
    }
}
