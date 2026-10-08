import Foundation

/// The text of one rule file and the name its rules and issues are reported under.
public struct RuleFileText: Sendable, Equatable {
    public var source: String
    public var yaml: String

    public init(source: String, yaml: String) {
        self.source = source
        self.yaml = yaml
    }
}

/// SpaceKit's own rules, the only ones with built-in trust: their commands may run the trusted tools, also in
/// automatic runs, and nothing can replace their protected rules.
///
/// They are compiled into the binary from the repository's `rules/` folder (the EmbedRules build plugin), so being
/// built-in is a fact of the build. No folder next to an installed binary, and no environment variable in a release
/// build, can add, change or drop one, and a file that doesn't parse fails the tests instead of quietly taking its
/// protections with it.
public struct BuiltinRules: Sendable {
    public let files: [RuleFileText]
    /// Files of a debug build's `SPACEKIT_RULES_DIR` that couldn't be read.
    let issues: [RuleIssue]
    /// Where the rules came from, for `spacekit rules dirs` and `spacekit doctor`.
    public let origin: String

    init(files: [RuleFileText], issues: [RuleIssue] = [], origin: String = "rule files passed in directly") {
        self.files = files
        self.issues = issues
        self.origin = origin
    }

    /// The rules compiled into this binary.
    public static let embedded = BuiltinRules(
        files: EmbeddedRuleFiles.all.map { RuleFileText(source: "built-in rules/" + $0.path, yaml: $0.yaml) },
        origin: "built into SpaceKit (\(EmbeddedRuleFiles.all.count) files)")

    /// The embedded rules, or in a debug build the folder `$SPACEKIT_RULES_DIR` names instead, so a contributor can
    /// try rule edits without rebuilding.
    public static var standard: BuiltinRules {
        standard(environment: ProcessInfo.processInfo.environment, debugBuild: isDebugBuild)
    }

    /// Rules in that folder get built-in trust, and any process that can set the agent's environment controls it, so
    /// a release build never reads it.
    #if DEBUG
        static let isDebugBuild = true
    #else
        static let isDebugBuild = false
    #endif

    static func standard(environment: [String: String], debugBuild: Bool) -> BuiltinRules {
        guard debugBuild, let directory = environment["SPACEKIT_RULES_DIR"], !directory.isEmpty else { return .embedded }
        let shown = PathUtil.abbreviate(directory)
        let read = RuleLibrary.read(directory: PathUtil.standardize(PathUtil.expand(directory)))
        let ruleCount = read.files.reduce(0) { count, file in
            count + ((try? RuleLibrary.parse(yaml: file.yaml, source: file.source))?.count ?? 0)
        }
        // A mistyped or empty folder would otherwise load no built-in rules, and the protected ones would go with them
        // without a word.
        guard ruleCount > 0 else {
            let issue = RuleIssue(
                severity: .error, source: directory,
                message: "$SPACEKIT_RULES_DIR has no rules to load (missing, empty or unreadable folder); the embedded rules are used")
            return BuiltinRules(
                files: embedded.files, issues: read.issues + [issue],
                origin: "\(embedded.origin); $SPACEKIT_RULES_DIR \(shown) has no rules (debug build)")
        }
        return BuiltinRules(
            files: read.files, issues: read.issues, origin: "$SPACEKIT_RULES_DIR \(shown) (debug build; the embedded rules are not used)")
    }
}
