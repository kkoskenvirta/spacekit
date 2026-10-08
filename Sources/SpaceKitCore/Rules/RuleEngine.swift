import Foundation

/// One removable unit found by a rule.
public struct FindingItem: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Codable, Sendable {
        case directory
        case file
        /// All plain files directly inside `path` (not its subdirectories).
        case looseFiles
    }

    public var path: String
    public var kind: Kind
    public var name: String
    public var size: UInt64
    public var fileCount: UInt64
    public var lastModified: Date?
    /// Best estimate of when this was last used. For project artifacts (`node_modules`, `target`) this is the
    /// project's activity, because package managers reset file dates inside them.
    public var lastUsed: Date?
    /// The item itself is a git working copy.
    public var isRepository: Bool
    /// Somewhere inside there's a git working copy.
    public var containsRepository: Bool
    /// For pattern matches, the enclosing project folder.
    public var project: String?
    /// For loose files: the names this item counted. Only these may be removed under it, so a file another rule
    /// claims (or one that appeared later) stays.
    public var looseFileNames: [String]?

    public var id: String { kind == .looseFiles ? CleanupItem.looseFilesPath(in: path) : path }

    public init(
        path: String, kind: Kind, name: String, size: UInt64, fileCount: UInt64 = 0, lastModified: Date? = nil,
        lastUsed: Date? = nil, isRepository: Bool = false, containsRepository: Bool = false, project: String? = nil,
        looseFileNames: [String]? = nil
    ) {
        self.path = path
        self.kind = kind
        self.name = name
        self.size = size
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.lastUsed = lastUsed
        self.isRepository = isRepository
        self.containsRepository = containsRepository
        self.project = project
        self.looseFileNames = looseFileNames
    }

    public var displayName: String {
        if let project { return PathUtil.lastComponent(project) + "/" + name }
        return name
    }

    /// Days since last use, if known.
    public func idleDays(now: Date = Date()) -> Int? {
        lastUsed.map { max(0, Int(Age.since($0, now: now).days)) }
    }
}

/// Everything one rule matched.
public struct Finding: Sendable, Identifiable {
    public let rule: Rule
    public var items: [FindingItem]

    public init(rule: Rule, items: [FindingItem]) {
        self.rule = rule
        self.items = items.sorted { $0.size > $1.size }
    }

    public var id: String { rule.id }
    public var size: UInt64 { items.reduce(0) { $0 &+ $1.size } }
    public var lastUsed: Date? { items.compactMap(\.lastUsed).max() }
    public var safety: SafetyLevel { rule.safety.level }
    public var isCleanable: Bool { rule.action.isCleanable && rule.safety.level != .protected }

    /// Items a cleanup with these conditions would touch.
    public func eligibleItems(olderThan: Age? = nil, keepRecent: Age? = nil, now: Date = Date()) -> [FindingItem] {
        let keepsActiveProjects = rule.exclusions.contains(where: RuleEngine.isActiveProjectsToken)
        let activeWindow: Age? = keepsActiveProjects ? rule.policy?.keepRecent ?? Job.defaultActiveProjectsWindow : nil
        let keep = keepRecent ?? activeWindow
        return items.filter { item in
            guard let used = item.lastUsed else { return olderThan == nil && keep == nil }
            let idle = now.timeIntervalSince(used)
            if let olderThan, idle < olderThan.seconds { return false }
            if let keep, idle < keep.seconds { return false }
            return true
        }
    }
}

/// Matches rules against a scan tree.
public struct RuleEngine: Sendable {
    public var rules: [Rule]
    /// Default search roots for pattern rules.
    public var devRoots: [String]

    /// Never searched by pattern rules: tool homes and app data where a `node_modules` or `build`
    /// folder belongs to an installed tool rather than to one of your projects.
    public static let defaultPatternExcludes: [String] =
        [
            "~/Library", "~/.Trash", "~/Applications", "~/.cache", "~/.local", "~/.config",
            "~/.vscode", "~/.vscode-insiders", "~/.cursor", "~/.windsurf", "~/.zed", "~/.antigravity",
            "~/.claude", "~/.codex", "~/.gemini", "~/.Spotlight-V100",
        ] + ToolHomes.developer + ToolHomes.ai

    /// Bundles are opaque: never search inside them.
    static let bundleSuffixes = [".app", ".photoslibrary", ".bundle", ".framework", ".xcarchive", ".musiclibrary", ".tvlibrary"]

    /// Problems with the rules as this engine resolved them: an override's paths it left out (`checkedOverride`).
    public let issues: [RuleIssue]

    /// Rule and root paths are resolved through symlinks once here (`PathUtil.canonicalPattern`), because
    /// the scan tree holds resolved paths: a rule for `/tmp/x` must match a scan of `/tmp`, stored as `/private/tmp`.
    public init(rules: [Rule], devRoots: [String] = ScanSettings.defaultDevRoots) {
        let checked = rules.map(RuleEngine.checkedOverride)
        self.rules = checked.map(\.rule)
        self.issues = checked.flatMap(\.issues)
        self.devRoots = devRoots.map { PathUtil.canonicalPattern($0) }
    }

    /// `canonical(rule)`; for an override, without the paths that no longer stay within the built-in rule it narrows
    /// (`Rule.checkedPaths`), each with an issue.
    static func checkedOverride(_ rule: Rule) -> (rule: Rule, issues: [RuleIssue]) {
        var resolved = canonical(rule)
        let checked = rule.checkedPaths()
        resolved.paths = checked.kept
        let issues = checked.leftOut.map { written, path in
            let message =
                "leaves out the path '\(written)': it leads to \(path) now, outside the built-in rule it narrows (a folder on the "
                + "way changed since the rules were loaded)"
            return RuleIssue(severity: .error, source: rule.source ?? RuleLibrary.inlineSource, ruleID: rule.id, message: message)
        }
        return (resolved, issues)
    }

    static func canonical(_ rule: Rule) -> Rule {
        var rule = rule
        rule.paths = rule.paths.map { PathUtil.canonicalPattern($0) }
        rule.exclusions = rule.exclusions.map { PathUtil.canonicalPattern($0) }
        if var match = rule.match {
            match.roots = match.roots?.map { PathUtil.canonicalPattern($0) }
            match.exclude = match.exclude.map { PathUtil.canonicalPattern($0) }
            rule.match = match
        }
        return rule
    }

    static func isActiveProjectsToken(_ token: String) -> Bool {
        ["active_projects", "recently_used", "active-projects"].contains(token.lowercased())
    }

    /// Paths a scan must cover for these rules to be evaluated: fixed locations that exist, plus pattern roots.
    public func requiredRoots() -> [String] {
        var roots: [String] = []
        for rule in rules {
            for pattern in rule.paths {
                // A rule may point at a single file; scan the folder that holds it.
                roots += PathUtil.glob(pattern).map { path in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    return isDirectory.boolValue ? path : PathUtil.parent(path)
                }
            }
            if let match = rule.match { roots += (match.roots ?? devRoots).map { PathUtil.expand($0) } }
        }
        let unique = Array(Set(roots.filter { FileManager.default.fileExists(atPath: $0) })).sorted()
        return unique.filter { candidate in !unique.contains { PathUtil.isStrictAncestor($0, of: candidate) } }
    }

    // MARK: Evaluation

    public func evaluate(_ tree: ScanTree) -> [Finding] {
        var claims: [Claim] = []
        for (index, rule) in rules.enumerated() where !rule.paths.isEmpty {
            for pattern in rule.paths {
                let expandedPattern = PathUtil.expand(pattern)
                for path in PathUtil.glob(pattern) where tree.covers(path) {
                    let specificity = PathUtil.components(expandedPattern).count * 2 + (rule.granularity == .children ? 1 : 0)
                    for item in items(at: path, rule: rule, tree: tree) where !isExcluded(item, by: rule) {
                        claims.append(Claim(rule: index, item: item, specificity: specificity))
                    }
                }
            }
        }
        claims += patternClaims(tree)
        claims = resolveOverlaps(claims, tree: tree)

        var grouped: [Int: [FindingItem]] = [:]
        for claim in claims { grouped[claim.rule, default: []].append(claim.item) }
        return grouped.keys.sorted().compactMap { index in
            let items = grouped[index] ?? []
            return items.isEmpty ? nil : Finding(rule: rules[index], items: items)
        }
        .sorted { $0.size > $1.size }
    }

    private struct Claim {
        var rule: Int
        var item: FindingItem
        var specificity: Int
    }

    private func items(at path: String, rule: Rule, tree: ScanTree) -> [FindingItem] {
        if let node = tree.node(at: path) {
            guard !node.isSkipped else { return [] }
            switch rule.granularity {
            case .whole: return node.size > 0 ? [Self.item(for: node, markers: tree.markers)] : []
            case .children: return Self.childItems(of: node, markers: tree.markers)
            }
        }
        // A single file. Small files aren't kept in the tree, so fall back to the file system.
        let parent = PathUtil.parent(path)
        let name = PathUtil.lastComponent(path)
        guard let directory = tree.node(at: parent), !directory.isSkipped else { return [] }
        if let leaf = directory.files.first(where: { $0.name == name }) {
            let date = Date(timeIntervalSince1970: TimeInterval(leaf.modified))
            return [FindingItem(path: path, kind: .file, name: name, size: leaf.size, fileCount: 1, lastModified: date, lastUsed: date)]
        }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { return [] }
        let date = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return [
            FindingItem(
                path: path, kind: .file, name: name, size: FileSize.allocated(st), fileCount: 1,
                lastModified: date, lastUsed: date)
        ]
    }

    static func item(for node: DirNode, markers: MarkerRegistry, project: String? = nil, lastUsed: Date? = nil) -> FindingItem {
        let repository = node.repositoryFlags(markers)
        return FindingItem(
            path: node.path,
            kind: .directory,
            name: node.name,
            size: node.size,
            fileCount: node.fileCount,
            lastModified: node.lastUsed,
            lastUsed: lastUsed ?? node.lastUsed,
            isRepository: repository.isRepository,
            containsRepository: repository.containsRepository,
            project: project
        )
    }

    static func childItems(of node: DirNode, markers: MarkerRegistry) -> [FindingItem] {
        var result: [FindingItem] = []
        for child in node.children where child.size > 0 && !child.isSkipped {
            result.append(item(for: child, markers: markers))
        }
        if let loose = looseFilesItem(of: node) { result.append(loose) }
        return result
    }

    /// The plain files directly inside `node` as one item, or `nil` if there are none with any size. `excluded`
    /// names files another rule claims, with their bytes; they're left out of the size and the names.
    static func looseFilesItem(
        of node: DirNode, path: String? = nil, excludingBytes excluded: UInt64 = 0, excludingNames excludedNames: Set<String> = []
    ) -> FindingItem? {
        guard node.directFileSize > excluded else { return nil }
        let folder = path ?? node.path
        let date = node.newestModified > 0 ? Date(timeIntervalSince1970: TimeInterval(node.newestModified)) : nil
        let names = FindingItem.plainFileNames(in: folder).filter { !excludedNames.contains($0) }
        return FindingItem(
            path: folder, kind: .looseFiles, name: "Files in \(node.name)",
            size: node.directFileSize - excluded, fileCount: UInt64(node.directFileCount),
            lastModified: date, lastUsed: date, looseFileNames: names)
    }

    private func isExcluded(_ item: FindingItem, by rule: Rule) -> Bool {
        rule.exclusions.contains { token in
            !RuleEngine.isActiveProjectsToken(token) && PathUtil.matches(item.path, glob: token)
        }
    }

    // MARK: Pattern rules

    private func patternClaims(_ tree: ScanTree) -> [Claim] {
        let patternRules = rules.enumerated().filter { $0.element.match != nil }
        guard !patternRules.isEmpty else { return [] }

        var byName: [String: [(Int, Rule, [String])]] = [:]
        var allRoots = Set<String>()
        for (index, rule) in patternRules {
            let roots = (rule.match!.roots ?? devRoots).map { PathUtil.expand($0) }
            allRoots.formUnion(roots)
            for name in rule.match!.names { byName[name, default: []].append((index, rule, roots)) }
        }
        var excluded = Set(RuleEngine.defaultPatternExcludes.map { PathUtil.expand(PathUtil.canonicalPattern($0)) })
        for (_, rule) in patternRules {
            for glob in rule.match!.exclude where !glob.contains("*") { excluded.insert(PathUtil.expand(glob)) }
        }
        let globExcludes = patternRules.flatMap { $0.element.match!.exclude.filter { $0.contains("*") } }

        let roots = allRoots.sorted().filter { candidate in !allRoots.contains { PathUtil.isStrictAncestor($0, of: candidate) } }
        let search = PatternSearch(byName: byName, excluded: excluded, globExcludes: globExcludes)
        var claims: [Claim] = []
        for root in roots {
            var stack: [(DirNode, String)] = search.starts(under: root, in: tree)
            while let (node, path) = stack.popLast() {
                for child in node.children where !child.isSkipped && child.size > 0 {
                    let childPath = PathUtil.join(path, child.name)
                    if excluded.contains(childPath) { continue }
                    if RuleEngine.bundleSuffixes.contains(where: { child.name.hasSuffix($0) }) { continue }
                    if !globExcludes.isEmpty, globExcludes.contains(where: { PathUtil.matches(childPath, glob: $0) }) { continue }

                    var matched = false
                    for (index, rule, ruleRoots) in byName[child.name] ?? [] {
                        guard ruleRoots.contains(where: { PathUtil.isAncestorOrEqual($0, of: childPath) }),
                            rule.match!.markersPresent(
                                sibling: { tree.markers.contains($0, in: node.markers) },
                                inside: { tree.markers.contains($0, in: child.markers) })
                        else { continue }
                        var item = RuleEngine.item(
                            for: child, markers: tree.markers, project: path, lastUsed: projectActivity(node, excluding: child))
                        item.name = child.name
                        if !isExcluded(item, by: rule) {
                            claims.append(Claim(rule: index, item: item, specificity: 0))
                        }
                        matched = true
                        break
                    }
                    if !matched { stack.append((child, childPath)) }
                }
            }
        }
        return claims
    }

    /// Where the pattern walk under one root begins. A tree scanned only for some rules may hold just folders
    /// below the root; the walk starts at each of them that a walk from the root would have reached.
    private struct PatternSearch {
        let byName: [String: [(Int, Rule, [String])]]
        let excluded: Set<String>
        let globExcludes: [String]

        func starts(under root: String, in tree: ScanTree) -> [(DirNode, String)] {
            if let node = tree.node(at: root) { return [(node, node.path)] }
            var starts: [(DirNode, String)] = []
            for scanned in tree.roots where PathUtil.isStrictAncestor(root, of: scanned) && isReached(scanned, from: root) {
                if let node = tree.node(at: scanned) { starts.append((node, scanned)) }
            }
            return starts
        }

        /// False if the walk from `root` stops above or at `path`: an excluded folder, a bundle, or a folder a pattern
        /// rule matches (checked on disk, since the tree doesn't hold the folders above its roots).
        private func isReached(_ path: String, from root: String) -> Bool {
            var current = root
            for component in PathUtil.components(String(path.dropFirst(root.count))) {
                let parent = current
                let name = String(component)
                current = PathUtil.join(parent, name)
                if excluded.contains(current) { return false }
                if RuleEngine.bundleSuffixes.contains(where: { name.hasSuffix($0) }) { return false }
                if globExcludes.contains(where: { PathUtil.matches(current, glob: $0) }) { return false }
                if matches(current, name: name, parent: parent) { return false }
            }
            return true
        }

        private func matches(_ path: String, name: String, parent: String) -> Bool {
            let exists = { (folder: String, entry: String) -> Bool in FileManager.default.fileExists(atPath: PathUtil.join(folder, entry)) }
            return (byName[name] ?? []).contains { _, rule, ruleRoots in
                guard let match = rule.match, ruleRoots.contains(where: { PathUtil.isAncestorOrEqual($0, of: path) }) else { return false }
                return match.markersPresent(sibling: { exists(parent, $0) }, inside: { exists(path, $0) })
            }
        }
    }

    /// When a project was last worked on, ignoring the generated folder itself.
    private func projectActivity(_ project: DirNode, excluding artifact: DirNode) -> Date? {
        var newest = project.newestModified
        for sibling in project.children where sibling !== artifact {
            newest = max(newest, sibling.subtreeNewestModified)
        }
        return newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil
    }

    // MARK: Overlaps

    /// Makes sure no byte is claimed twice. If two rules claim the same path, the more specific rule wins.
    /// If an item contains another rule's item, the outer item is split into its children so the
    /// inner item is reported (and cleaned) under its own rule. That includes another rule's loose files
    /// or single files: the outer rule never gets a folder's loose files that someone else already claims.
    private func resolveOverlaps(_ claims: [Claim], tree: ScanTree) -> [Claim] {
        var best: [String: Claim] = [:]
        for claim in claims {
            if let existing = best[claim.item.id], existing.specificity >= claim.specificity { continue }
            best[claim.item.id] = claim
        }
        var wholeClaims = Set<String>()
        var looseClaims = Set<String>()
        /// Claimed single files, by the folder that holds them.
        var fileClaims: [String: ClaimedFiles] = [:]
        for claim in best.values {
            switch claim.item.kind {
            case .directory: wholeClaims.insert(claim.item.path)
            case .looseFiles: looseClaims.insert(claim.item.path)
            case .file:
                let folder = PathUtil.parent(claim.item.path)
                fileClaims[folder, default: ClaimedFiles()].bytes &+= claim.item.size
                fileClaims[folder, default: ClaimedFiles()].names.insert(PathUtil.lastComponent(claim.item.path))
            }
        }
        // A loose-files claim takes bytes from its folder, so its folder path counts as claimed inside an ancestor.
        let claimedPaths = best.values.map(\.item.path).sorted()
        func hasClaimInside(_ path: String) -> Bool {
            let prefix = path == "/" ? "/" : path + "/"
            var low = 0
            var high = claimedPaths.count
            while low < high {
                let mid = (low + high) / 2
                if claimedPaths[mid] < prefix { low = mid + 1 } else { high = mid }
            }
            return low < claimedPaths.count && claimedPaths[low].hasPrefix(prefix)
        }
        func mustSplit(_ path: String) -> Bool { looseClaims.contains(path) || hasClaimInside(path) }

        var result: [Claim] = []
        for claim in best.values {
            if claim.item.kind == .looseFiles {
                if let loose = RuleEngine.withoutClaimedFiles(claim.item, fileClaims[claim.item.path]) {
                    result.append(Claim(rule: claim.rule, item: loose, specificity: claim.specificity))
                }
                continue
            }
            guard claim.item.kind == .directory, mustSplit(claim.item.path), let node = tree.node(at: claim.item.path) else {
                result.append(claim)
                continue
            }
            var stack = [(node, claim.item.path)]
            while let (current, currentPath) = stack.popLast() {
                for child in current.children where child.size > 0 {
                    let childPath = PathUtil.join(currentPath, child.name)
                    if wholeClaims.contains(childPath) { continue }
                    if mustSplit(childPath) {
                        stack.append((child, childPath))
                    } else {
                        result.append(
                            Claim(
                                rule: claim.rule, item: RuleEngine.item(for: child, markers: tree.markers), specificity: claim.specificity))
                    }
                }
                let claimed = fileClaims[currentPath] ?? ClaimedFiles()
                guard !looseClaims.contains(currentPath),
                    let loose = RuleEngine.looseFilesItem(
                        of: current, path: currentPath, excludingBytes: claimed.bytes, excludingNames: claimed.names)
                else { continue }
                result.append(Claim(rule: claim.rule, item: loose, specificity: claim.specificity))
            }
        }
        return result
    }
}

extension RuleEngine {
    /// Single files rules claim in one folder: their bytes and names.
    fileprivate struct ClaimedFiles {
        var bytes: UInt64 = 0
        var names: Set<String> = []
    }

    /// A loose-files claim less the single files other rules claim in the same folder. `nil` if nothing is left.
    fileprivate static func withoutClaimedFiles(_ item: FindingItem, _ claimed: ClaimedFiles?) -> FindingItem? {
        guard let claimed else { return item }
        guard item.size > claimed.bytes else { return nil }
        var loose = item
        loose.size -= claimed.bytes
        loose.looseFileNames = item.looseFileNames?.filter { !claimed.names.contains($0) }
        return loose
    }
}

extension FindingItem {
    /// Names of the plain files (anything but folders) directly inside `directory`, sorted. Empty if unreadable.
    static func plainFileNames(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { name in
            var st = stat()
            return lstat(PathUtil.join(directory, name), &st) == 0 && (st.st_mode & S_IFMT) != S_IFDIR
        }
        .sorted()
    }
}

extension PatternSpec {
    /// The marker check of a pattern match: at least one `sibling` next to the folder and at least one of
    /// `contains` inside it, each only when listed. The engine answers from scan markers, `RuleIndex` from disk.
    func markersPresent(sibling hasSibling: (String) -> Bool, inside hasInside: (String) -> Bool) -> Bool {
        (sibling.isEmpty || sibling.contains(where: hasSibling)) && (contains.isEmpty || contains.contains(where: hasInside))
    }
}
