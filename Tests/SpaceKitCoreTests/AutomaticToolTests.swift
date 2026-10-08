import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// What an automatic run starts: only programs, interpreters and search folders nothing of the person's can change, in
/// an environment that leaves their own tool settings behind. Nothing here starts a program the test wrote.
extension CommandTrustTests {
    /// A test's folders are its own, which settles the walk at once. Judged as someone else (`user`), each folder shows
    /// what else makes it changeable; the folders are made unwritable for their owner too, so no access check passes them
    /// for the test's own account.
    @Test("A folder writable through its group, by everyone (sticky or not) or by an access control list counts as changeable")
    func changeableFolderModes() throws {
        let tree = try TempTree()
        let someoneElse = getuid() &+ 1
        func isChangeable(_ relative: String, mode: mode_t, acl: String? = nil) throws -> Bool {
            try tree.directory(relative)
            let path = tree.path(relative)
            #expect(chown(path, getuid(), getgid()) == 0)
            #expect(chmod(path, mode) == 0)
            if let acl { #expect(Shell.run("/bin/chmod", ["+a", acl, path], timeout: 10).status == 0) }
            var st = stat()
            #expect(lstat(path, &st) == 0)
            return CommandTrust.isChangeable(path, st, user: someoneElse)
        }
        #expect(try !isChangeable("closed", mode: 0o555))
        #expect(try isChangeable("group", mode: 0o575), "your own group can write it")
        #expect(try isChangeable("everyone", mode: 0o557))
        #expect(try isChangeable("sticky", mode: 0o1557), "the sticky bit stops renames, not new programs")
        #expect(try isChangeable("acl", mode: 0o555, acl: "user:\(NSUserName()) allow add_file,add_subdirectory"))
        #expect(try !isChangeable("denied", mode: 0o555, acl: "user:\(NSUserName()) deny add_file"))
        // The system's sticky, world-writable folder.
        #expect(CommandTrust.changeablePart(of: "/private/tmp/no-such-tool-for-spacekit") == "/private/tmp")
    }

    @Test("A symlinked folder on the way to a program is checked, and so is the folder it leads to")
    func changeableThroughSymlinkedFolder() throws {
        let tree = try TempTree()
        try program(tree, "real/bin/tool")
        try FileManager.default.createSymbolicLink(atPath: tree.path("absolute"), withDestinationPath: tree.path("real"))
        try FileManager.default.createSymbolicLink(atPath: tree.path("relative"), withDestinationPath: "real")
        for link in ["absolute", "relative"] {
            let tool = tree.path("\(link)/bin/tool")
            #expect(CommandTrust.changeablePart(of: tool) { part, _ in part == tree.path(link) } == tree.path(link))
            #expect(CommandTrust.changeablePart(of: tool) { part, _ in part == tree.path("real") } == tree.path("real"), "\(link)")
            #expect(CommandTrust.changeablePart(of: tool) { part, _ in part == tree.path("real/bin/tool") } == tree.path("real/bin/tool"))
            #expect(CommandTrust.changeablePart(of: tool) { _, _ in false } == nil)
        }
    }

    @Test("The walk follows a symlink whose target climbs with .., and gives up past the system's symlink limit")
    func changeableWalkEdges() throws {
        let tree = try TempTree()
        // The test's own folder, without the /var link above it, so every symlink the walk follows is the test's.
        let root = try #require(PathUtil.realpath(tree.root))
        try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        try program(tree, "real/bin/tool")
        try FileManager.default.createSymbolicLink(atPath: root + "/up", withDestinationPath: "a/b/../../real")
        let visited = Mutex<[String]>([])
        let result = CommandTrust.changeablePart(of: root + "/up/bin/tool") { part, _ in
            visited.withLock { $0.append(part) }
            return false
        }
        #expect(result == nil)
        let parts = visited.withLock { $0 }
        for part in ["/up", "/a", "/a/b", "/real", "/real/bin", "/real/bin/tool"] {
            #expect(parts.contains(root + part), "\(part): \(parts)")
        }
        #expect(CommandTrust.changeablePart(of: root + "/up/bin/tool") { part, _ in part == root + "/real" } == root + "/real")

        // A chain of links as long as the limit is followed; one more and the walk stops there, refusing the tool.
        func chain(_ name: String, links: Int) throws -> String {
            var next = root + "/real"
            for index in (0..<links).reversed() {
                let link = root + "/\(name)\(index)"
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: next)
                next = link
            }
            return next + "/bin/tool"
        }
        #expect(CommandTrust.changeablePart(of: try chain("ok", links: CommandTrust.symlinkLimit)) { _, _ in false } == nil)
        let tooLong = try chain("long", links: CommandTrust.symlinkLimit + 1)
        #expect(CommandTrust.changeablePart(of: tooLong) { _, _ in false } != nil)
    }

    @Test("A script started by an env other than /usr/bin/env is refused: its options aren't known")
    func otherEnv() throws {
        let tree = try TempTree()
        try program(tree, "bin/env")
        let script = try program(tree, "bin/tool", "#!\(tree.path("bin/env")) node\n")
        let refusal = CommandTrust.programWalkRefusal("tool", at: script, locate: { _ in nil }, judge: { _ in nil })
        #expect(refusal?.contains("for an env other than /usr/bin/env") == true, "\(refusal ?? "")")
        // The system's own env is followed to the program it starts.
        let system = try program(tree, "bin/system", "#!/usr/bin/env node\n")
        let node = try program(tree, "bin/node")
        #expect(CommandTrust.programWalkRefusal("system", at: system, locate: { $0 == "node" ? node : nil }, judge: { _ in nil }) == nil)
    }

    /// A tool that starts a helper by name, or a script `/usr/bin/env` starts, searches the PATH it is given. In an
    /// automatic run that PATH holds only folders nothing of yours can change, so no program of yours is found first.
    @Test("An automatic run's PATH holds only search folders you can't change; a manual run's holds them all")
    func automaticSearchPath() throws {
        let tree = try TempTree()
        try tree.directory("bin")
        try tree.directory("home/.local/bin")
        let home = tree.path("home")
        let parent = ["PATH": "\(tree.path("bin")):/usr/bin:/bin", "HOME": home]
        func folders(_ environment: [String: String]) -> [String] {
            (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        }
        // The file system as it is: the test's folders are yours, /usr/bin and /bin the system's.
        let automatic = folders(Shell.toolEnvironment(from: parent, home: home, kind: .automatic))
        #expect(automatic.contains("/usr/bin") && automatic.contains("/bin"))
        #expect(!automatic.contains { $0.hasPrefix(tree.root) }, "\(automatic)")
        // With a stand-in judge, the folders it calls changeable go, whoever owns them.
        let judged = folders(Shell.toolEnvironment(from: parent, home: home, kind: .automatic) { $0 == "/usr/bin" ? $0 : nil })
        #expect(!judged.contains("/usr/bin") && judged.contains(tree.path("bin")) && judged.contains(home + "/.local/bin"))
        // You start a manual run yourself: it searches everywhere it did.
        let manual = folders(Shell.toolEnvironment(from: parent, home: home))
        #expect(manual.contains(tree.path("bin")) && manual.contains(home + "/.local/bin") && manual.contains("/usr/bin"))
    }

    /// Built-in rules' trusted tools skip the launcher-name check (`npm` is a script `node` runs), but not this one: a
    /// script runs its interpreter, which must be no more yours to change than the script.
    @Test("A trusted tool that is a script runs automatically only when its interpreter is one you can't change")
    func automaticScriptInterpreters() throws {
        let tree = try TempTree()
        try program(tree, "fixed/npm", "#!/usr/bin/env node\n")
        try program(tree, "fixed/go", "#!\(tree.path("mine/interpreter")) -q\n")
        try program(tree, "fixed/uv", "#!/usr/bin/env -S fixed-interpreter --quiet\n")
        try program(tree, "fixed/fixed-interpreter")
        try program(tree, "mine/node")
        try program(tree, "mine/interpreter")
        let mine = tree.path("mine")
        // Stands in for the system: `fixed` is a folder you can't change, `mine` one you can.
        let changeable: @Sendable (String) -> String? = { $0.hasPrefix(mine) ? mine : nil }
        let commands = [["npm", "cache", "clean", "--force"], ["go", "clean", "-cache"], ["uv", "cache", "clean"]]
        let rules = commands.map { rule($0[0], builtin: true, command: $0) }
        let plan = CleanupPlan(commands: commands.map { PlannedCommand(ruleID: $0[0], arguments: $0, estimatedBytes: 1) })
        let runner = RecordingRunner(searchPath: [tree.path("fixed"), mine, "/usr/bin", "/bin"])
        let executor = executor(tree, rules: rules, runner: runner, changeable: changeable)

        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        let reasons = report.commands.map { skipReason($0.outcome) ?? "ran" }
        // env looks for node on the automatic run's PATH, which leaves your folder out.
        #expect(reasons[0].contains("for 'node', which isn't installed where env looks"), "\(reasons[0])")
        #expect(reasons[1].contains("\(mine) can be replaced by any program of yours, so 'interpreter' runs only when you start it"))
        #expect(reasons[2] == "ran")
        #expect(runner.calls == [["uv", "cache", "clean"]])

        // By hand you start them yourself, interpreters and all.
        let manual = manualRun(plan, with: executor)
        #expect(manual.commands.allSatisfy { skipReason($0.outcome) == nil })
        #expect(runner.calls.suffix(3) == commands[...])
    }

    /// Any program of yours can write your tools' settings files, and nobody watches an automatic run. So its tools get
    /// settings SpaceKit chooses instead: Docker an empty folder only root can change (no contexts, plugins or credential
    /// helpers of yours), Go no env file and no other toolchain, npm and uv no config files.
    @Test("An automatic run's tools leave your own Docker, Go, npm, uv and xcrun settings behind; a manual run's keep them")
    func automaticIsolation() {
        let parent = [
            "PATH": "/usr/bin", "HOME": "/Users/tester", "DOCKER_CONFIG": "/Users/tester/.docker-elsewhere",
            "GOENV": "/Users/tester/go.env", "GOFLAGS": "-modcacherw", "GOTOOLCHAIN": "go1.99.0",
            "NPM_CONFIG_USERCONFIG": "/Users/tester/.npmrc-elsewhere", "npm_config_globalconfig": "/Users/tester/npmrc",
            "UV_CONFIG_FILE": "/Users/tester/uv.toml", "xcrun_nocache": "0", "npm_config_cache": "/Users/tester/.npm-elsewhere",
        ]
        let automatic = Shell.toolEnvironment(from: parent, home: "/Users/tester", kind: .automatic)
        let isolated = [
            "DOCKER_CONFIG": "/var/empty", "GOENV": "off", "GOTOOLCHAIN": "local", "NPM_CONFIG_USERCONFIG": "/dev/null",
            "NPM_CONFIG_GLOBALCONFIG": "/dev/null", "UV_NO_CONFIG": "1", "xcrun_nocache": "1",
        ]
        #expect(Shell.isolationVariables == isolated)
        for (name, value) in isolated { #expect(automatic[name] == value, "\(name)") }
        for name in ["GOFLAGS", "npm_config_globalconfig", "UV_CONFIG_FILE", "npm_config_cache"] {
            #expect(automatic[name] == nil, "\(name)")
        }

        let manual = Shell.toolEnvironment(from: parent, home: "/Users/tester")
        for name in isolated.keys { #expect(manual[name] == nil, "\(name)") }
        #expect(manual["npm_config_cache"] == "/Users/tester/.npm-elsewhere")
    }

    /// A whole rule's command cleans its folders by the tool's own lights, so a symlink on the way would have it clean
    /// wherever the link leads, with nobody watching.
    @Test("A whole rule's command doesn't run automatically when a folder on the way to the rule's paths is a symlink")
    func symlinkedRulePaths() throws {
        let tree = try TempTree()
        try tree.directory("home/fixed/go-build")
        try tree.directory("home/Documents/go-build")
        try tree.directory("home/Documents/data")
        try tree.directory("home/tools/real/data")
        try FileManager.default.createSymbolicLink(atPath: tree.path("home/cache"), withDestinationPath: tree.path("home/Documents"))
        try FileManager.default.createSymbolicLink(atPath: tree.path("home/tools/linked"), withDestinationPath: tree.path("home/Documents"))
        let cases: [(paths: [String], linked: String?)] = [
            (["~/fixed/go-build"], nil), (["~/cache/go-build"], "~/cache"), (["~/fixed/go-build", "~/tools/*/data"], "~/tools/linked"),
            // Outside the home folder, the system's own links (/tmp) are on the way to everything.
            (["/tmp/spacekit-no-such-cache"], nil),
        ]
        let command = ["go", "clean", "-cache"]
        for (paths, linked) in cases {
            let rules = [rule("go", builtin: true, command: command, paths: paths)]
            let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "go", arguments: command, estimatedBytes: 1)])
            let runner = RecordingRunner(installed: ["go"], in: tree)
            let executor = executor(tree, rules: rules, runner: runner)
            let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
            let reason = skipReason(report.commands.first?.outcome)
            if let linked {
                let expected = "\(linked), on the way to a folder rule go cleans, is a symlink"
                #expect(reason?.contains(expected) == true, "\(paths): \(reason ?? "ran")")
                #expect(runner.calls.isEmpty)
                // By hand, the person reviews the command and starts it.
                #expect(manualRun(plan, with: executor).commands.first?.outcome.isRemoved == true)
            } else {
                #expect(reason == nil, "\(paths): \(reason ?? "")")
            }
        }
    }

    /// HOME decides where each tool's default cache is, the folder it cleans, and any process of the person's can set
    /// the agent's variables. So an automatic run's tool gets SpaceKit's own home and the system's temporary folder.
    @Test("An automatic run's HOME and TMPDIR come from SpaceKit, never from the environment it was started with")
    func automaticHomeAndTemporaryFolder() throws {
        let parent = ["PATH": "/usr/bin", "HOME": "/Users/planted", "TMPDIR": "/Users/planted/tmp/", "USER": "tester"]
        let automatic = Shell.toolEnvironment(from: parent, home: "/Users/tester", kind: .automatic)
        let temporary = try #require(Shell.userTemporaryFolder)
        #expect(automatic["HOME"] == "/Users/tester")
        #expect(automatic["TMPDIR"] == temporary && temporary.hasPrefix("/") && !temporary.contains("planted"))
        #expect(automatic["USER"] == "tester")
        // A person starts a manual run, and its tool cleans the cache SpaceKit measured with their own variables.
        let manual = Shell.toolEnvironment(from: parent, home: "/Users/tester")
        #expect(manual["HOME"] == "/Users/planted" && manual["TMPDIR"] == "/Users/planted/tmp/")
        // The home SpaceKit runs with is the password database's, whatever the environment says.
        #expect(PathUtil.resolveHome(environment: ["HOME": "/Users/planted"], honorsOverride: false) == PathUtil.accountHome)
    }

    @Test("The real runner starts an automatic run's tool in the root folder, with the isolation variables")
    func realRunnerIsolates() {
        let automatic = Shell.run("/bin/pwd", [], timeout: 10, environment: [:], kind: .automatic)
        #expect(automatic.output == "/\n")
        let environment = Shell.run("/usr/bin/env", [], timeout: 10, environment: ["GOENV": "/x"], kind: .automatic)
        #expect(environment.output.split(separator: "\n").contains("GOENV=off"))
    }

    /// A new built-in rule's tool needs a decision: what SpaceKit leaves behind for it, or that automatic runs refuse it.
    @Test("Every built-in rule's tool is either isolated for automatic runs or refused in them")
    func builtinToolsClassified() {
        let library = RuleLibrary.load(builtin: .embedded)
        var tools = Set<String>()
        for rule in library.rules where rule.isBuiltin {
            for command in [rule.action.command, rule.action.itemCommand, rule.ai?.removeCommand].compactMap({ $0 }) {
                tools.insert(command.first ?? "")
            }
        }
        #expect(tools.count > 10)
        for tool in tools {
            #expect(CommandTrust.isolatedTools.contains(tool) != (CommandTrust.unisolatedTools[tool] != nil), "\(tool)")
        }
        #expect(CommandTrust.isolatedTools.isDisjoint(with: CommandTrust.unisolatedTools.keys))
    }

    /// Homebrew, CocoaPods, pnpm, bun and conda read settings no variable leaves behind, which decide what they delete
    /// or which code they load; a tool SpaceKit hasn't looked at is refused too.
    @Test("Tools whose own settings can't be left behind run by hand only")
    func unisolatedToolsRunByHand() throws {
        let tree = try TempTree()
        let commands = [
            ["brew", "cleanup"], ["pod", "cache", "clean", "--all"], ["cargo", "cache", "--autoclean"], ["go", "clean", "-cache"],
        ]
        let rules = commands.map { rule($0[0], builtin: true, command: $0) }
        let plan = CleanupPlan(commands: commands.map { PlannedCommand(ruleID: $0[0], arguments: $0, estimatedBytes: 1) })
        let runner = RecordingRunner(installed: Set(commands.map { $0[0] }), in: tree)
        let executor = executor(tree, rules: rules, runner: runner)
        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        let reasons = report.commands.map { skipReason($0.outcome) ?? "ran" }
        #expect(reasons[0].contains("~/.homebrew/brew.env") && reasons[0].hasSuffix("so 'brew' runs only when you start it"))
        #expect(reasons[1].contains("~/.cocoapods"))
        #expect(reasons[2].contains("SpaceKit hasn't checked which settings of yours 'cargo' reads"))
        #expect(reasons[3] == "ran")
        #expect(runner.calls == [["go", "clean", "-cache"]])
        #expect(manualRun(plan, with: executor).commands.allSatisfy { skipReason($0.outcome) == nil })
    }

    /// xcrun starts developer tools from the folder `xcode-select` chose, and looks elsewhere for one that folder lacks;
    /// Docker loads plugins from system folders, and reads its settings from the empty folder an automatic run hands it.
    /// Each must be one you can't change.
    @Test("xcrun's developer folder and tool, Docker's plugin folders and the empty settings folder must be ones you can't change")
    func toolFolders() throws {
        let tree = try TempTree()
        try program(tree, "Xcode/Developer/usr/bin/simctl")
        try tree.directory("CommandLineTools/usr/bin")
        let xcode = tree.path("xcode_select_link")
        let commandLineTools = tree.path("clt_link")
        try FileManager.default.createSymbolicLink(atPath: xcode, withDestinationPath: tree.path("Xcode/Developer"))
        try FileManager.default.createSymbolicLink(atPath: commandLineTools, withDestinationPath: tree.path("CommandLineTools"))
        let commands = [["xcrun", "simctl", "delete", "unavailable"], ["docker", "image", "prune", "--all", "--force"]]
        let rules = commands.map { rule($0[0], builtin: true, command: $0) }
        let plan = CleanupPlan(commands: commands.map { PlannedCommand(ruleID: $0[0], arguments: $0, estimatedBytes: 1) })
        let docker = ScriptedDocker()
        func reasons(developer: String = xcode, changeable: @escaping @Sendable (String) -> String?) -> [String] {
            let runner = RecordingRunner(installed: ["xcrun", "docker"], in: tree, respond: docker.respond)
            var executor = executor(tree, rules: rules, runner: runner, changeable: changeable)
            executor.developerFolderLink = developer
            let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
            return report.commands.map { skipReason($0.outcome) ?? "ran" }
        }
        #expect(reasons { _ in nil } == ["ran", "ran"])
        let xcodeFolder = tree.path("Xcode")
        let developer = reasons { $0 == xcode + "/usr/bin" ? xcodeFolder : nil }
        #expect(developer[0].contains("xcrun starts developer tools from") && developer[0].contains(xcodeFolder), "\(developer)")
        let simctl = reasons { $0 == xcode + "/usr/bin/simctl" ? $0 : nil }
        #expect(simctl[0].contains("xcrun would start \(xcode)/usr/bin/simctl"), "\(simctl)")
        // The Command Line Tools have no simulators: xcrun would look for simctl on the PATH instead.
        let withoutSimctl = reasons(developer: commandLineTools) { _ in nil }
        #expect(withoutSimctl[0].contains("has no 'simctl'") && withoutSimctl[0].hasSuffix("so 'xcrun' runs only when you start it"))
        let unselected = reasons(developer: tree.path("no-such-link")) { _ in nil }
        #expect(unselected[0].contains("\(tree.path("no-such-link")) is missing") && !unselected[0].contains("replaced"), "\(unselected)")
        // /usr/lib is on every Mac; /usr/lib/docker isn't, so its nearest folder decides who could create it.
        let plugins = reasons { $0 == "/usr/lib" ? "/usr/lib" : nil }
        #expect(plugins[1].contains("/usr/lib/docker/cli-plugins") && plugins[1].hasSuffix("so 'docker' runs only when you start it"))
        let settings = reasons { $0 == Shell.emptyFolder ? Shell.emptyFolder : nil }
        #expect(settings[1].contains("empty folder \(Shell.emptyFolder)"), "\(settings)")
    }

    @Test("A Docker plugin folder holding a plugin you can change keeps docker out of automatic runs")
    func changeableDockerPlugin() throws {
        let tree = try TempTree()
        try program(tree, "plugins/docker-buildx")
        let plugin = tree.path("plugins/docker-buildx")
        let folders = [tree.path("plugins")]
        #expect(CommandTrust.dockerFoldersRefusal(changeable: { _ in nil }, pluginFolders: folders) == nil)
        let refusal = CommandTrust.dockerFoldersRefusal(changeable: { $0 == plugin ? plugin : nil }, pluginFolders: folders)
        let expected = "docker loads plugins from \(tree.path("plugins")), and \(plugin) can be changed"
        #expect(refusal?.contains(expected) == true, "\(refusal ?? "")")
    }
}
