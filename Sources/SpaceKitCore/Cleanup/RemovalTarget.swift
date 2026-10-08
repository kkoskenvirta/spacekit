import Foundation

/// One thing to remove, read from the disk once: where it is, what is there, and every fact the guard judges.
///
/// The guard, the Trash-or-delete decision and the removal itself all work from the same target, so a symlink swapped
/// between two of them can't make the removal act somewhere the guard never looked. The parent folder is resolved
/// once, the folder and the item are pinned by device and inode, and the removal refuses whatever no longer matches
/// them.
public struct RemovalTarget: Sendable, Equatable {
    /// A file's device and inode: the same file, wherever it is and whatever its path says now.
    public struct Identity: Sendable, Hashable {
        public let device: dev_t
        public let inode: ino_t

        init(_ st: stat) {
            device = st.st_dev
            inode = st.st_ino
        }
    }

    /// The path as the plan names it, `~` expanded and standardized, never trimmed. Not absolute: the guard refuses it.
    public let path: String
    /// The folder the item is removed from, every symlink resolved. `nil` when that folder doesn't exist.
    public let directory: String?
    /// The last component: what is removed from `directory`.
    public let name: String
    /// The item as stored on disk, unless it is a symlink (removing a link removes the link, not its target).
    public let onDiskPath: String?
    /// What was at `directory`/`name` when the target was built. `nil`: nothing was.
    public let identity: Identity?
    /// The folder `directory` named when the target was built. `nil` when it couldn't be opened without symlinks.
    let directoryIdentity: Identity?
    public let isFolder: Bool
    /// The later of the item's modification and status-change times, when it exists.
    let lastChange: Date?
    public let isRepository: Bool
    public let containsRepository: Bool
    /// Bytes the removal would free, as the plan recorded them or as measured just before removal.
    public private(set) var size: UInt64

    /// The item with its folder resolved: the location that changes.
    public var resolvedPath: String { directory.map { PathUtil.join($0, name) } ?? path }

    /// Every spelling the guard checks: as named, with its folder resolved, and as stored on disk. A symlink in a parent
    /// folder can't smuggle a protected location in under another name.
    public var spellings: [String] {
        PathUtil.unique([path, resolvedPath, onDiskPath].compactMap { $0 })
    }

    /// Something was there when the target was built.
    public var exists: Bool { identity != nil }

    /// Where the target is and what was there: its resolved path, and the folder and the item by device and inode.
    struct Location: Sendable, Equatable {
        let resolvedPath: String
        let directory: Identity?
        let item: Identity?
    }

    var location: Location { Location(resolvedPath: resolvedPath, directory: directoryIdentity, item: identity) }

    /// This target with the size measured just before removal.
    func measured(_ size: UInt64) -> RemovalTarget {
        var target = self
        target.size = size
        return target
    }

    /// Modified or had its status changed (created, renamed into place) after `date`.
    func changed(after date: Date) -> Bool {
        lastChange.map { $0 > date } ?? false
    }
}

extension RemovalTarget {
    /// Builds the target for `rawPath` from the disk as it is now. The one place a removal's location is resolved.
    ///
    /// `isRepository` and `containsRepository` are what a scan recorded. `probingRepositories` adds what the disk says
    /// now: removal probes, since a plan can be stale; reviews don't, since probing every row of a large plan would stall
    /// them. `resolve` turns the parent folder into its real location. The executor passes its own, which tests replace
    /// to swap symlinks at the worst moment.
    static func at(
        _ rawPath: String, home: String, size: UInt64, isRepository: Bool, containsRepository: Bool, probingRepositories: Bool,
        resolve: (String) -> String? = PathUtil.realpath
    ) -> RemovalTarget {
        // `~name` would otherwise expand relative to the working directory.
        let isAbsolute = rawPath.hasPrefix("/") || rawPath == "~" || rawPath.hasPrefix("~/")
        // Exactly as given, trailing spaces and all: `report ` and `report` are different items.
        let path = isAbsolute ? PathUtil.expandArgument(rawPath, home: home) : rawPath
        let name = PathUtil.lastComponent(path)
        guard isAbsolute, path != "/", let directory = resolve(PathUtil.parent(path)) else {
            return RemovalTarget(
                path: path, directory: nil, name: name, onDiskPath: nil, identity: nil, directoryIdentity: nil, isFolder: false,
                lastChange: nil, isRepository: isRepository, containsRepository: containsRepository, size: size)
        }

        let resolvedPath = PathUtil.join(directory, name)
        let (directoryIdentity, entry) = pin(name, in: directory)
        let kind = entry.map { $0.st_mode & S_IFMT }
        let isFolder = kind == S_IFDIR
        let onDiskPath = entry != nil && kind != S_IFLNK ? PathUtil.realpath(resolvedPath) : nil

        let probes = probingRepositories && isFolder
        return RemovalTarget(
            path: path, directory: directory, name: name, onDiskPath: onDiskPath, identity: entry.map(Identity.init),
            directoryIdentity: directoryIdentity, isFolder: isFolder, lastChange: entry.map(lastChange),
            isRepository: isRepository || (probes && RepositoryProbe.isRepository(resolvedPath)),
            containsRepository: containsRepository || (probes && RepositoryProbe.containsRepository(resolvedPath)), size: size)
    }

    /// A plain file directly inside this target's folder, found through `fd` (the folder, opened by
    /// `Remover.openDirectory(of:)`) as `st`. Used for loose files, whose target is the folder's `*`; the file's location
    /// derives from the folder's, so it can't be resolved anywhere else. A plain file is never a repository.
    func entry(_ entryName: String, stat st: stat, namedIn folder: String) -> RemovalTarget {
        let resolvedPath = directory.map { PathUtil.join($0, entryName) }
        let isLink = st.st_mode & S_IFMT == S_IFLNK
        return RemovalTarget(
            path: PathUtil.join(folder, entryName), directory: directory, name: entryName,
            onDiskPath: isLink ? nil : resolvedPath.flatMap(PathUtil.realpath), identity: Identity(st),
            directoryIdentity: directoryIdentity, isFolder: false, lastChange: RemovalTarget.lastChange(st), isRepository: false,
            containsRepository: false, size: FileSize.allocated(st))
    }

    /// Opens `directory` with no symlink allowed in any component, confirms the kernel's path for the handle is
    /// `directory`, and reads the folder's identity and the entry `name` through that handle.
    ///
    /// A folder that can't be pinned (no read permission, or swapped already) leaves the folder's identity unset, and
    /// the item is described by path alone; removal then refuses it with the reason it couldn't open the folder.
    private static func pin(_ name: String, in directory: String) -> (Identity?, stat?) {
        var st = stat()
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            var folder = stat()
            if SafeRemoval.currentPath(of: fd) == directory, fstat(fd, &folder) == 0 {
                return (Identity(folder), fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil)
            }
        }
        return (nil, lstat(PathUtil.join(directory, name), &st) == 0 ? st : nil)
    }

    static func lastChange(_ st: stat) -> Date {
        func time(_ ts: timespec) -> Date { Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9) }
        return max(time(st.st_mtimespec), time(st.st_ctimespec))
    }
}
