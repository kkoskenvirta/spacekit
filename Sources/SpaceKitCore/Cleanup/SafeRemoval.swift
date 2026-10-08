import Foundation

/// Removal through a directory handle, so the folder that was checked is the folder that is changed.
///
/// The executor resolves an item's parent folder before asking the `SafetyGuard`. Between that check and the
/// removal, a parent could be swapped for a symlink to somewhere protected. Opening the checked path with no
/// symlinks allowed anywhere, confirming the handle's path, and then removing by name relative to that handle
/// closes the gap. Moving to the Trash has no handle-based API, so for that the path is re-verified immediately
/// before the move.
enum SafeRemoval {
    struct Refused: LocalizedError {
        var errorDescription: String?
    }

    /// Everything removable inside the item was removed, but some entries couldn't be.
    struct Incomplete: LocalizedError {
        /// The first entry that couldn't be removed.
        var path: String
        var reason: String
        /// Entries that couldn't be removed.
        var count: Int

        var errorDescription: String? {
            "Couldn't remove \(path): \(reason)" + (count > 1 ? " (and \(count - 1) more)" : "")
        }
    }

    /// Opens `path` as a directory, refusing symlinks in any component and a handle whose path isn't exactly
    /// `expected` (the resolved path the guard checked).
    static func openDirectory(_ path: String, expecting expected: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        guard currentPath(of: fd) == expected else {
            close(fd)
            throw Refused(errorDescription: "\(path) changed after it was checked; nothing was removed")
        }
        return fd
    }

    static func openDirectory(_ path: String) throws -> Int32 {
        try openDirectory(path, expecting: path)
    }

    /// The path the kernel has for an open handle.
    static func currentPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Deletes `name` (recursively if it's a folder; a symlink is removed as a link) inside the checked folder.
    static func delete(_ name: String, inDirectory directory: String) throws {
        let fd = try openDirectory(directory)
        defer { close(fd) }
        try delete(name, in: fd, directory: directory)
    }

    /// Deletes `name` inside the folder open as `fd`, never by path. Every step is relative to a handle opened with
    /// `O_NOFOLLOW`, so a folder swapped for a symlink mid-way is removed as a link, a deep tree never hits
    /// `PATH_MAX`, and losing search permission on a folder above doesn't matter.
    ///
    /// Throws `Incomplete` when some entries couldn't be removed (everything else is gone), and `Refused` when a
    /// folder was moved while the walk was inside it (the walk stops there).
    static func delete(_ name: String, in fd: Int32, directory: String) throws {
        let entry = Array(name.utf8CString)
        let path = PathUtil.join(directory, name)
        let top = openat(fd, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard top >= 0 else {
            // A file or a symlink: remove the entry itself, never what a link points to.
            guard errno == ENOTDIR || errno == ELOOP, unlinkat(fd, entry, 0) == 0 else { throw posixError(path) }
            return
        }
        var walk = TreeWalk(root: path)
        try walk.remove(entry, opened: top, in: fd)
        if let failure = walk.firstFailure {
            throw Incomplete(path: failure.path, reason: String(cString: strerror(failure.code)), count: walk.failureCount)
        }
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

    /// Confirms `directory` still resolves to itself (no symlink swapped in) right before a path-based operation.
    static func verifyUnchanged(_ directory: String) throws {
        close(try openDirectory(directory))
    }

    static func posixError(_ path: String) -> Error {
        let code = errno
        return CocoaError(
            .fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
