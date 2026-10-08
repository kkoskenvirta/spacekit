import Foundation

/// Where a rule applies: under one of its paths, or, for a pattern rule, a folder with a matching name under its
/// roots (or the configured developer roots), outside its exclusions, the default pattern exclusions and bundles.
/// The guard, the rule index and `RuleEngine` must agree on this, or an item one of them rejects gets a rule's
/// trust from another.
struct RuleScope: Sendable {
    let home: String
    /// Where pattern rules without their own `roots` look (the config's `scan.devRoots`).
    let patternRoots: [String]

    func contains(_ path: String, rule: Rule) -> Bool {
        if rule.paths.contains(where: { PathUtil.isInside(path, pattern: resolve($0)) }) { return true }
        guard let match = rule.match, match.names.contains(PathUtil.lastComponent(path)) else { return false }
        let roots = (match.roots ?? patternRoots).map(resolve)
        guard roots.contains(where: { PathUtil.isAncestorOrEqual($0, of: path) }) else { return false }
        return !isExcluded(path, match: match)
    }

    /// A rule or job location the way `RuleEngine` resolves it, so it compares with scanned paths.
    func resolve(_ pattern: String) -> String {
        PathUtil.expand(PathUtil.canonicalPattern(pattern, home: home), home: home)
    }

    /// Exclusions are compared by key so a differently spelled path stays excluded.
    private func isExcluded(_ path: String, match: PatternSpec) -> Bool {
        let key = PathUtil.comparisonKey(path)
        let excluded = (RuleEngine.defaultPatternExcludes + match.exclude).contains { exclude in
            PathUtil.isInside(key, pattern: PathUtil.comparisonKey(resolve(exclude)))
        }
        return excluded
            || PathUtil.components(key).dropLast().contains { component in RuleEngine.bundleSuffixes.contains { component.hasSuffix($0) } }
    }
}
