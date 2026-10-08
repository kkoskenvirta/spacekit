import Foundation

/// Everything a front end needs, wired up from the config. CLI, TUI, app and agent all start here.
public struct SpaceKitContext: Sendable {
    public var paths: SpaceKitPaths
    public var config: SpaceKitConfig
    public var library: RuleLibrary
    /// Set when the config file exists but couldn't be read. Read-only features use the defaults instead; the
    /// executor refuses every removal and command until the file is fixed.
    public var configError: String?

    public init(paths: SpaceKitPaths, config: SpaceKitConfig, library: RuleLibrary, configError: String? = nil) {
        self.paths = paths
        self.config = config
        self.library = library
        self.configError = configError
    }

    public static func load(paths: SpaceKitPaths = .standard) -> SpaceKitContext {
        var configError: String?
        let config: SpaceKitConfig
        do {
            config = try ConfigStore(file: paths.configFile).load()
        } catch {
            configError = error.localizedDescription
            config = SpaceKitConfig()
        }
        let directories = ruleDirectories(config: config, paths: paths)
        let library = RuleLibrary.load(directories: directories, disabled: Set(config.rules.disabled))
        return SpaceKitContext(paths: paths, config: config, library: library, configError: configError)
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

    public var safetyGuard: SafetyGuard {
        SafetyGuard(userProtectedPaths: config.safety.protectedPaths, protectedRules: library.rules, patternRoots: config.scan.devRoots)
    }

    public var executor: CleanupExecutor {
        CleanupExecutor(
            safety: safetyGuard, journal: journal, rules: library.rules,
            extraAllowedCommands: Set(config.safety.allowedCommands),
            maxBytesPerAutomaticRun: config.safety.maxBytesPerRun.bytes, configError: configError,
            alwaysTrash: config.safety.trashesEverything)
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
