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
    /// Ids of the built-in rules, including those a user rule replaced.
    public private(set) var builtinIDs: Set<String>

    public init(rules: [Rule], issues: [RuleIssue] = [], builtinIDs: Set<String> = []) {
        self.rules = rules
        self.issues = issues
        self.builtinIDs = builtinIDs
    }

    /// The source named for a rule that didn't come from a file, such as one parsed from text in a test.
    public static let inlineSource = "<inline>"

    /// User rules loaded in place of a built-in rule with the same id.
    public var overrides: [Rule] { rules.filter { !$0.isBuiltin && builtinIDs.contains($0.id) } }

    /// Loads the built-in rules and every `*.yaml` / `*.yml` in `directories`.
    ///
    /// A user rule with the id of an earlier rule replaces it. An override of a built-in rule may only narrow it
    /// (`overrideProblems`), and a built-in `protected` rule can't be replaced at all. Rules with validation errors
    /// are reported in `issues` but not loaded, and `disabled` never turns off a `protected` rule.
    public static func load(builtin: BuiltinRules = .standard, directories: [String] = [], disabled: Set<String> = []) -> RuleLibrary {
        var byID: [String: Rule] = [:]
        var builtinByID: [String: Rule] = [:]
        var order: [String] = []
        let read = sources(builtin: builtin, directories: directories)
        var issues = read.issues

        for (file, isBuiltin) in read.sources {
            let parsed: [Rule]
            do {
                parsed = try parse(yaml: file.yaml, source: file.source)
            } catch {
                issues.append(RuleIssue(severity: .error, source: file.source, message: DecodingErrorText.describe(error)))
                continue
            }
            for var rule in parsed {
                rule.isBuiltin = isBuiltin
                let ruleIssues = RuleLibrary.issues(for: rule)
                issues += ruleIssues
                if ruleIssues.contains(where: { $0.severity == .error }) { continue }
                if let original = builtinByID[rule.id], !isBuiltin {
                    let problems = overrideIssues(builtin: original, override: rule)
                    if !problems.isEmpty {
                        issues += problems
                        continue
                    }
                    rule.narrowing = Rule.Narrowing(builtinPaths: original.paths, builtinExclusions: pathExclusions(original))
                }
                if let existing = byID[rule.id] {
                    let origin = PathUtil.abbreviate(existing.source ?? inlineSource)
                    issues.append(
                        RuleIssue(severity: .warning, source: file.source, ruleID: rule.id, message: "replaces the rule from \(origin)"))
                } else {
                    order.append(rule.id)
                }
                byID[rule.id] = rule
                if isBuiltin { builtinByID[rule.id] = rule }
            }
        }

        let enabled = enabled(order.compactMap { byID[$0] }, disabled: disabled)
        return RuleLibrary(rules: enabled.rules, issues: issues + enabled.issues, builtinIDs: Set(builtinByID.keys))
    }

    /// The built-in rule files, then the rule files in each of `directories`, with the problems reading them.
    private static func sources(builtin: BuiltinRules, directories: [String]) -> (
        sources: [(file: RuleFileText, isBuiltin: Bool)], issues: [RuleIssue]
    ) {
        var issues = builtin.issues
        var sources = builtin.files.map { (file: $0, isBuiltin: true) }
        for directory in directories.map({ PathUtil.standardize(PathUtil.expand($0)) }) {
            let read = read(directory: directory)
            issues += read.issues
            sources += read.files.map { (file: $0, isBuiltin: false) }
        }
        return (sources, issues)
    }

    /// `rules` without the ones `disabled` names, except `protected` rules: those stay, with a warning.
    private static func enabled(_ rules: [Rule], disabled: Set<String>) -> (rules: [Rule], issues: [RuleIssue]) {
        var kept: [Rule] = []
        var issues: [RuleIssue] = []
        for rule in rules {
            if disabled.contains(rule.id) {
                guard rule.safety.level == .protected else { continue }
                issues.append(
                    RuleIssue(
                        severity: .warning, source: rule.source ?? inlineSource, ruleID: rule.id,
                        message: "protected rules can't be disabled; it stays active (rules.disabled)"))
            }
            kept.append(rule)
        }
        return (kept, issues)
    }

    /// Checks rule files on disk the way loading them would: a file other users could change isn't loaded
    /// (`FileTrust`), each rule on its own, and a rule with a built-in id against the built-in rule it would replace.
    /// `asBuiltin` judges them as built-in rules instead, for contributors checking a file in the repository's `rules/`
    /// folder before they build: built-in rules are compiled in, never read from a file, so who could change it doesn't
    /// matter there.
    public static func check(files: [String], asBuiltin: Bool = false, builtin: BuiltinRules = .standard) -> (
        rules: [Rule], issues: [RuleIssue]
    ) {
        let library = load(builtin: builtin)
        var rules: [Rule] = []
        var issues: [RuleIssue] = []
        for file in files {
            if !asBuiltin, let problem = FileTrust.problem(with: file) {
                issues.append(RuleIssue(severity: .error, source: file, message: RuleLibrary.notLoaded(problem)))
                continue
            }
            do {
                rules += try parse(yaml: try String(contentsOfFile: file, encoding: .utf8), source: file).map { rule in
                    var rule = rule
                    rule.isBuiltin = asBuiltin
                    return rule
                }
            } catch {
                issues.append(RuleIssue(severity: .error, source: file, message: DecodingErrorText.describe(error)))
            }
        }
        issues += RuleLibrary(rules: rules).validate()
        if !asBuiltin {
            for rule in rules {
                guard let original = library.rule(id: rule.id), original.isBuiltin else { continue }
                issues += overrideIssues(builtin: original, override: rule)
            }
        }
        return (rules, issues)
    }

    /// The issue of a rule file other users could have changed (`FileTrust.problem`), which loading skips.
    static func notLoaded(_ problem: String) -> String { "not loaded: it \(problem)" }

    /// The text of every rule file in `directory`, except files other users could have changed (`FileTrust`).
    static func read(directory: String) -> (files: [RuleFileText], issues: [RuleIssue]) {
        var files: [RuleFileText] = []
        var issues: [RuleIssue] = []
        for file in yamlFiles(in: directory) {
            if let problem = FileTrust.problem(with: file) {
                issues.append(RuleIssue(severity: .error, source: file, message: notLoaded(problem)))
                continue
            }
            do {
                files.append(RuleFileText(source: file, yaml: try String(contentsOfFile: file, encoding: .utf8)))
            } catch {
                issues.append(RuleIssue(severity: .error, source: file, message: DecodingErrorText.describe(error)))
            }
        }
        return (files, issues)
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
    public static func parse(yaml: String, source: String = inlineSource) throws -> [Rule] {
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
            let source = rule.source ?? Self.inlineSource
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
            issues.append(RuleIssue(severity: severity, source: rule.source ?? inlineSource, ruleID: rule.id, message: message))
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
            CommandTrust.ruleIssues(command, isBuiltin: rule.isBuiltin).forEach { issue($0.severity, $0.message) }
        }
        if rule.granularity == .children && rule.match != nil {
            issue(.warning, "`granularity: children` is unusual for pattern rules")
        }
        if let ai = rule.ai, !AISpec.layouts.contains(ai.layout) {
            let layouts = AISpec.layouts.sorted().joined(separator: ", ")
            issue(.warning, "unknown ai.layout '\(ai.layout)'; it is shown as a cache. Use one of \(layouts)")
        }
        if let command = rule.ai?.removeCommand {
            CommandTrust.ruleIssues(command, isBuiltin: rule.isBuiltin).forEach { issue($0.severity, $0.message) }
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
}
