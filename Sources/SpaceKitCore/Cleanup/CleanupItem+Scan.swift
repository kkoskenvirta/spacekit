import Foundation

extension DirNode {
    /// Whether this folder is a git working copy, and whether one is somewhere inside it, from the scan's markers.
    /// Both are `false` when the scan didn't record `.git`.
    public func repositoryFlags(_ markers: MarkerRegistry?) -> (isRepository: Bool, containsRepository: Bool) {
        let git = markers?.bit(for: ".git") ?? 0
        return (self.markers & git != 0, subtreeMarkers & git != 0)
    }
}

extension CleanupItem {
    /// An entry picked in `tree` (Explore), with the git facts the guard asks about and the tree's scan start time.
    /// `nil` for the block of smaller files, which has no path of its own.
    public init?(_ item: DiskItem, in tree: ScanTree, ruleID: String?) {
        guard let path = item.path else { return nil }
        let repository = item.directory?.repositoryFlags(tree.markers) ?? (isRepository: false, containsRepository: false)
        self.init(
            path: path, kind: item.isDirectory ? .directory : .file, name: item.name, size: item.size, ruleID: ruleID,
            isRepository: repository.isRepository, containsRepository: repository.containsRepository, lastUsed: item.modified,
            scanStarted: tree.scanStarted)
    }
}
