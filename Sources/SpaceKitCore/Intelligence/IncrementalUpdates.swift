import Foundation

/// Something a cleanup removed, as reported by `CleanupExecutor`.
public struct Removal: Sendable, Hashable {
    public var path: String
    public var kind: FindingItem.Kind
    public var bytes: UInt64
    /// Where the item went if it was moved to the Trash.
    public var trashedTo: String?
    /// For loose files moved to the Trash: where each file went (the full path in the Trash).
    public var trashedFiles: [String]
    /// The item's deletion failed part way: `bytes` of it were deleted and the rest is still at `path`.
    public var partial: Bool

    public init(
        path: String, kind: FindingItem.Kind, bytes: UInt64, trashedTo: String? = nil, trashedFiles: [String] = [],
        partial: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.trashedTo = trashedTo
        self.trashedFiles = trashedFiles
        self.partial = partial
    }

    /// Removals in a report: successful ones (including zero-byte ones, so the tree still drops them) and
    /// items that were deleted only in part (see `CleanupReport.partiallyFreed`), or removed around a volume mounted
    /// inside them (see `CleanupReport.leftOnOtherVolumes`).
    public static func from(_ report: CleanupReport) -> [Removal] {
        report.items.compactMap { entry -> Removal? in
            if let freed = report.partiallyFreed[entry.item.path], entry.outcome.isFailed {
                return Removal(path: entry.item.path, kind: entry.item.kind, bytes: freed, partial: true)
            }
            guard entry.outcome.isRemoved else { return nil }
            if report.leftOnOtherVolumes[entry.item.path] != nil {
                return Removal(path: entry.item.path, kind: entry.item.kind, bytes: entry.outcome.freedBytes, partial: true)
            }
            let trashedFiles: [String] = entry.item.kind == .looseFiles ? (report.trashedLooseFiles[entry.item.path] ?? []) : []
            return Removal(
                path: entry.item.path, kind: entry.item.kind, bytes: entry.outcome.freedBytes, trashedTo: entry.outcome.trashedTo,
                trashedFiles: trashedFiles)
        }
    }

    /// Applies this removal to a tree: trashed items move into the Trash folder (if the tree has it),
    /// deleted ones disappear, and a partly deleted folder is rescanned. Returns true if the tree changed.
    @discardableResult
    public func apply(to tree: ScanTree) -> Bool {
        if partial { return tree.rescan(path) }
        if kind == .looseFiles {
            let taken = tree.applyRemoval(of: path, looseFilesOnly: true)
            var placed = false
            for file in trashedFiles where tree.applyArrival(of: file) { placed = true }
            return taken > 0 || placed
        }
        let before = tree.root.size
        let existed = tree.node(at: path) != nil || tree.node(at: PathUtil.parent(path)) != nil
        if let trashedTo {
            tree.applyMove(of: path, to: trashedTo, bytes: bytes)
        } else {
            tree.applyRemoval(of: path, bytes: bytes)
        }
        return existed && (tree.root.size != before || tree.node(at: path) == nil)
    }

    /// This removal for `tree`, a scan that started before the cleanup finished: the scan may have reached the item
    /// before it went, or after. `nil` when the tree doesn't show the item where it was (a file the tree counts only in
    /// its folder's small files can't be told apart, so it is left too). Only the removal from where it was is carried:
    /// whether the scan saw a moved item or loose file in the Trash can't be told (it may have walked the Trash before
    /// the move, or counted a small file only in the Trash's total), so the workspace scans the Trash again instead
    /// (`trashFolders`). A partly deleted folder is rescanned anyway.
    func carried(over tree: ScanTree) -> Removal? {
        if partial { return self }
        if kind == .looseFiles {
            guard tree.node(at: path) != nil else { return nil }
            return Removal(path: path, kind: kind, bytes: bytes)
        }
        guard tree.shows(path) else { return nil }
        return Removal(path: path, kind: kind, bytes: bytes)
    }

    /// The Trash folders this removal moved something into. Loose files name each file they moved (`trashedTo` is the
    /// Trash folder itself for them); an item names where it went.
    var trashFolders: Set<String> {
        Set((kind == .looseFiles ? trashedFiles : [trashedTo].compactMap { $0 }).map(PathUtil.parent))
    }

    /// True if this removal took away everything at `path` (the item itself or a folder containing it).
    func covers(_ path: String) -> Bool {
        !partial && kind != .looseFiles && PathUtil.isAncestorOrEqual(self.path, of: path)
    }

    /// True if this removal took all of an item of `kind` at `path`: the item or a folder around it went, or, for
    /// loose files, those of the same folder went.
    public func takesAll(of path: String, kind: FindingItem.Kind) -> Bool {
        covers(path) || (self.kind == .looseFiles && kind == .looseFiles && self.path == path)
    }

    /// True if this removal took part of `item` (but not all of it). A loose-files item only holds the plain
    /// files directly in its folder, so only a removed file in that folder takes part of it.
    func isInside(_ item: FindingItem) -> Bool {
        if partial && item.path == path { return true }
        switch (item.kind, kind) {
        case (.file, _): return false
        case (.looseFiles, .file): return PathUtil.parent(path) == item.path
        case (.looseFiles, _): return false
        case (.directory, .looseFiles): return PathUtil.isAncestorOrEqual(item.path, of: path)
        case (.directory, _): return PathUtil.isStrictAncestor(item.path, of: path)
        }
    }
}

extension ScanTree {
    /// True if the tree has a folder at `path`, or a file there it lists by name (not only in its folder's small files).
    fileprivate func shows(_ path: String) -> Bool {
        if node(at: path) != nil { return true }
        let name = PathUtil.lastComponent(path)
        return node(at: PathUtil.parent(path))?.files.contains { $0.name == name } ?? false
    }
}

extension Analysis {
    /// Updates findings after a cleanup without re-scanning: removed items disappear, items that lost
    /// something inside them shrink, and findings left empty are dropped.
    /// Returns the ids of the rules whose findings changed.
    @discardableResult
    public mutating func apply(_ removals: [Removal]) -> Set<String> {
        guard !removals.isEmpty else { return [] }
        var touched = Set<String>()
        var updated: [Finding] = []
        for finding in findings {
            var changed = false
            var items: [FindingItem] = []
            for var item in finding.items {
                if removals.contains(where: { $0.takesAll(of: item.path, kind: item.kind) }) {
                    changed = true
                    continue
                }
                // Something inside this item went away: shrink it.
                for removal in removals where removal.isInside(item) {
                    item.size -= min(item.size, removal.bytes)
                    changed = true
                }
                if item.size > 0 { items.append(item) } else { changed = true }
            }
            if changed { touched.insert(finding.rule.id) }
            if !items.isEmpty { updated.append(Finding(rule: finding.rule, items: items)) }
        }
        findings = updated.sorted { $0.size > $1.size }
        return touched
    }

    /// Replaces the findings of `ruleIDs` with fresh ones (from a targeted re-evaluation).
    public mutating func replaceFindings(for ruleIDs: Set<String>, with fresh: [Finding]) {
        findings.removeAll { ruleIDs.contains($0.rule.id) }
        findings += fresh.filter { ruleIDs.contains($0.rule.id) && !$0.items.isEmpty }
        findings.sort { $0.size > $1.size }
    }
}

extension CategoryBreakdown {
    /// Subtracts removed bytes from the matching categories instead of recomputing the whole breakdown.
    public static func subtracting(
        _ removals: [Removal], from slices: [CategorySlice], findings: [Finding],
        home: String = PathUtil.home
    ) -> [CategorySlice] {
        let locations = locations(home: home, findings: findings)
        var result = slices
        for removal in removals {
            let category = nearestCategory(for: removal.path, in: locations) ?? .other
            if let index = result.firstIndex(where: { $0.category == category }) {
                result[index].size -= min(result[index].size, removal.bytes)
            }
        }
        return result.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }
}

extension AIReport {
    /// Replaces the models that came from `ruleIDs` with those in `partial` (built from a targeted re-scan),
    /// keeping every other tool's models as they were.
    public func replacingModels(from ruleIDs: Set<String>, with partial: AIReport) -> AIReport {
        var byTool: [String: [AIModel]] = [:]
        var order: [String] = []
        for tool in tools + partial.tools {
            if byTool[tool.name] == nil { order.append(tool.name) }
            byTool[tool.name, default: []] += []
        }
        for tool in tools { byTool[tool.name, default: []] += tool.models.filter { !ruleIDs.contains($0.ruleID) } }
        for tool in partial.tools { byTool[tool.name, default: []] += tool.models.filter { ruleIDs.contains($0.ruleID) } }
        let merged = order.compactMap { name -> AITool? in
            let models = (byTool[name] ?? []).sorted { $0.size > $1.size }
            return models.isEmpty ? nil : AITool(name: name, models: models)
        }
        return AIReport(tools: merged.sorted { $0.size > $1.size }, activeWindow: activeWindow)
    }
}
