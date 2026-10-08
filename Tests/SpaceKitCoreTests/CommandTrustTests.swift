import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// The bytes of a stand-in for a compiled program called `name`: a Mach-O header's first word, so the program walk
/// takes it for one the system loads, and then text. Nothing ever starts it.
func machOStandIn(_ name: String) -> Data {
    Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(" stand-in for \(name)\n".utf8)
}

/// Stands in for running tools: records every call and answers with what the test scripted, so trust and budget
/// tests never start a real program.
final class RecordingRunner: ProcessRunner {
    let searchPath: [String]
    private let locator: @Sendable (String) -> String?
    private let respond: @Sendable (_ call: [String]) -> Shell.Result
    private let recorded = Mutex<[(call: [String], kind: Shell.RunKind)]>([])

    /// Each tool in `installed` is found as a small stand-in file in `tree`, so the executor has a program file to check.
    convenience init(
        installed: Set<String>, in tree: TempTree,
        respond: @escaping @Sendable (_ call: [String]) -> Shell.Result = { _ in Shell.Result(status: 0, output: "", timedOut: false) }
    ) {
        let folder = tree.path("installed-tools")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in installed { try? machOStandIn(name).write(to: URL(fileURLWithPath: folder + "/" + name)) }
        self.init(searchPath: [folder], locate: { installed.contains($0) ? folder + "/" + $0 : nil }, respond: respond)
    }

    /// Tools are found the way `Shell.which` finds them, in `searchPath`; still none is started.
    convenience init(
        searchPath: [String],
        respond: @escaping @Sendable (_ call: [String]) -> Shell.Result = { _ in Shell.Result(status: 0, output: "", timedOut: false) }
    ) {
        self.init(searchPath: searchPath, locate: { Shell.which($0, in: searchPath) }, respond: respond)
    }

    private init(
        searchPath: [String], locate: @escaping @Sendable (String) -> String?,
        respond: @escaping @Sendable (_ call: [String]) -> Shell.Result
    ) {
        self.searchPath = searchPath
        self.locator = locate
        self.respond = respond
    }

    func locate(_ name: String) -> String? { locator(name) }

    /// Scripted: the test puts standard output in `output`, and standard error in `errors` for a run that keeps it apart.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, separateErrors: Bool, kind: Shell.RunKind)
        -> Shell.Result
    {
        let call = [PathUtil.lastComponent(executable)] + arguments
        recorded.withLock { $0.append((call, kind)) }
        return respond(call)
    }

    /// Every call so far, the tool by its bare name.
    var calls: [[String]] { recorded.withLock { $0.map(\.call) } }
    /// The environment each call so far was given.
    var kinds: [Shell.RunKind] { recorded.withLock { $0.map(\.kind) } }
}

@Suite("Command trust")
struct CommandTrustTests {
    func rule(
        _ id: String = "tool", builtin: Bool, level: SafetyLevel = .safe, command: [String]? = nil, itemCommand: [String]? = nil,
        paths: [String] = ["/Users/tester/.tool/cache"]
    ) -> Rule {
        var rule = Rule(
            id: id, name: id, paths: paths, granularity: .children, safety: SafetySpec(level: level),
            action: ActionSpec(command: command, itemCommand: itemCommand))
        rule.isBuiltin = builtin
        return rule
    }

    /// `changeable`: which part of a program's path the person could change; by default none, since a test's stand-in
    /// programs are in its own folder and an automatic run would skip them.
    func executor(
        _ tree: TempTree, rules: [Rule], runner: RecordingRunner, budget: ByteCount = .gb(100), allowed: Set<String> = [],
        changeable: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> CleanupExecutor {
        var executor = sandboxExecutor(tree, rules: rules, budget: budget, allowed: allowed)
        executor.runner = runner
        executor.changeable = changeable
        return executor
    }

    func skipReason(_ outcome: CleanupOutcome?) -> String? {
        if case .skipped(let reason, _) = outcome { return reason }
        return nil
    }

    let automatic = CleanupContext.automatic(AutomationContext(jobID: "j"))

    @Test("Who may run what: built-in rules use the trusted list, user rules allowedCommands and only by hand, launchers never")
    func decisionTable() {
        let trust = CommandTrust(allowedCommands: ["mytool", "sh", "baſh", "oſaſcript", "xcrun"])
        func refused(_ executable: String, builtin: Bool, _ context: CleanupContext) -> Bool {
            let command = PlannedCommand(ruleID: "tool", arguments: [executable, "x"], estimatedBytes: 1)
            return !trust.refusals(command, rule: rule(builtin: builtin, command: [executable, "x"]), context: context).isEmpty
        }
        // Built-in rule: trusted tools in every run, allowedCommands too, anything else never.
        #expect(!refused("brew", builtin: true, .manual) && !refused("brew", builtin: true, automatic))
        #expect(!refused("mytool", builtin: true, automatic))
        #expect(refused("make", builtin: true, .manual))
        // User rule: only allowedCommands, only by hand; the trusted list is no help.
        #expect(!refused("mytool", builtin: false, .manual))
        #expect(refused("mytool", builtin: false, automatic))
        #expect(refused("brew", builtin: false, .manual))
        // A code launcher in allowedCommands still never runs, in any spelling APFS finds it by.
        #expect(refused("sh", builtin: false, .manual) && refused("sh", builtin: true, .manual))
        #expect(refused("baſh", builtin: false, .manual) && refused("oſaſcript", builtin: true, .manual))
        // xcrun is trusted for built-in rules only; allowing it doesn't let a rule of yours start any developer tool.
        #expect(!refused("xcrun", builtin: true, automatic) && refused("xcrun", builtin: false, .manual))
        // swift is a launcher, but on the trusted list for built-in rules.
        #expect(!refused("swift", builtin: true, automatic))
        #expect(refused("/usr/local/bin/mytool", builtin: false, .manual))
    }

    @Test("Tools get a cleaned environment: PATH, HOME, locale, tool homes and Homebrew settings stay; the rest goes")
    func cleanedEnvironment() {
        let parent = [
            "PATH": "/usr/bin:relative", "HOME": "/Users/tester", "USER": "tester", "LOGNAME": "tester", "LANG": "en_US.UTF-8",
            "LC_ALL": "C", "TMPDIR": "/var/folders/x", "XDG_CACHE_HOME": "/Users/tester/.xdg", "CARGO_HOME": "/Users/tester/.cargo",
            "RUSTUP_HOME": "/r", "GOPATH": "/g", "GOMODCACHE": "/gm", "GOCACHE": "/gc", "npm_config_cache": "/n",
            "NPM_CONFIG_CACHE": "/N", "PNPM_HOME": "/p", "YARN_CACHE_FOLDER": "/y", "GRADLE_USER_HOME": "/gr",
            "OLLAMA_MODELS": "/o", "HOMEBREW_CACHE": "/hc", "HOMEBREW_PREFIX": "/opt/homebrew",
            "DOCKER_HOST": "tcp://build.example.com:2376", "DOCKER_CONTEXT": "remote", "DOCKER_CONFIG": "/elsewhere",
            "OLLAMA_HOST": "gpu.example.com", "GITHUB_TOKEN": "ghp_x", "AWS_SECRET_ACCESS_KEY": "s", "HF_TOKEN": "h",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "NODE_OPTIONS": "--require /tmp/evil.js", "SSH_AUTH_SOCK": "/tmp/agent",
            // Homebrew's own settings change what `brew cleanup` keeps; its credentials don't belong to any tool.
            "HOMEBREW_NO_CLEANUP_FORMULAE": "llvm,python@3.12", "HOMEBREW_CLEANUP_MAX_AGE_DAYS": "365", "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_GITHUB_API_TOKEN": "ghp_y", "HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN": "b", "HOMEBREW_ARTIFACT_PASSWORD": "p",
            "HOMEBREW_BOTTLE_SECRET": "s", "HOMEBREW_API_KEY": "k", "HOMEBREW_GITHUB_PACKAGES_AUTH": "a",
            // Picks the developer folder xcrun starts tools from: one of the person's own folders would get SpaceKit's Full
            // Disk Access.
            "DEVELOPER_DIR": "/Users/tester/Developer",
        ]
        let environment = Shell.toolEnvironment(from: parent, home: "/Users/tester")
        let droppedMarks = [
            "DEVELOPER", "DOCKER", "OLLAMA_HOST", "TOKEN", "AWS", "DYLD", "NODE", "SSH", "PATH", "PASSWORD", "SECRET", "KEY", "AUTH",
        ]
        for kept in parent.keys where !droppedMarks.contains(where: { kept.contains($0) }) {
            #expect(environment[kept] == parent[kept], "\(kept)")
        }
        for dropped in [
            "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "OLLAMA_HOST", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "HF_TOKEN",
            "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "SSH_AUTH_SOCK", "HOMEBREW_GITHUB_API_TOKEN",
            "HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN", "HOMEBREW_ARTIFACT_PASSWORD", "HOMEBREW_BOTTLE_SECRET", "HOMEBREW_API_KEY",
            "HOMEBREW_GITHUB_PACKAGES_AUTH", "DEVELOPER_DIR",
        ] {
            #expect(environment[dropped] == nil, "\(dropped)")
        }
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/usr/bin" && path.contains("/opt/homebrew/bin") && !path.contains("relative"))

        // Nobody watches an automatic run, and any process of the person's can set the agent's variables (launchctl
        // setenv): a tool home, an XDG folder or a Homebrew setting would steer what a tool deletes. Only who and where.
        let automatic = Shell.toolEnvironment(from: parent, home: "/Users/tester", kind: .automatic)
        #expect(
            Set(automatic.keys) == Set(["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"] + Shell.isolationVariables.keys))
        let fixed = Shell.automaticSearchPath(path, changeable: CommandTrust.changeablePart(of:))
        #expect(automatic["PATH"] == fixed.joined(separator: ":") && fixed.contains("/usr/bin") && automatic["HOME"] == "/Users/tester")
    }

    @Test("The real runner hands a tool the cleaned environment, not SpaceKit's own")
    func realRunnerCleansEnvironment() {
        let result = Shell.run(
            "/usr/bin/env", [], timeout: 10, environment: ["HOME": "/Users/tester", "DOCKER_HOST": "tcp://remote:2376", "API_TOKEN": "x"])
        let lines = Set(result.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=/Users/tester"))
        #expect(!result.output.contains("DOCKER_HOST") && !result.output.contains("API_TOKEN"))
    }

    @Test("The real runner keeps a query's standard error apart from its output")
    func realRunnerSeparatesErrors() {
        let script = "echo endpoint; echo 'WARNING: noise' >&2"
        let apart = Shell.run("/bin/sh", ["-c", script], timeout: 10, environment: [:], separateErrors: true)
        #expect(apart.status == 0 && apart.output == "endpoint\n" && apart.errors == "WARNING: noise\n")
        let merged = Shell.run("/bin/sh", ["-c", script], timeout: 10, environment: [:])
        #expect(merged.output.contains("endpoint") && merged.output.contains("WARNING") && merged.errors.isEmpty)
    }

    @Test("Refused commands never reach the runner")
    func refusalsDontRun() throws {
        let tree = try TempTree()
        let runner = RecordingRunner(installed: ["du", "sh", "brew"], in: tree)
        let user = rule("user", builtin: false, command: ["du", "-s", "/Users/tester/.tool/cache"])
        let launcher = rule("launcher", builtin: false, command: ["sh", "-c", "true"])
        let untrusted = rule("untrusted", builtin: true, command: ["make", "clean"])
        let plan = CleanupPlan(
            commands: [user, launcher, untrusted].map { rule in
                PlannedCommand(ruleID: rule.id, arguments: rule.action.command ?? [], estimatedBytes: 1)
            })
        let executor = executor(tree, rules: [user, launcher, untrusted], runner: runner, allowed: ["du", "sh"])
        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.commands.count == 3)
        #expect(report.commands.allSatisfy { skipReason($0.outcome) != nil })
        #expect(runner.calls.isEmpty)
        // By hand, the allowed user command runs; the launcher and the untrusted built-in one still don't.
        let manual = manualRun(plan, with: executor)
        #expect(manual.commands.filter { skipReason($0.outcome) == nil }.map(\.command.ruleID) == ["user"])
        #expect(runner.calls == [["du", "-s", "/Users/tester/.tool/cache"]])
        #expect(runner.kinds == [.manual])
    }

    /// Writes an executable file to `relative` in `tree`: a script with `text` (from `#!` on), or without it a stand-in
    /// for a compiled program (`machOStandIn`). Nothing runs it: the recording runner only finds it.
    @discardableResult
    func program(_ tree: TempTree, _ relative: String, _ text: String? = nil, mode: mode_t = 0o755) throws -> String {
        let path = tree.path(relative)
        try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
        try (text.map { Data($0.utf8) } ?? machOStandIn("program")).write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, mode) == 0)
        return path
    }

    /// Runs `name` from a rule of yours that allows it, by hand, with tools found in `tree`'s `bin` first. Nothing
    /// starts: the runner records what would.
    func runAllowed(_ name: String, in tree: TempTree) -> (outcome: CleanupOutcome?, calls: [[String]]) {
        let runner = RecordingRunner(searchPath: [tree.path("bin")] + Shell.searchPath)
        let tool = rule("tool", builtin: false, command: [name, "--all"])
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: [name, "--all"], estimatedBytes: 1)])
        let report = manualRun(plan, with: executor(tree, rules: [tool], runner: runner, allowed: [name]))
        return (report.commands.first?.outcome, runner.calls)
    }

    @Test("An allowed name whose real file is a launcher, or a script a launcher runs, is refused and never started")
    func launcherBehindAName() throws {
        let tree = try TempTree()
        let files = FileManager.default
        try tree.directory("bin")
        // Symlinks: the real file's name is a launcher's, in any spelling APFS finds it by.
        try files.createSymbolicLink(atPath: tree.path("bin/cleanup-tool"), withDestinationPath: "/bin/sh")
        try program(tree, "real/ZSH")
        try files.createSymbolicLink(atPath: tree.path("bin/cache-tool"), withDestinationPath: tree.path("real/ZSH"))
        // Scripts a launcher runs, directly, through a hard link, or through env and its options.
        try program(tree, "bin/sh-script", "#!/bin/sh\nexit 0\n")
        #expect(link(tree.path("bin/sh-script"), tree.path("bin/tidy-tool")) == 0)
        try program(tree, "bin/env-python", "#!/usr/bin/env python3\nprint(1)\n")
        try program(tree, "bin/env-split", "#!/usr/bin/env -S perl -w\n")
        try program(tree, "bin/env-attached", "#!/usr/bin/env -iSruby\n")
        try program(tree, "bin/env-options", "#!/usr/bin/env -S -u HOME LANG=C node\n")
        try program(tree, "bin/env-long", "#!/usr/bin/env --split-string=tidy\n")
        try program(tree, "bin/env-nothing", "#!/usr/bin/env -i\n")
        // A script whose interpreter is a script a launcher runs.
        try program(tree, "bin/helper", "#!/bin/bash\n")
        try program(tree, "bin/env-helper", "#!/usr/bin/env helper\n")
        try program(tree, "bin/direct-helper", "#!\(tree.path("bin/helper")) -x\n")
        // Interpreters that can't be told: relative, missing, none at all, and a file that can't be read.
        try program(tree, "bin/relative", "#!bin/sh\n")
        try program(tree, "bin/env-missing", "#!/usr/bin/env no-such-tool-for-spacekit\n")
        try program(tree, "bin/bare", "#!\n")
        try program(tree, "bin/unreadable", mode: 0o111)

        let refused = [
            ("cleanup-tool", "'sh'"), ("cache-tool", "'ZSH'"), ("sh-script", "'sh'"), ("tidy-tool", "'sh'"),
            ("env-python", "'python3'"), ("env-split", "'perl'"), ("env-attached", "'ruby'"), ("env-options", "'node'"),
            ("env-long", "env"), ("env-nothing", "env"), ("env-helper", "'bash'"), ("direct-helper", "'bash'"),
            ("relative", "bin/sh"), ("env-missing", "no-such-tool-for-spacekit"), ("bare", "interpreter"), ("unreadable", "read"),
        ]
        for (name, mentioning) in refused {
            let result = runAllowed(name, in: tree)
            let reason = skipReason(result.outcome)
            #expect(reason?.contains(mentioning) == true, "\(name): \(reason ?? "ran")")
            #expect(result.calls.isEmpty, "\(name)")
        }
    }

    /// The Command Line Tools install one shim file under dozens of names (`git`, `pip3`, `swiftc`, `strip`), and Volta
    /// and mise link every tool to one shim; each picks what to run from the name it was started as. Comparing files
    /// would take `pip3` for `git`.
    @Test("Tools that share one program file with a launcher, or a shim that dispatches by name, run under their own names")
    func sharedProgramFiles() throws {
        let tree = try TempTree()
        let files = FileManager.default
        try program(tree, "bin/git")
        #expect(link(tree.path("bin/git"), tree.path("bin/pip3")) == 0)
        try program(tree, "shims/volta-shim")
        for name in ["node", "yarn"] {
            try files.createSymbolicLink(atPath: tree.path("bin/\(name)"), withDestinationPath: tree.path("shims/volta-shim"))
        }
        try program(tree, "bin/interpreter")
        try program(tree, "bin/by-env", "#!/usr/bin/env -S -i LANG=C interpreter --quiet\n")
        try program(tree, "bin/by-path", "#!\(tree.path("bin/interpreter")) -q\n")
        // A copy of a launcher under another name has its own file; the review names where it was found.
        try files.copyItem(atPath: "/bin/zsh", toPath: tree.path("bin/zsh-copy"))

        for name in ["pip3", "yarn", "by-env", "by-path", "zsh-copy"] {
            let result = runAllowed(name, in: tree)
            #expect(skipReason(result.outcome) == nil, "\(name): \(String(describing: result.outcome))")
            #expect(result.calls == [[name, "--all"]], "\(name)")
        }
    }

    /// The attacker SpaceKit defends against can write rule files and the config alike, so `safety.allowedCommands`
    /// can't tell a command the person wants from one planted next to it. Their acknowledgement can, once they see what
    /// would run.
    @Test("A command from your own rule always needs acknowledgement, which sees its full arguments and resolved path")
    func ownRuleCommandsNeedAcknowledgement() throws {
        let tree = try TempTree()
        let real = try program(tree, "tools/tidy-1.2")
        try tree.directory("bin")
        try FileManager.default.createSymbolicLink(atPath: tree.path("bin/tidy"), withDestinationPath: real)
        let arguments = ["tidy", "--all", "dir with space", "\u{1B}[2Khidden"]
        let mine = rule("mine", builtin: false, command: arguments)
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "mine", arguments: arguments, estimatedBytes: 1)])
        let runner = RecordingRunner(searchPath: [tree.path("bin")])
        let executor = executor(tree, rules: [mine], runner: runner, allowed: ["tidy"])

        let review = CleanupReview(plan, executor: executor)
        let row = try #require(review.commands.first)
        #expect(row.verdict.decision == .confirm)
        #expect(review.needsAcknowledgement)
        let reason = row.verdict.reasons.joined(separator: "\n")
        #expect(reason.contains("tidy --all 'dir with space' \\u{1B}[2Khidden"), "every argument, control characters made visible")
        #expect(reason.contains(tree.path("bin/tidy")) && reason.contains(real), "where it was found and the file that is")
        #expect(!reason.unicodeScalars.contains { $0.value == 0x1B })

        // `--yes` alone: selected, left undone, and reported.
        let unacknowledged = executor.execute(review.acknowledge(acceptingWarnings: false), dryRun: false)
        #expect(skipReason(unacknowledged.commands.first?.outcome)?.hasPrefix(CleanupExecutor.notAccepted) == true)
        #expect(runner.calls.isEmpty)
        let acknowledged = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(skipReason(acknowledged.commands.first?.outcome) == nil)
        #expect(runner.calls == [arguments])

        // The same tool in a built-in rule runs without one.
        let builtin = rule("mine", builtin: true, command: arguments)
        let trusted = CleanupReview(plan, executor: self.executor(tree, rules: [builtin], runner: runner, allowed: ["tidy"]))
        #expect(trusted.commands.first?.verdict.decision == .allow)
    }

    @Test("A command your review saw at one path doesn't run a program found at another")
    func reviewedExecutableBound() throws {
        let tree = try TempTree()
        try program(tree, "bin2/tidy")
        try tree.directory("bin1")
        for builtin in [false, true] {
            let tool = rule("tool", builtin: builtin, command: ["tidy", "--all"])
            let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: ["tidy", "--all"], estimatedBytes: 1)])
            let runner = RecordingRunner(searchPath: [tree.path("bin1"), tree.path("bin2")])
            let executor = executor(tree, rules: [tool], runner: runner, allowed: ["tidy"])
            let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
            // Found earlier on the search path after the review. Only a digit differs, which a share of the disk may do.
            try program(tree, "bin1/tidy")
            defer { unlink(tree.path("bin1/tidy")) }
            let report = executor.execute(reviewed, dryRun: false)
            #expect(skipReason(report.commands.first?.outcome)?.hasPrefix(CleanupExecutor.changedSinceReview) == true, "\(builtin)")
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("A command for one item runs only while that item is where your review judged it")
    func reviewedItemBound() throws {
        let tree = try TempTree()
        try tree.file("home/kegs/wget/bin", bytes: 1_000)
        let kegs = rule("kegs", builtin: true, itemCommand: ["brew", "uninstall", "{path}"], paths: [tree.path("home/kegs")])
        let item = FindingItem(path: tree.path("home/kegs/wget"), kind: .directory, name: "wget", size: 1_000)
        let plan = CleanupPlan.make(findings: [Finding(rule: kegs, items: [item])], scanStarted: Date())
        let runner = RecordingRunner(installed: ["brew"], in: tree)
        let executor = executor(tree, rules: [kegs], runner: runner)
        let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
        // Another folder of the same name stands where the reviewed one was.
        try FileManager.default.removeItem(atPath: tree.path("home/kegs/wget"))
        try tree.file("home/kegs/wget/other", bytes: 1_000)

        let report = executor.execute(reviewed, dryRun: false)

        #expect(skipReason(report.commands.first?.outcome)?.hasPrefix(CleanupExecutor.changedSinceReview) == true)
        #expect(report.hasProblems)
        #expect(runner.calls.isEmpty)

        let again = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
        #expect(executor.execute(again, dryRun: false).commands.first?.outcome.isRemoved == true)
        #expect(runner.calls == [["brew", "uninstall", tree.path("home/kegs/wget")]])
    }

    @Test("Your review shows a launcher behind an allowed name as blocked")
    func reviewBlocksLauncherBehindName() throws {
        let tree = try TempTree()
        try tree.directory("bin")
        try FileManager.default.createSymbolicLink(atPath: tree.path("bin/cleanup-tool"), withDestinationPath: "/bin/sh")
        let tool = rule("tool", builtin: false, command: ["cleanup-tool", "-c", "true"])
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: ["cleanup-tool", "-c", "true"], estimatedBytes: 1)])
        let runner = RecordingRunner(searchPath: [tree.path("bin")])
        let review = CleanupReview(plan, executor: executor(tree, rules: [tool], runner: runner, allowed: ["cleanup-tool"]))
        #expect(review.commands.first?.verdict.isBlocked == true)
        #expect(review.commands.first?.verdict.reasons.contains { $0.contains("'sh'") } == true)
    }

    /// The agent runs with Full Disk Access and nobody watching. A program in a folder the person can change, such as
    /// `~/.local/bin` or a Homebrew prefix they own, can be swapped by any program of theirs for its own.
    @Test("Automatic runs start a tool only from files and folders you can't change; your own folder is skipped")
    func automaticRunsNeedFixedPrograms() throws {
        let tree = try TempTree()
        try program(tree, "bin/tidy")
        let simulators = ["xcrun", "simctl", "delete", "unavailable"]
        let tidy = rule("tidy", builtin: true, command: ["tidy", "--all"])
        let xcrun = rule("xcrun", builtin: true, command: simulators)
        let plan = CleanupPlan(commands: [
            PlannedCommand(ruleID: "tidy", arguments: ["tidy", "--all"], estimatedBytes: 1),
            PlannedCommand(ruleID: "xcrun", arguments: simulators, estimatedBytes: 1),
        ])
        // The file system as it is: the test's own folder is yours, /usr/bin is the system's. Which developer folder this
        // Mac's xcode-select chose isn't what this tests, so a developer folder of the test's own stands in for the system's.
        try program(tree, "Developer/usr/bin/simctl")
        let developer = tree.path("xcode_select_link")
        try FileManager.default.createSymbolicLink(atPath: developer, withDestinationPath: tree.path("Developer"))
        let runner = RecordingRunner(searchPath: [tree.path("bin"), "/usr/bin"])
        let changeable: @Sendable (String) -> String? = { $0.hasPrefix(developer) ? nil : CommandTrust.changeablePart(of: $0) }
        var executor = executor(tree, rules: [tidy, xcrun], runner: runner, allowed: ["tidy"], changeable: changeable)
        executor.developerFolderLink = developer
        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        let reason = skipReason(report.commands.first?.outcome) ?? "ran"
        // The temporary folder the test's own folder is in is already yours.
        let yours = try #require(CommandTrust.changeablePart(of: tree.path("bin/tidy")))
        #expect(tree.path("bin/tidy").hasPrefix(yours))
        #expect(reason.contains("\(yours) can be replaced by any program of yours, so 'tidy' runs only when you start it"), "\(reason)")
        #expect(report.commands.last?.outcome.isRemoved == true)
        #expect(runner.calls == [simulators])

        // By hand the person starts it themselves, from wherever it is.
        let manual = manualRun(plan, with: executor)
        #expect(manual.commands.allSatisfy { skipReason($0.outcome) == nil })
    }

    @Test("A symlink or a folder above a program that you can change makes it changeable")
    func changeablePaths() throws {
        let tree = try TempTree()
        try program(tree, "mine/tool")
        try FileManager.default.createSymbolicLink(atPath: tree.path("mine/to-du"), withDestinationPath: "/usr/bin/du")
        #expect(CommandTrust.changeablePart(of: "/usr/bin/du") == nil)
        #expect(CommandTrust.changeablePart(of: "/bin/sh") == nil)
        #expect(CommandTrust.changeablePart(of: tree.path("mine/tool")).map { tree.path("mine/tool").hasPrefix($0) } == true)
        // The symlink sits in a folder of yours: you can point it elsewhere.
        #expect(CommandTrust.changeablePart(of: tree.path("mine/to-du")) != nil)
        // A system symlink to a file of yours leads to something you can change.
        #expect(CommandTrust.changeablePart(of: "/var/tmp") == "/private/var/tmp")
        // What isn't there can't be told apart from what is: refused.
        #expect(CommandTrust.changeablePart(of: "/usr/bin/no-such-tool-for-spacekit") == "/usr/bin/no-such-tool-for-spacekit")
    }

    @Test("What a command frees is charged to the run's budget; the next command that doesn't fit isn't started")
    func budgetCharging() throws {
        let tree = try TempTree()
        let cache = try tree.file("home/first/blob", bytes: 6_000)
        let freed = tree.allocated("home/first/blob")
        let runner = RecordingRunner(installed: ["go", "uv"], in: tree) { call in
            if call.first == "go" { try? FileManager.default.removeItem(atPath: cache) }
            return Shell.Result(status: 0, output: "", timedOut: false)
        }
        let first = rule("first", builtin: true, command: ["go", "clean", "-cache"])
        let second = rule("second", builtin: true, command: ["uv", "cache", "clean"])
        let plan = CleanupPlan(commands: [
            PlannedCommand(
                ruleID: "first", arguments: ["go", "clean", "-cache"], estimatedBytes: 6_000, measurePaths: [tree.path("home/first")]),
            PlannedCommand(ruleID: "second", arguments: ["uv", "cache", "clean"], estimatedBytes: 6_000),
        ])
        let budget = ByteCount(freed + 1_000)
        let report = executor(tree, rules: [first, second], runner: runner, budget: budget)
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.commands.first?.outcome == .removed(bytes: freed, trashedTo: nil))
        #expect(skipReason(report.commands.last?.outcome)?.contains("budget") == true)
        #expect(runner.calls == [["go", "clean", "-cache"]])
        #expect(runner.kinds == [.automatic], "an automatic run's tools get the automatic environment")
        #expect(journalEntries(tree).map(\.bytes) == [freed])
    }

    @Test("An item or model name that would read as an option is refused")
    func dashNames() throws {
        let tree = try TempTree()
        try tree.directory("home/kegs/-rf")
        try tree.directory("home/kegs/wget")
        let kegs = rule("kegs", builtin: true, itemCommand: ["brew", "uninstall", "{name}"], paths: [tree.path("home/kegs")])
        let finding = Finding(
            rule: kegs,
            items: ["-rf", "wget"].map { FindingItem(path: tree.path("home/kegs/\($0)"), kind: .directory, name: $0, size: 10) })
        let plan = CleanupPlan.make(findings: [finding], scanStarted: Date())
        #expect(plan.commands.map(\.arguments) == [["brew", "uninstall", "-rf"], ["brew", "uninstall", "wget"]])
        let runner = RecordingRunner(installed: ["brew"], in: tree)
        let report = manualRun(plan, with: executor(tree, rules: [kegs], runner: runner))
        let dashed = report.commands.first { $0.command.arguments.last == "-rf" }
        #expect(skipReason(dashed?.outcome)?.contains("'-rf'") == true)
        #expect(runner.calls == [["brew", "uninstall", "wget"]])

        // {path} is absolute, so a dash at the start of the folder name is harmless there.
        let byPath = rule("kegs", builtin: true, itemCommand: ["brew", "uninstall", "{path}"], paths: [tree.path("home/kegs")])
        let pathPlan = CleanupPlan.make(findings: [Finding(rule: byPath, items: finding.items)], scanStarted: Date())
        let pathRunner = RecordingRunner(installed: ["brew"], in: tree)
        let pathReport = manualRun(pathPlan, with: executor(tree, rules: [byPath], runner: pathRunner))
        #expect(pathReport.commands.allSatisfy { skipReason($0.outcome) == nil })
    }
}
