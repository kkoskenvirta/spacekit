import Foundation

/// Everything a front end needs, wired up from the config. CLI, TUI, app and agent all start here.
///
/// A context is one consistent reading of the config file: its config, the rule library loaded for it, and the guard
/// and executor built from both, once. It never changes; a config change (`applying(_:)`) or a re-read
/// (`rereadingConfig()`) returns a new context, and a front end replaces its own with it.
public struct SpaceKitContext: Sendable {
    public let paths: SpaceKitPaths
    public let config: SpaceKitConfig
    public let library: RuleLibrary
    /// Set when the config file exists but couldn't be read. Read-only features use the defaults instead; the
    /// executor refuses every removal and command until the file is fixed.
    public let configError: String?
    public let safetyGuard: SafetyGuard
    /// Re-reads only the mount table on each run (see `CleanupExecutor.readMounts`).
    public let executor: CleanupExecutor

    public init(paths: SpaceKitPaths, config: SpaceKitConfig, library: RuleLibrary, configError: String? = nil) {
        self.paths = paths
        self.config = config
        self.library = library
        self.configError = configError
        safetyGuard = SafetyGuard(
            userProtectedPaths: config.safety.protectedPaths, protectedRules: library.rules, patternRoots: config.scan.devRoots)
        var executor = CleanupExecutor(
            safety: safetyGuard, journal: Journal(file: paths.journalFile), rules: library.rules,
            allowedCommands: Set(config.safety.allowedCommands),
            maxBytesPerAutomaticRun: config.safety.maxBytesPerRun.bytes, configError: configError,
            alwaysTrash: config.safety.trashesEverything)
        executor.readMounts = { VolumeTable.current() }
        self.executor = executor
    }

    public static func load(paths: SpaceKitPaths = .standard) -> SpaceKitContext {
        let (config, configError) = read(paths)
        return SpaceKitContext(paths: paths, config: config, library: library(for: config, paths: paths), configError: configError)
    }

    /// Applies one config change to the file as it is on disk now (`ConfigStore.update`, under the lock) and returns
    /// the context for what was saved. Validity is the file's now, not this context's: a file fixed since it was loaded
    /// is adopted, one that is invalid now throws its `ConfigError` and is never overwritten.
    public func applying(_ change: (inout SpaceKitConfig) throws -> Void) throws -> SpaceKitContext {
        adopting(try configStore.update(change), error: nil)
    }

    /// The context for the config file as it is on disk now, for edits made elsewhere (an editor, the CLI). An invalid
    /// file gives the defaults and a config error, as `load` does. Rule files themselves are re-read only by `load`.
    public func rereadingConfig() -> SpaceKitContext {
        let (config, configError) = SpaceKitContext.read(paths)
        return adopting(config, error: configError)
    }

    /// This context moved to `config`. The rule library is a function of the rule settings, so it is kept unless they
    /// changed; an unchanged config keeps the whole context.
    private func adopting(_ config: SpaceKitConfig, error: String?) -> SpaceKitContext {
        if config == self.config && error == configError { return self }
        let library = config.rules == self.config.rules ? library : SpaceKitContext.library(for: config, paths: paths)
        return SpaceKitContext(paths: paths, config: config, library: library, configError: error)
    }

    /// What a front end that labels folders and findings with rules redoes after replacing its context.
    public struct Relabelling: Sendable, Equatable {
        /// The rule settings changed, so the library was reloaded: findings take its rules (`Workspace.reindex`).
        public let reindex: Bool
        /// The rules or the developer roots changed: the labels Explore shows (`ruleIndex`) are built again.
        public let rebuildIndex: Bool

        public init(reindex: Bool, rebuildIndex: Bool) {
            self.reindex = reindex
            self.rebuildIndex = rebuildIndex
        }
    }

    /// What changed for rule labels since `previous`, the context this one replaces.
    public func relabelling(since previous: SpaceKitContext) -> Relabelling {
        let rules = config.rules != previous.config.rules
        return Relabelling(reindex: rules, rebuildIndex: rules || config.scan.devRoots != previous.config.scan.devRoots)
    }

    /// The config file's config, or the defaults and why it couldn't be read.
    private static func read(_ paths: SpaceKitPaths) -> (SpaceKitConfig, String?) {
        do {
            return (try ConfigStore(file: paths.configFile).load(), nil)
        } catch {
            return (SpaceKitConfig(), error.localizedDescription)
        }
    }

    private static func library(for config: SpaceKitConfig, paths: SpaceKitPaths) -> RuleLibrary {
        RuleLibrary.load(directories: ruleDirectories(config: config, paths: paths), disabled: Set(config.rules.disabled))
    }

    /// Where user rules load from: `rules.directories`, plus the standard rules folder if it isn't listed.
    public var ruleDirectories: [String] { SpaceKitContext.ruleDirectories(config: config, paths: paths) }

    static func ruleDirectories(config: SpaceKitConfig, paths: SpaceKitPaths) -> [String] {
        var directories = config.rules.directories.map { PathUtil.expand($0) }
        if !directories.contains(paths.userRulesDirectory) { directories.append(paths.userRulesDirectory) }
        return directories
    }

    public var configStore: ConfigStore { ConfigStore(file: paths.configFile) }
    public var journal: Journal { Journal(file: paths.journalFile) }
    public var history: HistoryStore { HistoryStore(file: paths.historyFile) }
    public var jobStates: JobStateStore { JobStateStore(file: paths.jobStateFile) }
    public var suggestions: SuggestionStore { SuggestionStore(file: paths.suggestionsFile) }

    public var scanOptions: ScanOptions { config.scan.options(markers: library.markerRegistry) }

    public var analyzer: StorageAnalyzer {
        StorageAnalyzer(library: library, scanOptions: scanOptions, devRoots: config.scan.devRoots)
    }

    /// `true` to force the Trash, `nil` to follow rules.
    public func trashPreference(for action: Job.Action = .trash) -> Bool? {
        if config.safety.trashesEverything { return true }
        switch action {
        case .trash: return true
        case .delete: return false
        case .rule: return nil
        }
    }
}
