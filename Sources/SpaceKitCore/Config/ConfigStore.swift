import Foundation
import Yams

public enum ConfigError: Error, LocalizedError {
    case invalid(file: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let file, let message): return "\(PathUtil.abbreviate(file)): \(message)"
        }
    }
}

/// Reads and writes the YAML config.
public struct ConfigStore: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    /// True if anything is at the config path, including a symlink whose target is missing.
    public var exists: Bool { linkStatus != nil }

    var isSymlink: Bool { linkStatus.map { ($0.st_mode & S_IFMT) == S_IFLNK } ?? false }

    /// The config path itself, not followed if it's a symlink. `nil` if nothing is there.
    private var linkStatus: stat? {
        var st = stat()
        return lstat(file, &st) == 0 ? st : nil
    }

    /// Loads the config. A missing file yields the defaults. A file (or symlink) that is there but can't be read is
    /// an error: the defaults would lack the person's protections.
    public func load() throws -> SpaceKitConfig {
        guard exists else { return SpaceKitConfig() }
        if let problem = FileTrust.problem(with: file) {
            throw ConfigError.invalid(file: file, message: "\(problem); SpaceKit only reads a config only you can change")
        }
        let text: String
        do {
            text = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            let reason = isSymlink ? "is a symlink to a file that is missing or can't be read" : "can't be read"
            throw ConfigError.invalid(file: file, message: "\(reason) (\(error.localizedDescription))")
        }
        do {
            return try ConfigStore.parse(text)
        } catch {
            throw ConfigError.invalid(file: file, message: DecodingErrorText.describe(error))
        }
    }

    public static func parse(_ yaml: String) throws -> SpaceKitConfig {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        // A file of only comments decodes as null; treat it as defaults.
        if trimmed.isEmpty || trimmed.split(separator: "\n").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            return SpaceKitConfig()
        }
        let config = try YAMLDecoder().decode(SpaceKitConfig.self, from: yaml)
        try validate(config)
        return config
    }

    /// Semantic checks beyond YAML syntax.
    public static func validate(_ config: SpaceKitConfig) throws {
        // An error, not a silent skip: the whole config fails closed, so the person sees why and nothing runs.
        if let problem = config.safety.allowedCommands.lazy.compactMap(CommandTrust.allowedCommandProblem).first {
            let path: [CodingKey] = [SpaceKitConfig.CodingKeys.safety, SafetySettings.CodingKeys.allowedCommands]
            throw DecodingError.dataCorrupted(
                .init(codingPath: path, debugDescription: problem + "; remove it, and list the cleanup tool itself by its own name"))
        }
        var ids = Set<String>()
        for job in config.jobs {
            guard ids.insert(job.id).inserted else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Duplicate job id '\(job.id)'"))
            }
            if job.rules.isEmpty && job.paths.isEmpty {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Job '\(job.id)' needs `rules` or `paths`"))
            }
        }
    }

    /// Saves the config, keeping the previous file as `config.yaml.bak`. Front ends call `SpaceKitContext.applying(_:)`
    /// instead, which applies one change to the file as it is now and never overwrites a file that doesn't parse.
    func save(_ config: SpaceKitConfig) throws {
        try ConfigStore.validate(config)
        let body = try YAMLEncoder().encode(config)
        let text = ConfigStore.savedHeader + body
        // The previous contents, not a copy of a symlink, which would show the new config once it's saved.
        if let previous = FileManager.default.contents(atPath: file) {
            try? LockedFile.write(previous, to: file + ".bak", like: file)
        }
        // An atomic write replaces the path, so a symlinked config (dotfiles) is written where the link points.
        let destination = isSymlink ? (PathUtil.realpath(file) ?? file) : file
        try LockedFile.write(Data(text.utf8), to: destination)
    }

    /// Writes the commented starter config if no config exists.
    @discardableResult
    public func initialize(force: Bool = false) throws -> Bool {
        guard force || !exists else { return false }
        if isSymlink {
            throw ConfigError.invalid(file: file, message: "is a symlink; edit or remove it yourself, SpaceKit won't replace it")
        }
        try LockedFile.write(Data(ConfigStore.template.utf8), to: file)
        return true
    }

    static let savedHeader = """
        # SpaceKit configuration — see docs/CONFIGURATION.md
        # This file was last written by SpaceKit. Your previous version is in config.yaml.bak.

        """

    /// The documented starter configuration written by `spacekit config init`.
    public static let template = """
        # SpaceKit configuration
        # Docs: docs/CONFIGURATION.md · Validate with: spacekit config validate
        #
        # Every key is optional. Sizes accept 500MB / 30GB / 1.5TB; ages accept 14d / 2w / 3mo / 1y.
        version: 1

        scan:
          defaultPath: /            # what Explore scans (/ = the whole startup disk, hidden folders included)
          minFileSize: 1MB          # smaller files are summarised per folder (keeps big scans fast and light)
          boundary: container       # device | container | unrestricted
          devRoots: [~]             # where to look for node_modules, target/, __pycache__, …
          exclude: []               # paths or globs never scanned, e.g. ~/VirtualMachines

        safety:
          trash: always             # always = move to Trash; rules = regenerable caches may be deleted directly
          maxBytesPerRun: 100GB     # an automatic run never removes more than this
          protectedPaths: []        # your own never-touch list, e.g. [~/Work/client-archive]
          allowedCommands: []       # tools your own rules may run, by hand only; no shells or interpreters

        rules:
          disabled: []              # rule ids to ignore, e.g. [node.node-modules]
          directories: [~/.config/spacekit/rules]   # your own rule files (same format as the built-in library)

        automation:
          notifications: true       # for observe and suggest jobs; automatic runs that clean always notify
          checkEvery: 1h            # how often the background agent looks for due jobs (5m to 24h)
          snapshot: sunday 04:00    # full storage snapshot for History ("what grew?"); or: never
          activeModelWindow: 90d    # AI models used within this window count as active

        # Jobs: observe = notify me · suggest = prepare a cleanup and ask · automatic = clean (safe items only)
        jobs:
          - id: xcode-derived-data
            name: Xcode DerivedData
            rules: [xcode.derived-data]
            mode: automatic
            schedule: sunday 03:00
            when:
              sizeAbove: 30GB
              keepRecent: 14d       # keep projects used within 14 days

          - id: stale-node-modules
            name: node_modules
            rules: [node.node-modules]
            mode: suggest
            schedule: weekly
            when:
              olderThan: 60d        # projects untouched for 60 days

          - id: package-caches
            name: npm / pnpm / Homebrew caches
            rules: [node.npm-cache, node.pnpm-store, homebrew.cache]
            mode: suggest
            schedule: monthly

        ui:
          visualization: sunburst   # sunburst | treemap
          colorBy: branch           # branch | category | safety | age
          mapDepth: 4

        """
}
