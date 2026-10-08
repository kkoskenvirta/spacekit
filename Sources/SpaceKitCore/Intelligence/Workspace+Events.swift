import Foundation
import Synchronization

extension Workspace {
    /// The tree and the analysis as of one moment, for a front end to show.
    public struct State: Sendable {
        public let tree: ScanTree?
        public let result: AnalysisResult?
        /// Rules being re-evaluated after their tool command ran (their cards show a spinner).
        public let refreshingRules: Set<String>
    }

    /// A read of the tree begun on one thread and ended on another (`Workspace.beginRead`). The tree doesn't change
    /// until the lease ends; ending it more than once counts once, and a lease let go of without `end` ends then.
    public final class ReadLease: Sendable {
        /// The tree as it was when the read began.
        public let tree: ScanTree?
        private let ending: Mutex<(@Sendable () -> Void)?>

        init(tree: ScanTree?, end: @escaping @Sendable () -> Void) {
            self.tree = tree
            ending = Mutex(end)
        }

        public func end() {
            let end = ending.withLock { ending in
                defer { ending = nil }
                return ending
            }
            end?()
        }

        deinit { end() }
    }

    /// What a step did, for the front end to show and to fix its selection by.
    public enum Event: Sendable {
        /// The latest analysis finished. Cleanups that finished while it ran are already applied to its result.
        case analysed(State)
        case analysisFailed(any Error)
        /// The tree or the findings changed in place.
        case changed(Change)
        /// Rules re-evaluated after their tool command ran have new findings, or the re-evaluation ended.
        case refreshed(State)
    }

    /// One change made to the tree and the findings: a cleanup's removals, or a folder scanned again.
    public struct Change: Sendable {
        public let state: State
        /// What the cleanup removed (none when a folder was re-synced).
        public let removals: [Removal]
        /// Folders scanned again and spliced in: they keep their node, but everything inside them has new ones.
        public let rescanned: [String]
        /// The Explore tree changed (not only the findings or a separate analysis tree).
        public let treeChanged: Bool
        /// Nodes taken out of the tree. `DirNode.parent` doesn't keep a parent alive, so a node the front end still
        /// holds could lose its way to the root once these go; kept until the front end has let go of this change.
        let retired: [DirNode]

        /// True if what was at `path` (where it was before this change) was removed, moved away, or replaced by a
        /// rescan of a folder around it.
        public func isGone(_ path: String) -> Bool {
            let path = originalPath(of: path)
            return removals.contains { $0.covers(path) } || rescanned.contains { PathUtil.isStrictAncestor($0, of: path) }
        }

        /// The folder a front end that showed `node` should show now: `node` itself if the change left it where it
        /// was, otherwise the nearest folder still in the tree at or above where it was. `nil` without a tree.
        public func survivor(of node: DirNode) -> DirNode? {
            guard let tree = state.tree else { return nil }
            let path = originalPath(of: node.path)
            return tree.node(at: path) === node ? node : tree.nearestNode(to: path)
        }

        /// Where something now at `path` was before this change: items moved to the Trash are inside their new place.
        private func originalPath(of path: String) -> String {
            for removal in removals where !removal.partial && removal.kind != .looseFiles {
                guard let destination = removal.trashedTo, PathUtil.isAncestorOrEqual(destination, of: path) else { continue }
                return removal.path + path.dropFirst(destination.count)
            }
            return path
        }
    }
}
