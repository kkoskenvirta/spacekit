import Foundation

/// How risky it is to remove what a rule matches.
public enum SafetyLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// 🟢 Regenerable. The owning tool recreates it on demand (build output, package caches).
    case safe
    /// 🟡 Review. Removable, but costs time, bandwidth or something you might want (archives, models, simulators).
    case review
    /// 🔴 Don't touch automatically. Identified so it can be shown and protected, never cleaned by SpaceKit.
    case protected

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
        guard let level = SafetyLevel(alias: raw) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown safety level '\(raw)'. Use safe, review or protected."))
        }
        self = level
    }

    public init?(alias: String) {
        switch alias.lowercased() {
        case "safe", "regenerable", "low": self = .safe
        case "review", "caution", "medium": self = .review
        case "protected", "never", "keep", "high": self = .protected
        default: return nil
        }
    }

    private var rank: Int { self == .safe ? 0 : self == .review ? 1 : 2 }
    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rank < rhs.rank }

    public var title: String {
        switch self {
        case .safe: return "Regenerable"
        case .review: return "Review"
        case .protected: return "Don't touch"
        }
    }

    public var risk: String {
        switch self {
        case .safe: return "Low"
        case .review: return "Medium"
        case .protected: return "High"
        }
    }

    public var emoji: String {
        switch self {
        case .safe: return "🟢"
        case .review: return "🟡"
        case .protected: return "🔴"
        }
    }
}

/// Whether a rule's matched location is one item or a set of items.
public enum Granularity: String, Codable, Sendable {
    /// The matched directory is one item (`node_modules`, a single cache).
    case whole
    /// Each entry inside the matched directory is an item (`DerivedData/<project>`, `Archives/<date>`),
    /// so policies like "keep projects used within 14 days" can apply per entry.
    case children
}

/// A storage rule: knowledge about one kind of data on a Mac.
///
/// Rules live in YAML files (see `docs/RULES.md` and the `rules/` directory). The schema is
/// deliberately forgiving: `path` may be a string or a list, `safety` may be a level or an object,
/// and `action` may be `trash`, `delete` or an object.
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Display group, e.g. `Xcode`, `JavaScript`, `Ollama`. Defaults to the file's `group`.
    public var group: String
    /// Dotted category, e.g. `developer.build`, `developer.cache`, `ai.models`, `system.cache`.
    public var category: String
    public var description: String?
    /// Tool that recreates the data, shown as "Recreated by".
    public var recreatedBy: String?
    /// Fixed locations. `~` and globs (`*`) are allowed.
    public var paths: [String]
    /// Name-based matching anywhere under search roots (for `node_modules`, `target`, `__pycache__`, …).
    public var match: PatternSpec?
    public var granularity: Granularity
    public var safety: SafetySpec
    /// Suggested automation defaults.
    public var policy: PolicySpec?
    /// Globs to leave alone, plus tokens: `active_projects` (respect the policy's `keepRecent`).
    public var exclusions: [String]
    public var action: ActionSpec
    public var ai: AISpec?
    public var docs: String?
    public var tags: [String]
    /// File the rule was loaded from (not part of the schema).
    public var source: String?
    /// One of SpaceKit's own rules, compiled into the binary (`BuiltinRules`; not part of the schema). Only built-in
    /// rules may run `CommandTrust.trustedCommands` without the user listing them in `safety.allowedCommands`.
    public var isBuiltin = false
    /// For an override: the built-in rule's paths and path exclusions it was checked against when the rules loaded,
    /// which `RuleEngine` checks it against again where it looks (not part of the schema).
    var narrowing: Narrowing?

    /// The bounds an override must stay within: the built-in rule's paths and its exclusions written as paths.
    struct Narrowing: Sendable {
        let builtinPaths: [String]
        let builtinExclusions: [String]
    }

    public static func == (lhs: Rule, rhs: Rule) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var isPattern: Bool { match != nil }

    public init(
        id: String, name: String, group: String = "", category: String = "other",
        description: String? = nil, recreatedBy: String? = nil, paths: [String] = [],
        match: PatternSpec? = nil, granularity: Granularity = .whole, safety: SafetySpec = SafetySpec(level: .review),
        policy: PolicySpec? = nil, exclusions: [String] = [], action: ActionSpec = ActionSpec(),
        ai: AISpec? = nil, docs: String? = nil, tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.category = category
        self.description = description
        self.recreatedBy = recreatedBy
        self.paths = paths
        self.match = match
        self.granularity = granularity
        self.safety = safety
        self.policy = policy
        self.exclusions = exclusions
        self.action = action
        self.ai = ai
        self.docs = docs
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case id, name, group, category, description, recreatedBy, path, paths, match, granularity
        case safety, policy, exclusions, action, ai, docs, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Rule.slug(name)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        recreatedBy = try c.decodeIfPresent(String.self, forKey: .recreatedBy)
        paths = try c.decodeStringOrListIfPresent(forKey: .path) ?? c.decodeStringOrListIfPresent(forKey: .paths) ?? []
        match = try c.decodeIfPresent(PatternSpec.self, forKey: .match)
        granularity = try c.decodeIfPresent(Granularity.self, forKey: .granularity) ?? .whole
        safety = try c.decodeIfPresent(SafetySpec.self, forKey: .safety) ?? SafetySpec(level: .review)
        policy = try c.decodeIfPresent(PolicySpec.self, forKey: .policy)
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        action = try c.decodeIfPresent(ActionSpec.self, forKey: .action) ?? ActionSpec()
        ai = try c.decodeIfPresent(AISpec.self, forKey: .ai)
        docs = try c.decodeIfPresent(String.self, forKey: .docs)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(group, forKey: .group)
        try c.encode(category, forKey: .category)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(recreatedBy, forKey: .recreatedBy)
        if !paths.isEmpty { try c.encode(paths, forKey: .path) }
        try c.encodeIfPresent(match, forKey: .match)
        try c.encode(granularity, forKey: .granularity)
        try c.encode(safety, forKey: .safety)
        try c.encodeIfPresent(policy, forKey: .policy)
        if !exclusions.isEmpty { try c.encode(exclusions, forKey: .exclusions) }
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(ai, forKey: .ai)
        try c.encodeIfPresent(docs, forKey: .docs)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
    }

    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.hasSuffix("-") ? String(result.dropLast()) : result
    }
}

/// Name-based matching, e.g. every `node_modules` that sits next to a `package.json`.
public struct PatternSpec: Codable, Sendable, Hashable {
    /// Directory names to match.
    public var names: [String]
    /// At least one of these must exist next to the match (in its parent directory).
    public var sibling: [String]
    /// At least one of these must exist inside the match.
    public var contains: [String]
    /// Where to search. Defaults to the configured developer roots (normally `~`).
    public var roots: [String]?
    /// Globs that are never searched (in addition to SpaceKit's defaults such as `~/Library`).
    public var exclude: [String]

    public init(names: [String], sibling: [String] = [], contains: [String] = [], roots: [String]? = nil, exclude: [String] = []) {
        self.names = names
        self.sibling = sibling
        self.contains = contains
        self.roots = roots
        self.exclude = exclude
    }

    enum CodingKeys: String, CodingKey { case names, name, sibling, contains, roots, exclude }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decodeStringOrListIfPresent(forKey: .names) ?? c.decodeStringOrListIfPresent(forKey: .name) ?? []
        sibling = try c.decodeStringOrListIfPresent(forKey: .sibling) ?? []
        contains = try c.decodeStringOrListIfPresent(forKey: .contains) ?? []
        roots = try c.decodeIfPresent([String].self, forKey: .roots)
        exclude = try c.decodeStringOrListIfPresent(forKey: .exclude) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(names, forKey: .names)
        if !sibling.isEmpty { try c.encode(sibling, forKey: .sibling) }
        if !contains.isEmpty { try c.encode(contains, forKey: .contains) }
        try c.encodeIfPresent(roots, forKey: .roots)
        if !exclude.isEmpty { try c.encode(exclude, forKey: .exclude) }
    }
}

extension KeyedDecodingContainer {
    /// A value written either as one string or as a list of strings.
    func decodeStringOrListIfPresent(forKey key: Key) throws -> [String]? {
        if let list = try? decodeIfPresent([String].self, forKey: key) { return list }
        return try decodeIfPresent(String.self, forKey: key).map { [$0] }
    }
}

public struct SafetySpec: Codable, Sendable, Hashable {
    public var level: SafetyLevel
    /// Move to the Trash instead of deleting permanently.
    public var trash: Bool

    public init(level: SafetyLevel, trash: Bool = true) {
        self.level = level
        self.trash = trash
    }

    enum CodingKeys: String, CodingKey { case level, trash }

    public init(from decoder: Decoder) throws {
        if let level = try? decoder.singleValueContainer().decode(SafetyLevel.self) {
            self = SafetySpec(level: level)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(SafetyLevel.self, forKey: .level)
        trash = try c.decodeIfPresent(Bool.self, forKey: .trash) ?? true
    }
}

/// Suggested automation for a rule. Jobs created from the rule start with these values.
public struct PolicySpec: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case size, age, schedule }

    /// Informational; the fields below are what count.
    public var type: Kind?
    /// Clean when the total grows beyond this.
    public var threshold: ByteCount?
    /// Only clean items untouched for at least this long.
    public var olderThan: Age?
    /// Never clean items used within this window (`active_projects`).
    public var keepRecent: Age?
    public var schedule: Schedule?
    public var mode: Job.Mode?

    public init(
        type: Kind? = nil, threshold: ByteCount? = nil, olderThan: Age? = nil, keepRecent: Age? = nil, schedule: Schedule? = nil,
        mode: Job.Mode? = nil
    ) {
        self.type = type
        self.threshold = threshold
        self.olderThan = olderThan
        self.keepRecent = keepRecent
        self.schedule = schedule
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey { case type, threshold, olderThan, keepRecent, schedule, mode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(Kind.self, forKey: .type)
        threshold = try c.decodeIfPresent(ByteCount.self, forKey: .threshold)
        olderThan = try c.decodeRetentionIfPresent(forKey: .olderThan)
        keepRecent = try c.decodeRetentionIfPresent(forKey: .keepRecent)
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule)
        mode = try c.decodeIfPresent(Job.Mode.self, forKey: .mode)
    }
}

/// What cleaning means for a rule.
public struct ActionSpec: Codable, Sendable, Hashable {
    /// Remove the matched items (to the Trash unless `safety.trash` is false).
    public var remove: Bool
    /// Run this instead of removing files, e.g. `[docker, builder, prune, --force]`. No shell is involved.
    public var command: [String]?
    /// Run once per item; `{name}` and `{path}` are substituted (e.g. `[ollama, rm, "{name}"]`).
    public var itemCommand: [String]?
    /// Human instructions when cleanup must happen in another app.
    public var manual: String?

    public init(remove: Bool = false, command: [String]? = nil, itemCommand: [String]? = nil, manual: String? = nil) {
        self.remove = remove
        self.command = command
        self.itemCommand = itemCommand
        self.manual = manual
    }

    enum CodingKeys: String, CodingKey { case remove, command, itemCommand, manual }

    public init(from decoder: Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            switch word.lowercased() {
            case "remove": self = ActionSpec(remove: true)
            case "none": self = ActionSpec()
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown action '\(word)'. Use remove, none, or an object with command/manual."))
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decodeIfPresent([String].self, forKey: .command)
        itemCommand = try c.decodeIfPresent([String].self, forKey: .itemCommand)
        manual = try c.decodeIfPresent(String.self, forKey: .manual)
        remove = try c.decodeIfPresent(Bool.self, forKey: .remove) ?? false
    }

    public var isCleanable: Bool { remove || command != nil || itemCommand != nil }

    /// Any action at all, including manual instructions. Protected rules may have none.
    public var isEmpty: Bool { !isCleanable && manual == nil }
}

/// Extra knowledge for the AI Development view.
public struct AISpec: Codable, Sendable, Hashable {
    /// Tool name shown in the AI view (`Ollama`, `Hugging Face`, …).
    public var tool: String
    /// How models are laid out on disk: `ollama`, `huggingface`, `lmstudio`, `children` (each entry is a model) or `cache`.
    public var layout: String

    /// How the tool removes one model, e.g. `[ollama, rm, "{name}"]`; `{name}` is the model's name as the AI view
    /// shows it. Use this when a model's files are shared with others (Ollama blobs), so only the tool can tell
    /// what may go.
    public var removeCommand: [String]?

    /// Every `layout` the AI view understands; anything else is shown as a cache.
    public static let layouts: Set<String> = ["ollama", "huggingface", "lmstudio", "children", "cache"]

    public init(tool: String, layout: String, removeCommand: [String]? = nil) {
        self.tool = tool
        self.layout = layout
        self.removeCommand = removeCommand
    }

    /// `removeCommand` filled in for one model, or `nil` if the rule has none.
    public func removeArguments(forModel name: String) -> [String]? {
        removeCommand?.map { $0.replacingOccurrences(of: "{name}", with: name) }
    }
}
