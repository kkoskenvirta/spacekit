import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Path helpers")
struct PathUtilTests {
    let realHome = PathUtil.standardize(FileManager.default.homeDirectoryForCurrentUser.path)

    @Test("SPACEKIT_HOME is ignored unless the build honours it")
    func homeOverride() {
        let environment = ["SPACEKIT_HOME": "/private/tmp/sandbox"]
        #expect(PathUtil.resolveHome(environment: environment, honorsOverride: false) == realHome)
        #expect(PathUtil.resolveHome(environment: environment, honorsOverride: true) == "/private/tmp/sandbox")
        #expect(PathUtil.resolveHome(environment: ["SPACEKIT_HOME": ""], honorsOverride: true) == realHome)
    }

    @Test("Comparison keys fold case and Unicode normalization")
    func comparisonKey() {
        #expect(PathUtil.comparisonKey("/Users/Me/Library") == PathUtil.comparisonKey("/users/me/LIBRARY"))
        #expect(PathUtil.comparisonKey("/x/Caf\u{E9}").unicodeScalars.elementsEqual(PathUtil.comparisonKey("/x/CAFE\u{301}").unicodeScalars))
    }

    @Test("A folder could contain a glob's matches when its components match the glob's leading components")
    func couldContain() {
        #expect(PathUtil.couldContain("/opt/homebrew/var", pattern: "/opt/homebrew/var/postgresql@*"))
        #expect(PathUtil.couldContain("/a/b", pattern: "/a/*/c"))
        #expect(PathUtil.couldContain("/a/b/c/d", pattern: "/a/**/z"))
        #expect(!PathUtil.couldContain("/opt/homebrew/var/postgresql@16", pattern: "/opt/homebrew/var/postgresql@*"))
        #expect(!PathUtil.couldContain("/opt/other", pattern: "/opt/homebrew/var/postgresql@*"))
        #expect(PathUtil.couldContain("/a", pattern: "/a/b"))
        #expect(!PathUtil.couldContain("/a/b", pattern: "/a/b"))
    }

    @Test("Patterns resolve symlinks in their existing literal prefix, keeping globs and a final named link")
    func canonicalPattern() throws {
        #expect(PathUtil.canonicalPattern("/tmp/spacekit-none/*") == "/private/tmp/spacekit-none/*")
        #expect(PathUtil.canonicalPattern("/tmp/spacekit-none/cache") == "/private/tmp/spacekit-none/cache")
        #expect(PathUtil.canonicalPattern("~/Library/Caches") == "~/Library/Caches")
        #expect(PathUtil.canonicalPattern("active_projects") == "active_projects")
        #expect(PathUtil.canonicalPattern("/") == "/")

        let tree = try TempTree()
        try tree.directory("real/target")
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real"))
        try FileManager.default.createSymbolicLink(atPath: tree.path("real/alias"), withDestinationPath: tree.path("real/target"))
        #expect(PathUtil.canonicalPattern(tree.path("link/*/x")) == tree.path("real/*/x"))
        // A pattern that names a symlink means the link, not what it points at.
        #expect(PathUtil.canonicalPattern(tree.path("link/alias")) == tree.path("real/alias"))
    }

    @Test("Rule and job paths written through a symlink match a scan, which reports resolved paths")
    func rulesThroughSymlinks() throws {
        let tree = try TempTree()
        try tree.file("real/cache/a/blob", bytes: 4_000)
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real"))
        let scanned = try scan(tree.path("link"))
        let whole = Rule(id: "whole", name: "whole", paths: [tree.path("link/cache")])
        let glob = Rule(id: "glob", name: "glob", paths: [tree.path("link/c*")], granularity: .children)
        for rule in [whole, glob] {
            let engine = RuleEngine(rules: [rule])
            #expect(engine.requiredRoots().allSatisfy(scanned.covers), "\(rule.id)")
            #expect(engine.evaluate(scanned).first?.items.isEmpty == false, "\(rule.id)")
        }
    }
}
