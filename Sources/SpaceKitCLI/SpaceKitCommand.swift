import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

@main
struct SpaceKitCommand: ParsableCommand {
    static let version = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "spacekit",
        abstract: "Understand your Mac. Automate the cleanup.",
        discussion: """
            Explore where disk space goes, see what developer and AI storage is safe to remove, and schedule cleanups.

            Start with:
              spacekit tui                 full-screen explorer
              spacekit dev                 what's safe to remove (Dev Intelligence)
              spacekit scan ~ --depth 2    largest folders
              spacekit clean <rule>        preview a cleanup (add --yes to run it)

            Nothing is removed without a preview, and every removal passes the safety guard (docs/SAFETY.md).
            """,
        version: version,
        subcommands: [
            TUICommand.self, ScanCommand.self, DiskCommand.self, DevCommand.self, AICommand.self, CleanCommand.self,
            RulesCommand.self, JobsCommand.self, SuggestionsCommand.self, AgentCommand.self, HistoryCommand.self,
            JournalCommand.self, TrashCommand.self, ConfigCommand.self, DoctorCommand.self,
        ]
    )
}

/// Options shared by commands that load the SpaceKit context.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Config file (default: ~/.config/spacekit/config.yaml or $SPACEKIT_CONFIG).")
    var config: String?

    /// Where config and state live. The config path is absolute, so a launch agent installed with it finds it too.
    var paths: SpaceKitPaths {
        var paths = SpaceKitPaths.standard
        if let config { paths.configFile = PathUtil.expandArgument(config) }
        return paths
    }

    func loadContext() -> SpaceKitContext {
        let context = SpaceKitContext.load(paths: paths)
        if let error = context.configError {
            Output.warn(
                Output.safe("Config not loaded, using defaults: \(error)")
                    + ". Nothing will be removed until it's fixed (spacekit config validate).")
        }
        return context
    }
}

struct TUICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Full-screen terminal interface: explore, Dev Intelligence, AI, automation and history.",
        aliases: ["explore", "ui"]
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Folder or volume to explore (default: scan.defaultPath, normally /).")
    var path: String?

    func run() throws {
        guard Terminal.isInteractive else {
            throw ValidationError("The TUI needs an interactive terminal. Try `spacekit scan` for plain output.")
        }
        TUIApp(context: global.loadContext(), path: path).run()
    }
}
