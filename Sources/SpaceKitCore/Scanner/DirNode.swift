import Foundation
import Synchronization

/// A file large enough to be tracked individually (see `ScanOptions.minFileSize`).
public struct FileLeaf: Sendable, Hashable {
    public let name: String
    /// Allocated bytes on disk.
    public let size: UInt64
    /// Modification time, seconds since 1970.
    public let modified: Int64
}

/// One directory in a scan tree.
///
/// Memory layout is deliberately compact: directories are objects, but files are only kept
/// individually when they're at least `ScanOptions.minFileSize`; smaller files are folded into
/// `otherFilesSize` / `otherFilesCount`. That keeps a full-disk scan of millions of files in a
/// few hundred megabytes while still drawing every file that's big enough to see.
///
/// Thread-safety: `@unchecked Sendable` rests on who writes when, not on immutability.
/// - During a scan, the worker that lists a directory writes its stored properties, then publishes it
///   (`isListed`, release/acquire). Other threads may read only `name`, `isListed` and `liveSize` of the
///   nodes in `ScanProgress.liveChildren`.
/// - When the workers finish, the scanning thread resolves hard links and aggregates totals (sorting
///   `children` in place) before `Scanner.scan` returns.
/// - After that, the tree changes only through `ScanTree.applyRemoval`, `applyMove`, `splice` and `rescan`, which
///   the tree's owner calls from one thread or actor at a time. Reads on other threads must be
///   synchronized with those calls by the owner. The app and the TUI leave that to `Workspace`: other threads read
///   only inside `Workspace.read` or a read lease, and changes wait for those reads, then run on the front end's own
///   thread.
public final class DirNode: @unchecked Sendable, Identifiable, Hashable {
    /// Folder name; roots are named by their absolute path. Changes only when an item is moved (e.g. to the Trash).
    public internal(set) var name: String
    /// Parent directory. Valid for as long as the owning `ScanTree` is alive.
    public private(set) unowned(unsafe) var parent: DirNode?
    public internal(set) var depth: Int

    // Filled in by the worker that lists this directory.
    public internal(set) var children: [DirNode] = []
    public internal(set) var files: [FileLeaf] = []
    /// Combined size of files smaller than the tracking threshold.
    public internal(set) var otherFilesSize: UInt64 = 0
    public internal(set) var otherFilesCount: UInt32 = 0
    /// Bytes of all files directly in this directory (tracked and folded).
    public internal(set) var directFileSize: UInt64 = 0
    public internal(set) var directFileCount: UInt32 = 0
    /// Bit set of marker names (e.g. `package.json`, `.git`) present directly in this directory.
    public internal(set) var markers: UInt64 = 0
    public internal(set) var newestModified: Int64 = 0
    public internal(set) var newestAccessed: Int64 = 0
    public internal(set) var flags: Flags = []

    // Filled in by aggregation once the scan finishes.
    /// Allocated bytes of the whole subtree.
    public internal(set) var size: UInt64 = 0
    public internal(set) var fileCount: UInt64 = 0
    public internal(set) var dirCount: UInt64 = 0
    public internal(set) var subtreeMarkers: UInt64 = 0
    public internal(set) var subtreeNewestModified: Int64 = 0
    public internal(set) var subtreeNewestAccessed: Int64 = 0

    // Live values readable while the scan runs.
    let liveBytes = Atomic<UInt64>(0)
    let listed = Atomic<Bool>(false)

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Permission denied or I/O error while listing. Usually means Full Disk Access is missing.
        public static let unreadable = Flags(rawValue: 1 << 0)
        /// A different volume that was not traversed.
        public static let otherVolume = Flags(rawValue: 1 << 1)
        /// A data-volume path that is also reachable through a firmlink; skipped to avoid double counting.
        public static let firmlinkDuplicate = Flags(rawValue: 1 << 2)
        /// Matched an exclude pattern.
        public static let excluded = Flags(rawValue: 1 << 3)

        public static let skipped: Flags = [.otherVolume, .firmlinkDuplicate, .excluded]
    }

    init(name: String, parent: DirNode?) {
        self.name = name
        self.parent = parent
        self.depth = (parent?.depth ?? -1) + 1
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public static func == (lhs: DirNode, rhs: DirNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// Absolute path. Root nodes store their absolute path as `name`, so the walk stops at the first
    /// ancestor whose name starts with `/`.
    public var path: String {
        if name.hasPrefix("/") || parent == nil { return name }
        var parts: [String] = [name]
        var cursor = parent
        while let node = cursor {
            if node.name.hasPrefix("/") {
                let tail = parts.reversed().joined(separator: "/")
                return node.name == "/" ? "/" + tail : node.name + "/" + tail
            }
            parts.append(node.name)
            cursor = node.parent
        }
        return "/" + parts.reversed().joined(separator: "/")
    }

    /// Short name for display: the last path component, even for a root node named by its full path.
    public var displayName: String {
        if name == "/" { return VolumeCapacity.of(path: "/")?.name ?? "Macintosh HD" }
        return name.hasPrefix("/") ? PathUtil.lastComponent(name) : name
    }

    /// `id` as a number, for string keys.
    public var address: UInt { UInt(bitPattern: id) }

    /// Bytes counted so far during a running scan (only maintained for shallow nodes).
    public var liveSize: UInt64 { liveBytes.load(ordering: .relaxed) }

    /// True once this directory's entries have been read; `children` is then safe to read during a scan.
    public var isListed: Bool { listed.load(ordering: .acquiring) }

    public var isSkipped: Bool { !flags.intersection(.skipped).isEmpty }

    /// Newest modification anywhere in the subtree, used as "last used".
    ///
    /// Access times are deliberately not used here: Spotlight, backup and antivirus tools read files in the
    /// background, so a folder nobody has touched in months can show an access time of a few minutes ago.
    /// They're still recorded (`subtreeNewestAccessed`) for model weights, where reads do mean use.
    public var lastUsed: Date? {
        subtreeNewestModified > 0 ? Date(timeIntervalSince1970: TimeInterval(subtreeNewestModified)) : nil
    }

    public func child(named name: String) -> DirNode? {
        children.first { $0.name == name }
    }

    /// Ancestors from the root down to (but excluding) this node.
    public var ancestors: [DirNode] {
        var result: [DirNode] = []
        var cursor = parent
        while let node = cursor {
            result.append(node)
            cursor = node.parent
        }
        return result.reversed()
    }

    /// Items to display for this directory: subdirectories, tracked files and the folded remainder, largest first.
    public var items: [DiskItem] {
        var result: [DiskItem] = []
        result.reserveCapacity(children.count + files.count + 1)
        for child in children where child.size > 0 || child.isSkipped || child.flags.contains(.unreadable) {
            result.append(.directory(child))
        }
        for file in files { result.append(.file(file, parent: self)) }
        if otherFilesSize > 0 { result.append(.otherFiles(parent: self)) }
        result.sort { $0.size > $1.size }
        return result
    }

    /// Visits every node in the subtree (pre-order) without recursion.
    public func forEachDescendant(_ body: (DirNode) -> Bool) {
        var stack: [DirNode] = [self]
        while let node = stack.popLast() {
            if body(node) { stack.append(contentsOf: node.children) }
        }
    }

    func setParent(_ parent: DirNode?) { self.parent = parent }

    /// True if this node is `top` or lies under it.
    func isWithin(_ top: DirNode) -> Bool {
        var cursor: DirNode? = self
        while let node = cursor {
            if node === top { return true }
            cursor = node.parent
        }
        return false
    }

    /// Takes a hard-linked file's bytes off its link `name`, which stays counted as a file of 0 bytes (so it's no
    /// longer tracked). Updates this folder's direct totals only. Returns false if the tracked entry is missing.
    @discardableResult
    func dropLinkBytes(named name: String, size: UInt64, minFileSize: UInt64) -> Bool {
        if size >= minFileSize && size > 0 {
            guard let index = files.firstIndex(where: { $0.name == name }) else { return false }
            files.remove(at: index)
            otherFilesCount += 1
        } else {
            otherFilesSize -= min(otherFilesSize, size)
        }
        directFileSize -= min(directFileSize, size)
        return true
    }

    /// Gives a hard-linked file's bytes to its link `name`, until now counted as a file of 0 bytes. Updates this
    /// folder's direct totals only.
    func addLinkBytes(named name: String, size: UInt64, modified: Int64, minFileSize: UInt64) {
        if size >= minFileSize && size > 0 {
            otherFilesCount -= min(otherFilesCount, 1)
            let index = files.firstIndex { $0.size < size } ?? files.count
            files.insert(FileLeaf(name: name, size: size, modified: modified), at: index)
        } else {
            otherFilesSize &+= size
        }
        directFileSize &+= size
    }
}

/// Something that occupies space inside a directory.
public enum DiskItem: Identifiable, Sendable, Hashable {
    case directory(DirNode)
    case file(FileLeaf, parent: DirNode)
    /// Files below the tracking threshold, shown as one block.
    case otherFiles(parent: DirNode)

    public var id: String {
        switch self {
        case .directory(let node): return "d:\(node.address)"
        case .file(let leaf, let parent): return "f:\(parent.address):\(leaf.name)"
        case .otherFiles(let parent): return "o:\(parent.address)"
        }
    }

    public var size: UInt64 {
        switch self {
        case .directory(let node): return node.size
        case .file(let leaf, _): return leaf.size
        case .otherFiles(let parent): return parent.otherFilesSize
        }
    }

    public var name: String {
        switch self {
        case .directory(let node): return node.name
        case .file(let leaf, _): return leaf.name
        case .otherFiles(let parent):
            let n = parent.otherFilesCount
            return "\(n) smaller file\(n == 1 ? "" : "s")"
        }
    }

    public var path: String? {
        switch self {
        case .directory(let node): return node.path
        case .file(let leaf, let parent): return PathUtil.join(parent.path, leaf.name)
        case .otherFiles: return nil
        }
    }

    public var directory: DirNode? {
        if case .directory(let node) = self { return node }
        return nil
    }

    public var isDirectory: Bool { directory != nil }

    public var modified: Date? {
        switch self {
        case .directory(let node): return node.lastUsed
        case .file(let leaf, _): return leaf.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(leaf.modified)) : nil
        case .otherFiles(let parent):
            return parent.newestModified > 0 ? Date(timeIntervalSince1970: TimeInterval(parent.newestModified)) : nil
        }
    }

    public static func == (lhs: DiskItem, rhs: DiskItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
