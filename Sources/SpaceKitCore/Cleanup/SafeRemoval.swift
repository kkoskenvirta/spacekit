import Foundation

/// Removal through directory handles, so the folder that was checked is the folder that is changed.
///
/// `Remover` opens a target's pinned folder through `openDirectory(_:pinned:)` and checks the entry with
/// `verifyEntry(_:in:)`; deletion then never leaves handles: every step is relative to a folder opened with
/// `O_NOFOLLOW` (see `TreeWalk`), and a folder on a different device than the item (a volume mounted inside it) is
/// left alone.
enum SafeRemoval {
    /// Nothing was removed: what is there isn't what was checked, or it can't be removed safely.
    struct Refused: LocalizedError {
        var errorDescription: String?

        /// What is at `path` isn't what was checked.
        static func changed(_ path: String) -> Refused {
            Refused(errorDescription: "\(path) changed after it was checked; nothing was removed")
        }
    }

    /// Emptying a folder began and stopped part way, because a folder was moved while the walk was inside it.
    struct Stopped: LocalizedError {
        var errorDescription: String?
    }

    /// Everything removable inside the item was removed, but some entries couldn't be.
    struct Incomplete: LocalizedError {
        /// The first entry that couldn't be removed.
        var path: String
        var reason: String
        /// Entries that couldn't be removed.
        var count: Int
        /// Folders also left because another volume is mounted on them.
        var leftOnOtherVolumes: [String] = []

        var errorDescription: String? {
            "Couldn't remove \(path): \(reason)" + (count > 1 ? " (and \(count - 1) more)" : "")
        }
    }

    /// Reads the device of an open folder.
    typealias DeviceReader = @Sendable (Int32) -> dev_t?

    /// Opens `path` as a directory, refusing symlinks in any component, a handle whose path isn't exactly `path` (the
    /// resolved folder the guard checked), and a folder that isn't `pinned` (one put in its place since).
    static func openDirectory(_ path: String, pinned: RemovalTarget.Identity?) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        var st = stat()
        guard currentPath(of: fd) == path, fstat(fd, &st) == 0, let pinned, RemovalTarget.Identity(st) == pinned else {
            close(fd)
            throw Refused.changed(path)
        }
        return fd
    }

    /// Confirms the entry `target.name` of the folder open as `fd` is still what the target pinned, and on the same
    /// device as the folder (not a volume mounted there since).
    static func verifyEntry(_ target: RemovalTarget, in fd: Int32) throws {
        let path = target.resolvedPath
        var st = stat()
        guard fstatat(fd, target.name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(path) }
        guard let pinned = target.identity, RemovalTarget.Identity(st) == pinned else {
            throw Refused.changed(path)
        }
        var folder = stat()
        guard fstat(fd, &folder) == 0 else { throw posixError(target.directory ?? path) }
        guard folder.st_dev == st.st_dev else {
            throw Refused(
                errorDescription: "\(path) is on another volume than its folder (something is mounted there); nothing was removed")
        }
    }

    /// The path the kernel has for an open handle.
    static func currentPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func device(of fd: Int32) -> dev_t? {
        var st = stat()
        return fstat(fd, &st) == 0 ? st.st_dev : nil
    }

    /// File systems that number a file by where its entry sits. An empty file has nothing else to go by there, so
    /// moving it (to the Trash, say) gives it a new inode.
    static let unstableInodeFileSystems: Set<String> = ["msdos", "exfat"]

    /// Whether the volume of the folder open as `fd` keeps a file's inode when the file moves. A volume that can't be
    /// read counts as keeping them, so the stricter check applies.
    static func keepsInodes(on fd: Int32) -> Bool {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return true }
        let name = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return !unstableInodeFileSystems.contains(name)
    }

    /// Deletes the target's entry inside its folder, open as `fd`, never by path: recursively if the target is a
    /// folder, as the entry itself otherwise (a symlink is removed as a link). Every step is relative to a handle opened
    /// with `O_NOFOLLOW`, so a folder swapped for a symlink mid-way is removed as a link, a deep tree never hits
    /// `PATH_MAX`, and losing search permission on a folder above doesn't matter.
    ///
    /// Only what the target pinned goes. A folder is emptied through a handle whose device and inode are the pinned
    /// ones, so a folder renamed into the item's place after `verifyEntry` is refused; a file or a link is unlinked
    /// without `AT_REMOVEDIR`, which can't remove a folder, so one swapped in for it stays.
    ///
    /// A folder whose device differs from `fd`'s is a volume mounted inside the item: it is left as it is, with
    /// everything above it, and the rest is removed. Returns those folders' paths.
    ///
    /// Throws `Refused` (or the system's error) when nothing was removed: the entry isn't what the target pinned, the
    /// item itself is another volume, or a file couldn't be unlinked. Once emptying a folder began, throws `Incomplete`
    /// when some entries couldn't be removed (everything else is gone), and `Stopped` when a folder was moved while the
    /// walk was inside it.
    static func delete(_ target: RemovalTarget, in fd: Int32, device: @escaping DeviceReader = SafeRemoval.device(of:)) throws -> [String] {
        let entry = Array(target.name.utf8CString)
        let path = target.resolvedPath
        guard target.isFolder else {
            guard unlinkat(fd, entry, 0) == 0 else { throw posixError(path) }
            return []
        }
        guard let volume = device(fd) else { throw posixError(target.directory ?? path) }
        let top = openat(fd, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard top >= 0 else {
            // Swapped for a file or a link since the check: that isn't the folder that was checked.
            guard errno == ENOTDIR || errno == ELOOP else { throw posixError(path) }
            throw Refused.changed(path)
        }
        var st = stat()
        guard fstat(top, &st) == 0, let pinned = target.identity, RemovalTarget.Identity(st) == pinned else {
            close(top)
            throw Refused.changed(path)
        }
        guard device(top) == volume else {
            close(top)
            throw Refused(errorDescription: "\(path) is another volume (something is mounted there); nothing was removed")
        }
        var walk = TreeWalk(root: path, volume: volume, device: device)
        try walk.remove(entry, opened: top, in: fd)
        if let failure = walk.firstFailure {
            throw Incomplete(
                path: failure.path, reason: String(cString: strerror(failure.code)), count: walk.failureCount,
                leftOnOtherVolumes: walk.leftOnOtherVolumes)
        }
        return walk.leftOnOtherVolumes
    }

    /// Entries can appear while a folder is emptied; this many listings catch them, then removing it reports the rest.
    static let emptyingPasses = 3

    /// Raw names (not decoded, so any byte sequence round-trips) of the entries of the folder open as `fd`.
    static func entryNames(of fd: Int32) -> [[CChar]]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [[CChar]] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name: [CChar] = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                Array(raw.bindMemory(to: CChar.self).prefix(length)) + [0]
            }
            if name == currentFolder || name == parentFolder { continue }
            names.append(name)
        }
        return names
    }

    static let currentFolder: [CChar] = Array(".".utf8CString)
    static let parentFolder: [CChar] = Array("..".utf8CString)

    /// The error `code` describes, for `path`: by default `errno`. A caller that runs anything between the failing call
    /// and this reads `errno` right after the call and passes it.
    static func posixError(_ path: String, code: Int32 = errno) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
