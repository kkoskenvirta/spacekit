import Foundation
import Testing

@testable import SpaceKitCore

/// Config and rule files decide what SpaceKit removes and runs, so files other users can change aren't read.
@Suite("Config and rule files other users can change")
struct FileTrustTests {
    @Test("A config file other users can write is a config error")
    func writableConfig() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        try "version: 1\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(chmod(file, 0o666) == 0)
        #expect(throws: ConfigError.self) { try ConfigStore(file: file).load() }
        let context = SpaceKitContext.load(paths: SpaceKitPaths(configFile: file, stateDirectory: tree.path("state")))
        #expect(context.configError != nil)
    }

    @Test("A config file in a folder other users can write to (without the sticky bit) is a config error")
    func configInWritableFolder() throws {
        let tree = try TempTree()
        try tree.directory("shared")
        let file = tree.path("shared/config.yaml")
        try "version: 1\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(chmod(tree.path("shared"), 0o777) == 0)
        defer { chmod(tree.path("shared"), 0o755) }
        #expect(throws: ConfigError.self) { try ConfigStore(file: file).load() }

        #expect(chmod(tree.path("shared"), 0o1777) == 0)
        #expect(throws: Never.self) { try ConfigStore(file: file).load() }
    }

    @Test("A rule file other users can write isn't loaded")
    func writableRuleFile() throws {
        let tree = try TempTree()
        try tree.directory("rules")
        let file = tree.path("rules/mine.yaml")
        try "id: mine.cache\nname: Mine\npath: ~/.mine/cache\nsafety: safe\naction: remove\n".write(
            toFile: file, atomically: true, encoding: .utf8)
        #expect(chmod(file, 0o664) == 0)
        let library = RuleLibrary.load(builtin: BuiltinRules(files: []), directories: [tree.path("rules")])
        #expect(library.rule(id: "mine.cache") == nil)
        #expect(library.issues.contains { $0.severity == .error && $0.source == file })

        #expect(chmod(file, 0o644) == 0)
        #expect(RuleLibrary.load(builtin: BuiltinRules(files: []), directories: [tree.path("rules")]).rule(id: "mine.cache") != nil)
    }

    static func mode(_ path: String) -> mode_t {
        var st = stat()
        stat(path, &st)
        return st.st_mode & 0o7777
    }

    @Test("SpaceKit gives its own config, backup, lock and state files fixed modes, whatever the umask")
    func modesIgnoreUmask() throws {
        let tree = try TempTree()
        let file = tree.path("config/spacekit/config.yaml")
        let journal = tree.path("state/SpaceKit/journal.jsonl")
        let store = ConfigStore(file: file)
        // Under umask 002 the defaults would make the config group-writable and refused on the next load.
        try withUmask(0o077) {
            try store.initialize()
            try store.update { $0.ui.mapDepth = 3 }
            try Journal(file: journal).append([JournalEntry(path: "/x", bytes: 1, method: .delete, automatic: false)])
            try SpaceKitPaths.writeRuleFile("rules: []\n", to: tree.path("config/spacekit/rules/mine.yaml"))
        }

        let folders = ["config", "config/spacekit", "config/spacekit/rules", "state", "state/SpaceKit"].map(tree.path)
        for folder in folders {
            #expect(FileTrustTests.mode(folder) == 0o755, "\(folder)")
        }
        for created in [file, file + ".bak", file + ".lock", journal, tree.path("config/spacekit/rules/mine.yaml")] {
            #expect(FileTrustTests.mode(created) == 0o644, "\(created)")
        }
        #expect(throws: Never.self) { try store.load() }
    }

    @Test("Saving keeps a config the person made private private, and its backup too")
    func savingNeverWidens() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        let store = ConfigStore(file: file)
        try store.initialize()
        #expect(chmod(file, 0o600) == 0)

        try store.update { $0.ui.mapDepth = 3 }

        #expect(FileTrustTests.mode(file) == 0o600)
        #expect(FileTrustTests.mode(file + ".bak") == 0o600)
    }

    @Test("Built-in rules aren't files anyone owns; a debug build's SPACEKIT_RULES_DIR files must still be trusted")
    func builtinRulesNeedNoOwner() throws {
        let tree = try TempTree()
        let file = tree.path("rules/builtin.yaml")
        try tree.file("rules/builtin.yaml", bytes: 10)
        #expect(chmod(file, 0o664) == 0)
        let environment = ["SPACEKIT_RULES_DIR": tree.path("rules")]

        // Whoever installed SpaceKit, its built-in rules come from the binary, so no file owner or mode can refuse them.
        let release = BuiltinRules.standard(environment: environment, debugBuild: false)
        #expect(release.issues.isEmpty)
        #expect(!release.files.isEmpty && release.files.allSatisfy { $0.source.hasPrefix("built-in rules/") })

        // A folder standing in for them is held to the same rules as any rule file. With its only file refused it
        // has no rules, so the embedded ones stay.
        let debug = BuiltinRules.standard(environment: environment, debugBuild: true)
        #expect(!debug.files.contains { $0.source == file })
        #expect(debug.issues.first?.message == "not loaded: it can be changed by other users (group or world writable)")
        #expect(debug.issues.count == 2)
        #expect(FileTrust.problem(with: file, owners: FileTrust.owners(user: getuid() &+ 4_242)) == "is owned by another user")
    }

    /// Runs `chmod` with `arguments` (ACL edits have no Foundation API).
    static func chmodACL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "chmod \(arguments.joined(separator: " "))")
    }

    @Test("A file whose ACL lets others write it isn't trusted")
    func fileACL() throws {
        let tree = try TempTree()
        let file = tree.path("rules/mine.yaml")
        try tree.file("rules/mine.yaml", bytes: 10)
        #expect(chmod(file, 0o644) == 0)
        defer { try? FileTrustTests.chmodACL(["-N", file]) }

        try FileTrustTests.chmodACL(["+a", "everyone deny delete", file])
        #expect(FileTrust.problem(with: file) == nil)
        try FileTrustTests.chmodACL(["+a", "user:\(NSUserName()) allow write", file])
        #expect(FileTrust.problem(with: file) == nil)
        try FileTrustTests.chmodACL(["+a", "everyone allow write", file])
        #expect(FileTrust.problem(with: file) != nil)
    }

    @Test("A file in a folder whose ACL lets others add or delete entries isn't trusted")
    func folderACL() throws {
        let tree = try TempTree()
        let folder = tree.path("rules")
        let file = tree.path("rules/mine.yaml")
        try tree.file("rules/mine.yaml", bytes: 10)
        #expect(chmod(file, 0o644) == 0)
        defer { try? FileTrustTests.chmodACL(["-N", folder]) }

        try FileTrustTests.chmodACL(["+a", "everyone deny delete", folder])
        #expect(FileTrust.problem(with: file) == nil)
        try FileTrustTests.chmodACL(["+a", "everyone allow add_file,delete_child", folder])
        #expect(FileTrust.problem(with: file) != nil)
        #expect(throws: ConfigError.self) {
            try "version: 1\n".write(toFile: tree.path("rules/config.yaml"), atomically: false, encoding: .utf8)
            chmod(tree.path("rules/config.yaml"), 0o644)
            _ = try ConfigStore(file: tree.path("rules/config.yaml")).load()
        }
    }
}
