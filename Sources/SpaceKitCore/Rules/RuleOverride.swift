import Foundation

extension RuleLibrary {
    /// `overrideProblems` as errors on the override, which then doesn't load.
    static func overrideIssues(builtin: Rule, override: Rule) -> [RuleIssue] {
        overrideProblems(builtin: builtin, override: override).map {
            RuleIssue(severity: .error, source: override.source ?? inlineSource, ruleID: override.id, message: $0)
        }
    }

    /// Why `override` may not take the place of the built-in rule with the same id; empty when it may.
    ///
    /// Jobs and the starter config name rules by id, and jobs from 🟢 rules run automatically. So a file in the user
    /// rules folder, which any program running as the person can write, would otherwise widen what an existing
    /// automatic job removes just by reusing an id. An override may only narrow the built-in rule: keep its paths
    /// within the built-in ones, add exclusions, raise its thresholds and ages, schedule its jobs less often, keep or
    /// raise its safety level, drop its action. Turning it into a `protected` rule only adds protection, so that is
    /// always allowed. Anything new has to be a rule of its own.
    static func overrideProblems(builtin: Rule, override: Rule) -> [String] {
        if builtin.safety.level == .protected {
            return ["can't replace the built-in protected rule with the same id; protected rules keep SpaceKit from touching that data"]
        }
        if override.safety.level < builtin.safety.level {
            return [
                "can't lower the safety level of the built-in rule from \(builtin.safety.level.rawValue) to "
                    + "\(override.safety.level.rawValue); add it to rules.disabled to turn it off instead"
            ]
        }
        if override.safety.level == .protected { return [] }

        let widened = locationProblems(builtin, override) + actionProblems(builtin, override) + policyProblems(builtin, override)
        guard !widened.isEmpty else { return [] }
        return widened.map {
            "can't widen the built-in rule: \($0). A rule with a built-in id may only narrow it (add exclusions, raise "
                + "thresholds and ages, raise the safety level); give a new rule its own id"
        }
    }

    private static func locationProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        var problems = pathProblems(builtin, override)
        switch (builtin.match, override.match) {
        case (nil, .some):
            problems.append("adds a name pattern (match)")
        case (.some(let original), .some(let pattern)):
            for name in pattern.names where !original.names.contains(name) { problems.append("adds the name '\(name)' to its pattern") }
            if pattern.sibling != original.sibling || pattern.contains != original.contains || pattern.roots != original.roots {
                problems.append("changes where its pattern matches (match sibling, contains or roots)")
            }
            for glob in original.exclude where !pattern.exclude.contains(glob) {
                problems.append("drops '\(glob)' from its pattern's exclude")
            }
        default:
            break
        }
        if override.granularity != builtin.granularity { problems.append("changes its granularity") }
        for exclusion in builtin.exclusions where !override.exclusions.contains(exclusion) {
            problems.append("drops the exclusion '\(exclusion)'")
        }
        return problems
    }

    private static func actionProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        var problems: [String] = []
        let action = override.action
        if action.remove && !builtin.action.remove { problems.append("adds remove to its action") }
        if let command = action.command, command != builtin.action.command { problems.append("changes its command") }
        if let command = action.itemCommand, command != builtin.action.itemCommand { problems.append("changes its itemCommand") }
        if let ai = override.ai {
            if ai.layout != builtin.ai?.layout || ai.tool != builtin.ai?.tool { problems.append("changes its ai layout") }
            if let command = ai.removeCommand, command != builtin.ai?.removeCommand { problems.append("changes its ai.removeCommand") }
        }
        if builtin.safety.trash && !override.safety.trash { problems.append("turns off the Trash (safety.trash)") }
        return problems
    }

    private static func policyProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        let original = builtin.policy
        let policy = override.policy
        var problems = [
            lowered("threshold", from: original?.threshold, to: policy?.threshold),
            lowered("olderThan", from: original?.olderThan, to: policy?.olderThan),
            lowered("keepRecent", from: original?.keepRecent, to: policy?.keepRecent),
        ].compactMap { $0 }
        let job = Job.suggested(for: override)
        let originalJob = Job.suggested(for: builtin)
        // The policies are compared, not the jobs: a command rule's jobs start as suggestions whatever its policy says.
        let (mode, originalMode) = (Job.policyMode(of: override), Job.policyMode(of: builtin))
        if mode > originalMode {
            problems.append("makes jobs from it start in \(mode.rawValue) mode instead of \(originalMode.rawValue)")
        }
        if job.schedule.every < originalJob.schedule.every {
            problems.append("makes jobs from it run \(job.schedule.every.rawValue) instead of \(originalJob.schedule.every.rawValue)")
        }
        return problems
    }

    /// A limit the built-in rule's policy sets that the override lowers or leaves out (no limit is the lowest).
    private static func lowered<Limit: Comparable>(_ name: String, from original: Limit?, to limit: Limit?) -> String? {
        guard let original, limit.map({ $0 < original }) ?? true else { return nil }
        return "lowers its policy \(name) below \(original)"
    }

    /// The override's paths that name a location none of the built-in paths do, or one a built-in exclusion names.
    private static func pathProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        let exclusions = pathExclusions(builtin)
        return override.paths.flatMap { path in
            let added = builtin.paths.contains { covers($0, path) } ? [] : ["adds the path '\(path)'"]
            return added + exclusions.filter { isInside(path, exclusion: $0) }.map { "names '\(path)' in its exclusion '\($0)'" }
        }
    }

    /// A rule's exclusions written as paths, which name folders; `active_projects` and relative globs don't.
    static func pathExclusions(_ rule: Rule) -> [String] {
        rule.exclusions.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
    }

    /// True when `path` names only locations `builtin` names, at the same depth. Both are compared where the engine
    /// looks for them (through `PathUtil.canonicalPattern`, as `RuleEngine.canonical` resolves every rule path), and
    /// each component of `path` must equal the built-in one or be a glob whose names are a subset of its names: a
    /// built-in segment `X*` covers `X<more>*`. A deeper path would change the items the built-in rule judges:
    /// `DerivedData/*` would weigh keepRecent per build folder instead of per project. Comparing the text instead would
    /// let a symlinked folder inside a built-in path lead an override anywhere.
    static func covers(_ builtin: String, _ path: String) -> Bool {
        covers(canonical: PathUtil.canonicalPattern(builtin), PathUtil.canonicalPattern(path))
    }

    /// `covers` for paths already resolved through `PathUtil.canonicalPattern`, as the engine holds them.
    static func covers(canonical builtin: String, _ path: String) -> Bool {
        let outer = PathUtil.components(compared(builtin))
        let inner = PathUtil.components(compared(path))
        return outer.count == inner.count && zip(outer, inner).allSatisfy { covers(segment: $1, pattern: $0) }
    }

    /// True when `path` is the location `exclusion` names or lies inside it, both where the engine looks for them. The
    /// engine leaves out only items an exclusion names, so an override rooted at or below an excluded folder would hand
    /// out everything in it. A `**` in the exclusion counts as holding everything below it.
    static func isInside(_ path: String, exclusion: String) -> Bool {
        isInside(canonical: PathUtil.canonicalPattern(path), exclusion: PathUtil.canonicalPattern(exclusion))
    }

    /// `isInside` for paths already resolved through `PathUtil.canonicalPattern`, as the engine holds them.
    static func isInside(canonical path: String, exclusion: String) -> Bool {
        let outer = PathUtil.components(compared(exclusion))
        let inner = PathUtil.components(compared(path))
        guard inner.count >= outer.count else { return false }
        for (pattern, segment) in zip(outer, inner) {
            if pattern == "**" { return true }
            guard covers(segment: segment, pattern: pattern) else { return false }
        }
        return true
    }

    /// True when an override's `path` stays within the built-in rule it narrows: one of `builtinPaths` covers it and
    /// none of `exclusions` holds it. All three are resolved through `PathUtil.canonicalPattern`, as the engine holds
    /// them, so the engine can check again with the paths it is about to use.
    static func staysWithin(canonical path: String, builtinPaths: [String], exclusions: [String]) -> Bool {
        builtinPaths.contains { covers(canonical: $0, path) } && !exclusions.contains { isInside(canonical: path, exclusion: $0) }
    }

    /// A resolved rule path as it is compared: expanded as `PathUtil.glob` expands it, and case-folded as the guard
    /// compares paths.
    private static func compared(_ canonical: String) -> String {
        PathUtil.comparisonKey(PathUtil.expand(canonical))
    }

    /// True when every name `segment` matches, `pattern` matches too, the way glob(3) expands a rule path: one
    /// component at a time, and a leading `.` only where the pattern spells it out (`FNM_PERIOD`), so `*` never covers
    /// `.keys` or `.k*`. `**` crosses folders and may match none, so a segment holding it is covered only by the same
    /// segment.
    private static func covers(segment: Substring, pattern: Substring) -> Bool {
        if segment == pattern { return true }
        if segment.contains("**") { return false }
        if !PathUtil.isGlob(String(segment)) { return fnmatch(String(pattern), String(segment), FNM_PERIOD) == 0 }
        guard pattern.hasSuffix("*"), !pattern.hasSuffix("**") else { return false }
        let prefix = pattern.dropLast()
        let dotNameUnderWildcard = prefix.isEmpty && segment.hasPrefix(".")
        return !PathUtil.isGlob(String(prefix)) && segment.hasPrefix(prefix) && !dotNameUnderWildcard
    }
}

extension Rule {
    /// This rule's paths where they lead now (`PathUtil.canonicalPattern` with `home`), as the engine and the guard use
    /// them; for an override, without those that now lead outside the built-in rule it narrows (`leftOut`: each as
    /// written, and where it leads). The library checked the override when the rules loaded, but a folder on the way can
    /// change since: a symlink pointed elsewhere moves a literal path out of the built-in glob. So `RuleEngine` and
    /// `RuleScope` (the guard, the rule index) check again here, with the paths they are about to use.
    func checkedPaths(home: String = PathUtil.home) -> (kept: [String], leftOut: [(written: String, resolved: String)]) {
        let resolved = paths.map { PathUtil.canonicalPattern($0, home: home) }
        guard let narrowing else { return (resolved, []) }
        let builtinPaths = narrowing.builtinPaths.map { PathUtil.canonicalPattern($0, home: home) }
        let exclusions = narrowing.builtinExclusions.map { PathUtil.canonicalPattern($0, home: home) }
        var kept: [String] = []
        var leftOut: [(written: String, resolved: String)] = []
        for (written, path) in zip(paths, resolved) {
            if RuleLibrary.staysWithin(canonical: path, builtinPaths: builtinPaths, exclusions: exclusions) {
                kept.append(path)
            } else {
                leftOut.append((written, path))
            }
        }
        return (kept, leftOut)
    }
}
