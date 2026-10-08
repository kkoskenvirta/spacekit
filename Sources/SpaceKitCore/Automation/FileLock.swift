import Foundation

/// An exclusive advisory lock for read-modify-write of one of SpaceKit's state files, shared by the app,
/// the CLI and the background agent.
///
/// The lock is taken on `<file>.lock` rather than the file itself: writes replace the file (temp file and
/// rename), and a lock held on the replaced file would no longer exclude anyone.
enum FileLock {
    static func withLock<T>(for file: String, _ body: () throws -> T) throws -> T {
        let lockPath = file + ".lock"
        try LockedFile.createDirectory(PathUtil.parent(file))
        let fd = LockedFile.openForWriting(lockPath, flags: O_RDWR)
        guard fd >= 0 else { throw error(lockPath) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw error(lockPath) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func error(_ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
