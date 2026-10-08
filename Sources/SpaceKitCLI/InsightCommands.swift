import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI
import Yams

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "How your disk usage changed over time, and what grew.",
        subcommands: [Show.self, Snapshot.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Usage over time and what grew.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Days to show.") var days: Int = 90
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func validate() throws {
            guard days >= 1 else { throw ValidationError("--days must be 1 or more") }
        }

        func run() throws {
            let context = global.loadContext()
            let history = context.history
            if json {
                try Output.json(history.records(since: Age.days(Double(days)).ago()))
                return
            }
            let daily = history.dailyUsage(days: days)
            print("YOUR DISK".bold)
            guard daily.count >= 2 else {
                print("Not enough history yet. The agent records usage every few hours (`spacekit agent install`);".dim)
                print("`spacekit history snapshot` records a full breakdown now.".dim)
                return
            }
            let values = daily.map { Double($0.used) }
            print(ByteCount.format(daily.last!.total).dim + " total")
            print(ANSI.sparkline(values).fg(ANSI.accent) + "  " + ByteCount.format(daily.last!.used).bold + " used")
            print(
                daily.first!.date.formatted(.dateTime.month(.abbreviated).day()).dim + " → "
                    + daily.last!.date.formatted(.dateTime.month(.abbreviated).day()).dim)
            print()
            if let month = history.usedDelta(over: .days(30)) {
                print((ByteCount.formatDelta(month) + " this month").bold.fg(month > 0 ? ANSI.review : ANSI.safe))
            }
            let grew = history.whatGrew(over: .days(Double(days)))
            if !grew.isEmpty {
                print()
                print("WHAT GREW?".bold)
                for item in grew { print(item.terminalLine) }
            }
        }
    }

    struct Snapshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record a full storage breakdown now.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            let analysis = try ProgressReporter.run("Analysing") { try context.analyzer.analyzeSync(progress: $0) }
            try context.history.recordSnapshot(analysis: analysis)
            print(
                "Snapshot recorded: \(analysis.groups.count) groups, \(ByteCount.format(analysis.findings.reduce(0) { $0 + $1.size })) recognised."
            )
        }
    }
}

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal", abstract: "Everything SpaceKit removed, and how much it recovered.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Days to show.") var days: Int = 90
    @Flag(name: .long, help: "Machine-readable output.") var json = false

    func validate() throws {
        guard days >= 1 else { throw ValidationError("--days must be 1 or more") }
    }

    func run() throws {
        let context = global.loadContext()
        let since = Age.days(Double(days)).ago()
        let entries = context.journal.entries(since: since)
        if json {
            try Output.json(entries)
            return
        }
        print(
            "Your Mac has recovered " + ByteCount.format(context.journal.recovered(since: since)).bold.fg(ANSI.safe)
                + " over the last \(days) days.")
        print()
        for entry in entries.suffix(50) {
            let how = entry.automatic ? "auto" : "manual"
            print(
                entry.date.formatted(date: .abbreviated, time: .shortened).dim + "  " + Output.size(entry.bytes) + "  "
                    + ANSI.pad(entry.method.rawValue, to: 7).dim + ANSI.pad(how, to: 7).dim + Output.path(entry.path))
        }
        if entries.count > 50 { print("… \(entries.count - 50) earlier entries (use --json for all)".dim) }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Create, show, validate and edit the YAML config.",
        subcommands: [Path.self, Init.self, Show.self, Validate.self, Edit.self],
        defaultSubcommand: Show.self
    )

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print config and state locations.")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let paths = global.paths
            print("config: \(Output.safe(paths.configFile))")
            print("rules:  \(Output.safe(paths.userRulesDirectory))")
            print("state:  \(Output.safe(paths.stateDirectory))")
        }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a commented starter config.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Overwrite an existing config.") var force = false
        func run() throws {
            let context = global.loadContext()
            if try context.configStore.initialize(force: force) {
                print("Wrote \(Output.path(context.paths.configFile)). Edit it, then check with `spacekit config validate`.")
            } else {
                print("\(Output.path(context.paths.configFile)) already exists (use --force to replace it).")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the effective config (defaults filled in).")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Machine-readable output.") var json = false
        func run() throws {
            let context = global.loadContext()
            if json {
                try Output.json(context.config)
                return
            }
            print(
                "# \(Output.path(context.paths.configFile))\(context.configStore.exists ? "" : " (not created yet — showing defaults)")"
                    .dim)
            print(Output.safeLines(try YAMLEncoder().encode(context.config)))
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check a config file for mistakes.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "File to check (default: your config).") var file: String?
        func run() throws {
            var paths = global.paths
            if let file { paths.configFile = PathUtil.expandArgument(file) }
            // A symlink to a missing file is there (and invalid), not absent.
            guard ConfigStore(file: paths.configFile).exists else {
                throw ValidationError("No config at \(Output.safe(paths.configFile)). Create one with `spacekit config init`.")
            }
            // Load it the way every command would, so its own rule folders and disabled rules apply.
            let context = SpaceKitContext.load(paths: paths)
            if let error = context.configError {
                print("✗ ".fg(ANSI.protected) + Output.safe(error))
                throw ExitCode.failure
            }
            var problems = 0
            for job in context.config.jobs {
                for id in job.rules where context.library.rule(id: id) == nil {
                    print("job \(Output.safe(job.id)): unknown or disabled rule '\(Output.safe(id))'".fg(ANSI.protected))
                    problems += 1
                }
            }
            if problems > 0 { throw ExitCode.failure }
            let count = context.config.jobs.count
            print("✓ ".fg(ANSI.safe) + "\(Output.path(paths.configFile)) is valid: \(count) job\(count == 1 ? "" : "s").")
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the config in $VISUAL or $EDITOR (creating it first if needed).")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let paths = global.paths
            try ConfigStore(file: paths.configFile).initialize()
            let environment = ProcessInfo.processInfo.environment
            let setting = [environment["VISUAL"], environment["EDITOR"]].compactMap { $0 }.first { !$0.isEmpty } ?? "nano"
            // `code --wait` is a command and an argument; split it the way a shell would, without running one.
            guard let editor = ShellWords.split(setting), !editor.isEmpty else {
                throw ValidationError("Can't read the editor command '\(Output.safe(setting))'. Check $VISUAL / $EDITOR.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = editor + [paths.configFile]
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                print("✗ ".fg(ANSI.protected) + "The editor (\(Output.safe(setting))) exited with status \(process.terminationStatus).")
                throw ExitCode.failure
            }
            do {
                _ = try ConfigStore(file: paths.configFile).load()
                print("✓ ".fg(ANSI.safe) + "Config is valid.")
            } catch {
                print("✗ ".fg(ANSI.protected) + Output.safe(error.localizedDescription))
                throw ExitCode.failure
            }
        }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check permissions, config, rules and the background agent.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Machine-readable output.") var json = false

    struct Check: Encodable {
        var check: String
        var ok: Bool
        var detail: String
    }

    func run() throws {
        let context = global.loadContext()
        if json {
            try Output.json(checks(context))
            return
        }
        for check in checks(context) {
            let detail = check.detail.isEmpty ? "" : "  " + Output.safe(check.detail).dim
            print((check.ok ? "✓ ".fg(ANSI.safe) : "! ".fg(ANSI.review)) + check.check + detail)
        }
    }

    private func checks(_ context: SpaceKitContext) -> [Check] {
        var checks: [Check] = []
        let fda = FullDiskAccess.isGranted
        checks.append(
            Check(
                check: "Full Disk Access", ok: fda,
                detail: fda ? "" : "System Settings → Privacy & Security → Full Disk Access → add your terminal app (and the agent)"))
        checks.append(
            Check(
                check: "Config", ok: context.configError == nil,
                detail: context.configError.map { "\($0) — cleaning is refused until it's fixed" }
                    ?? (context.configStore.exists
                        ? PathUtil.abbreviate(context.paths.configFile) : "not created (defaults) — `spacekit config init`")))
        let errors = context.library.issues.filter { $0.severity == .error }
        checks.append(
            Check(
                check: "Rules", ok: errors.isEmpty,
                detail: "\(context.library.rules.count) loaded from "
                    + (RuleLibrary.builtinDirectory.map { PathUtil.abbreviate($0) } ?? "nowhere")
                    + (errors.isEmpty ? "" : ", \(errors.count) errors (spacekit rules validate)")))
        let agent = LaunchAgent(paths: context.paths).status()
        checks.append(
            Check(
                check: "Background agent", ok: agent.loaded, detail: agent.loaded ? "running" : "not running — `spacekit agent install`"))
        checks.append(
            Check(
                check: "Not running as root", ok: geteuid() != 0, detail: geteuid() == 0 ? "SpaceKit refuses to remove files as root" : ""))
        checks.append(
            Check(
                check: "Trash", ok: true,
                detail: context.config.safety.trashesEverything
                    ? "everything goes to the Trash" : "regenerable caches may be deleted directly"))
        if let capacity = VolumeCapacity.of(path: "/") {
            checks.append(
                Check(
                    check: "Startup disk", ok: capacity.fullness != .nearlyFull,
                    detail: "\(ByteCount.format(capacity.available)) available of \(ByteCount.format(capacity.total))"
                        + (capacity.purgeable > 0
                            ? " (\(ByteCount.format(capacity.freeNow)) free now, \(ByteCount.format(capacity.purgeable)) purgeable)" : "")))
        }
        return checks
    }
}
