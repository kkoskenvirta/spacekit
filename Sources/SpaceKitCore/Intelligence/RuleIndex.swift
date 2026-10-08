import Foundation

extension ScanSettings {
    /// Where pattern rules look for projects unless the config says otherwise: the home folder.
    public static let defaultDevRoots: [String] = ["~"]
}

/// Answers "what is this folder?" for any path, so every view can label folders semantically.
public struct RuleIndex: Sendable {
    private var exact: [String: Rule] = [:]
    /// Locations of `granularity: children` rules: every entry inside belongs to the rule.
    private var containers: [String: Rule] = [:]
    /// Glob locations with their literal prefix (the part before the first wildcard), checked first.
    private var globRules: [(glob: String, prefix: String, rule: Rule)] = []
    private var byName: [String: [Rule]] = [:]
    private let scope: RuleScope

    /// `patternRoots`: where pattern rules without their own `roots` look (the config's `scan.devRoots`).
    public init(
        rules: [Rule], findings: [Finding] = [], home: String = PathUtil.home, patternRoots: [String] = ScanSettings.defaultDevRoots
    ) {
        scope = RuleScope(home: home, patternRoots: patternRoots)
        for rule in rules {
            for pattern in rule.paths {
                let expanded = PathUtil.expand(pattern, home: home)
                if let wildcard = expanded.firstIndex(where: { "*?[".contains($0) }) {
                    globRules.append((expanded, String(expanded[..<wildcard]), rule))
                } else if rule.granularity == .children {
                    containers[expanded] = rule
                    if exact[expanded] == nil { exact[expanded] = rule }
                } else {
                    exact[expanded] = rule
                }
            }
            for name in rule.match?.names ?? [] { byName[name, default: []].append(rule) }
        }
        for finding in findings {
            for item in finding.items where item.kind != .looseFiles { exact[item.path] = finding.rule }
        }
    }

    /// The rule describing exactly this path (or an entry of a `children` rule), if any.
    public func rule(for path: String) -> Rule? {
        if let rule = exact[path] { return rule }
        if let rule = containers[PathUtil.parent(path)] { return rule }
        for entry in globRules where path.hasPrefix(entry.prefix) && PathUtil.matches(path, glob: entry.glob) { return entry.rule }
        return patternRule(for: path)
    }

    /// A pattern rule matching this folder, verified against the disk (e.g. `node_modules` next to a `package.json`),
    /// and only where the engine would look for it.
    public func patternRule(for path: String) -> Rule? {
        guard let candidates = byName[PathUtil.lastComponent(path)] else { return nil }
        let fm = FileManager.default
        let parent = PathUtil.parent(path)
        return candidates.first { rule in
            guard scope.contains(path, rule: rule) else { return false }
            return rule.match?.markersPresent(
                sibling: { fm.fileExists(atPath: PathUtil.join(parent, $0)) },
                inside: { fm.fileExists(atPath: PathUtil.join(path, $0)) }) ?? false
        }
    }
}

/// The rule for a path or its nearest ancestor (so files deep inside DerivedData are recognised), memoized
/// for one pass over many related paths (a map layout, a list). Not thread-safe: use one per task.
public final class RuleLookupCache {
    public let index: RuleIndex
    private var containing: [String: Rule?] = [:]

    public init(index: RuleIndex) { self.index = index }

    public func rule(containing path: String) -> Rule? {
        if let cached = containing[path] { return cached }
        let result: Rule?
        if let direct = index.rule(for: path) {
            result = direct
        } else if path == "/" || path.isEmpty {
            result = nil
        } else {
            result = rule(containing: PathUtil.parent(path))
        }
        containing[path] = result
        return result
    }
}
