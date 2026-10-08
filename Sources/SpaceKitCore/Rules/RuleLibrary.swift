import Foundation
import Yams

/// A problem found while loading or validating rules.
public struct RuleIssue: Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var source: String
    public var ruleID: String?
    public var message: String

    public init(severity: Severity, source: String, ruleID: String? = nil, message: String) {
        self.severity = severity
        self.source = source
        self.ruleID = ruleID
        self.message = message
    }

    public var description: String {
        let location = ruleID.map { "\(PathUtil.abbreviate(source)) [\($0)]" } ?? PathUtil.abbreviate(source)
        return "\(severity.rawValue): \(location): \(message)"
    }
}

/// The set of known storage rules: SpaceKit's built-in library plus the user's own rule files.
public struct RuleLibrary: Sendable {
    public private(set) var rules: [Rule]
    public private(set) var issues: [RuleIssue]

    public init(rules: [Rule], issues: [RuleIssue] = []) {
        self.rules = rules
        self.issues = issues
    }

    /// Executables that built-in rule commands may run without the user explicitly allowing them in the config.
    /// Rules from any other folder need their executable listed in `safety.allowedCommands`.
    public static let trustedCommands: Set<String> = [
        "brew", "docker", "xcrun", "npm", "pnpm", "yarn", "bun", "ollama", "go", "cargo", "pip", "pip3",
        "uv", "conda", "mamba", "gem", "pod", "flutter", "dart", "gradle", "huggingface-cli", "hf", "mise", "rustup",
        "orb", "podman", "colima", "swift", "deno",
    ]

    /// Loads the built-in rules and every `*.yaml` / `*.yml` in `directories`.
    ///
    /// A user rule with the id of an earlier rule replaces it, so a built-in rule can be customised by copying
    /// it, except that a built-in `protected` rule can't be replaced and a replacement can't have a lower safety
    /// level than the built-in rule. Rules with validation errors are reported in `issues` but not loaded, and
    /// `disabled` never turns off a `protected` rule.
    public static func load(
        builtinDirectory: String? = RuleLibrary.builtinDirectory,
        directories: [String] = [],
        disabled: Set<String> = []
    ) -> RuleLibrary {
        var byID: [String: Rule] = [:]
        var builtinByID: [String: Rule] = [:]
        var order: [String] = []
        var issues: [RuleIssue] = []

        let builtin = builtinDirectory.map(PathUtil.standardize)
        var sources: [(directory: String, isBuiltin: Bool)] = builtin.map { [($0, true)] } ?? []
        for directory in directories.map({ PathUtil.standardize(PathUtil.expand($0)) }) where directory != builtin {
            sources.append((directory, false))
        }

        let builtinOwners = FileTrust.builtinOwners()
        for (directory, isBuiltin) in sources {
            for file in yamlFiles(in: directory) {
                if let problem = FileTrust.problem(with: file, owners: isBuiltin ? builtinOwners : FileTrust.owners()) {
                    issues.append(RuleIssue(severity: .error, source: file, message: "not loaded: it \(problem)"))
                    continue
                }
                let parsed: [Rule]
                do {
                    parsed = try parse(yaml: try String(contentsOfFile: file, encoding: .utf8), source: file)
                } catch {
                    issues.append(RuleIssue(severity: .error, source: file, message: DecodingErrorText.describe(error)))
                    continue
                }
                for var rule in parsed {
                    rule.isBuiltin = isBuiltin
                    let ruleIssues = RuleLibrary.issues(for: rule)
                    issues += ruleIssues
                    if ruleIssues.contains(where: { $0.severity == .error }) { continue }
                    if let problem = builtinByID[rule.id].flatMap({ overrideProblem(builtin: $0, replacement: rule) }) {
                        issues.append(RuleIssue(severity: .error, source: file, ruleID: rule.id, message: problem))
                        continue
                    }
                    if let existing = byID[rule.id] {
                        let origin = PathUtil.abbreviate(existing.source ?? "<inline>")
                        issues.append(
                            RuleIssue(severity: .warning, source: file, ruleID: rule.id, message: "replaces the rule from \(origin)"))
                    } else {
                        order.append(rule.id)
                    }
                    byID[rule.id] = rule
                    if isBuiltin { builtinByID[rule.id] = rule }
                }
            }
        }

        var rules: [Rule] = []
        for rule in order.compactMap({ byID[$0] }) {
            if disabled.contains(rule.id) {
                guard rule.safety.level == .protected else { continue }
                issues.append(
                    RuleIssue(
                        severity: .warning, source: rule.source ?? "<inline>", ruleID: rule.id,
                        message: "protected rules can't be disabled; it stays active (rules.disabled)"))
            }
            rules.append(rule)
        }
        return RuleLibrary(rules: rules, issues: issues)
    }

    /// Why `replacement` may not take the place of the built-in rule with the same id, or `nil` if it may.
    static func overrideProblem(builtin: Rule, replacement: Rule) -> String? {
        if builtin.safety.level == .protected {
            return "can't replace the built-in protected rule with the same id; protected rules keep SpaceKit from touching that data"
        }
        if replacement.safety.level < builtin.safety.level {
            return "can't lower the safety level of the built-in rule from \(builtin.safety.level.rawValue) to "
                + "\(replacement.safety.level.rawValue); add it to rules.disabled to turn it off instead"
        }
        return nil
    }

    /// Where the built-in rule library lives, searched in this order:
    /// `$SPACEKIT_RULES_DIR`, the app bundle's `Resources/rules`, `<prefix>/share/spacekit/rules` next to
    /// the executable (Homebrew, `make install`), the bundle's resources when the CLI runs from
    /// `SpaceKit.app/Contents/Helpers`, a `rules` folder beside the executable, and, in debug builds only, the
    /// `rules/` folder of the source checkout the binary was built from.
    public static var builtinDirectory: String? {
        builtinCandidates().first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func builtinCandidates() -> [String] {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["SPACEKIT_RULES_DIR"], !env.isEmpty { candidates.append(env) }
        if let resources = Bundle.main.resourceURL?.path { candidates.append(resources + "/rules") }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent().path
        candidates.append(executable + "/../share/spacekit/rules")
        candidates.append(executable + "/../Resources/rules")  // SpaceKit.app/Contents/Helpers/spacekit
        candidates.append(executable + "/rules")
        // Rules found in the built-in directory get built-in trust (their commands may run trusted tools). A release
        // binary must not grant that to whatever sits at the path it was compiled from on some build machine.
        #if DEBUG
            candidates.append(sourceCheckoutRules)
        #endif
        return candidates.map(PathUtil.standardize)
    }

    /// Sources/SpaceKitCore/Rules/RuleLibrary.swift → <repo>/rules
    static var sourceCheckoutRules: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rules").path
    }

    static func yamlFiles(in directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if relative.hasSuffix(".yaml") || relative.hasSuffix(".yml") { files.append(directory + "/" + relative) }
        }
        return files.sorted()
    }

    /// Parses a rule file. A file is either a single rule (has `name` at the top level) or a list under `rules:`
    /// with optional file-wide `group` and `category` defaults.
    public static func parse(yaml: String, source: String = "<inline>") throws -> [Rule] {
        guard let node = try Yams.compose(yaml: yaml), let mapping = node.mapping else { return [] }
        let decoder = YAMLDecoder()
        var rules: [Rule]
        var defaultGroup = ""
        var defaultCategory = ""
        if mapping["rules"] != nil {
            let file = try decoder.decode(RuleFile.self, from: yaml)
            rules = file.rules
            defaultGroup = file.group ?? ""
            defaultCategory = file.category ?? ""
        } else {
            rules = [try decoder.decode(Rule.self, from: yaml)]
        }
        for index in rules.indices {
            if rules[index].group.isEmpty { rules[index].group = defaultGroup.isEmpty ? rules[index].name : defaultGroup }
            if rules[index].category.isEmpty { rules[index].category = defaultCategory.isEmpty ? "other" : defaultCategory }
            rules[index].source = source
        }
        return rules
    }

    private struct RuleFile: Decodable {
        var group: String?
        var category: String?
        var rules: [Rule]
    }

    // MARK: Lookup

    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }

    public func rules(inCategory prefix: String) -> [Rule] {
        rules.filter { $0.category == prefix || $0.category.hasPrefix(prefix + ".") }
    }

    /// Every marker name rules depend on, for `ScanOptions.markers`. `MarkerRegistry` drops repeats.
    public var markerNames: [String] {
        rules.flatMap { ($0.match?.sibling ?? []) + ($0.match?.contains ?? []) }
    }

    public var markerRegistry: MarkerRegistry { MarkerRegistry(names: markerNames) }

    // MARK: Validation

    /// Checks rules for mistakes that would make them useless or dangerous.
    public func validate() -> [RuleIssue] {
        var issues: [RuleIssue] = []
        var seen: [String: String] = [:]
        for rule in rules {
            let source = rule.source ?? "<inline>"
            if let other = seen[rule.id], other != source {
                issues.append(
                    RuleIssue(
                        severity: .warning, source: source, ruleID: rule.id,
                        message: "id also defined in \(PathUtil.abbreviate(other)); the later definition wins"))
            }
            seen[rule.id] = source
            issues += RuleLibrary.issues(for: rule)
        }
        return issues
    }

    /// Problems with one rule on its own. Any `error` keeps the rule out of the loaded library.
    static func issues(for rule: Rule, home: String = PathUtil.home) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        func issue(_ severity: RuleIssue.Severity, _ message: String) {
            issues.append(RuleIssue(severity: severity, source: rule.source ?? "<inline>", ruleID: rule.id, message: message))
        }
        if rule.paths.isEmpty && rule.match == nil {
            issue(.error, "needs either `path` or `match`")
        }
        if let match = rule.match, match.names.isEmpty {
            issue(.error, "`match.names` is empty")
        }
        for path in rule.paths {
            if !path.hasPrefix("/") && !path.hasPrefix("~") {
                issue(.error, "path '\(path)' must be absolute or start with ~")
            }
            if isTooBroad(path, home: home) {
                issue(.error, "path '\(path)' is too broad; rules may not target a volume root, a top-level folder or the home folder")
            }
        }
        if rule.safety.level == .protected && !rule.action.isEmpty {
            issue(.error, "protected rules identify data to keep; they can't have a cleanup action or manual steps")
        }
        for command in [rule.action.command, rule.action.itemCommand].compactMap({ $0 }) {
            commandIssues(command, rule: rule).forEach { issue($0.severity, $0.message) }
        }
        if rule.granularity == .children && rule.match != nil {
            issue(.warning, "`granularity: children` is unusual for pattern rules")
        }
        if let ai = rule.ai, !AISpec.layouts.contains(ai.layout) {
            let layouts = AISpec.layouts.sorted().joined(separator: ", ")
            issue(.warning, "unknown ai.layout '\(ai.layout)'; it is shown as a cache. Use one of \(layouts)")
        }
        if let command = rule.ai?.removeCommand {
            commandIssues(command, rule: rule).forEach { issue($0.severity, $0.message) }
            if command.contains(where: { $0.contains("{path}") }) {
                issue(.error, "ai.removeCommand names a model with {name}; {path} isn't available there")
            }
        }
        return issues
    }

    /// A path is too broad if it, or the folder its first glob component sits in, is the home folder, a volume
    /// root or a top-level folder: `~`, `/Users`, `~/*` and `~/Do*` all are.
    static func isTooBroad(_ path: String, home: String) -> Bool {
        let expanded = PathUtil.expand(path, home: home)
        let components = PathUtil.components(expanded)
        let literal = components.prefix { !PathUtil.isGlob(String($0)) }
        // APFS ignores case and Unicode normalization, so `~/library/..` names the same folders as `~/Library/..`.
        let prefix = PathUtil.comparisonKey("/" + literal.joined(separator: "/"))
        let homeKey = PathUtil.comparisonKey(home)
        return components.count < 2 || prefix == "/" || prefix == homeKey || PathUtil.comparisonKey(expanded) == homeKey
    }

    /// Why a command from a rule outside the built-in library doesn't run: the validation warning and the
    /// executor's refusal say the same thing.
    static func untrustedRuleCommand(_ executable: String) -> String {
        "'\(executable)' comes from a rule outside SpaceKit's built-in library; built-in trust covers SpaceKit's own rules only. "
            + "Add it to safety.allowedCommands to allow it"
    }

    private static func commandIssues(_ command: [String], rule: Rule) -> [(severity: RuleIssue.Severity, message: String)] {
        guard let executable = command.first, Shell.isBareName(executable) else {
            let got = command.first ?? ""
            return [(.error, "command must start with a bare program name such as brew, without / or .. or {name}; got '\(got)'")]
        }
        var issues: [(RuleIssue.Severity, String)] = []
        if rule.isBuiltin {
            if !trustedCommands.contains(executable) {
                let message = "command '\(executable)' is not in the trusted list; it only runs if listed in safety.allowedCommands"
                issues.append((.warning, message))
            }
        } else {
            issues.append((.warning, untrustedRuleCommand(executable)))
        }
        if command.contains(where: { $0.contains(";") || $0.contains("&&") || $0.contains("|") || $0.contains("`") || $0.contains("$(") }) {
            issues.append((.error, "commands run without a shell; remove shell syntax (; && | ` $( )"))
        }
        return issues
    }
}
