import Foundation

/// Config and rule files decide what SpaceKit removes and which tools it runs, and the background agent reads
/// them unattended. A file another account could have written (or could still replace) is not read.
enum FileTrust {
    /// Why `path` can't be trusted, or `nil` if only this user (or root) can change it. A missing file is not a
    /// problem here; callers handle that on their own.
    static func problem(with path: String, owners: Set<uid_t> = FileTrust.owners()) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        if !owners.contains(st.st_uid) { return "is owned by another user" }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "can be changed by other users (group or world writable)" }
        let real = PathUtil.realpath(path) ?? path
        if aclAllowsOthers(real, fileWrites, owner: st.st_uid) {
            return "can be changed by other users (its access control list allows it)"
        }
        // The folder of the path and, for a symlink, of its target: others could replace the file there.
        let folders = Set([PathUtil.parent(path), PathUtil.parent(real)])
        for folder in folders.sorted() where isOpenToOthers(folder) {
            return "is in a folder other users can change (\(PathUtil.abbreviate(folder)))"
        }
        return nil
    }

    /// Accounts whose config and rule files `user` trusts: their own, and root's.
    static func owners(user: uid_t = geteuid()) -> Set<uid_t> { [user, 0] }

    /// For SpaceKit's built-in rules, also the owner of the running program: whoever installed SpaceKit installed
    /// those files with it (an app copied in by another admin, a shared Homebrew prefix, a run under sudo).
    static func builtinOwners(user: uid_t = geteuid(), executable: String? = Bundle.main.executablePath) -> Set<uid_t> {
        var trusted = owners(user: user)
        var st = stat()
        if let executable, stat(executable, &st) == 0 { trusted.insert(st.st_uid) }
        return trusted
    }

    /// Writable by group or others without the sticky bit, which would stop them replacing this user's files, or
    /// open to others through its access control list.
    private static func isOpenToOthers(_ folder: String) -> Bool {
        var st = stat()
        guard stat(folder, &st) == 0 else { return false }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 && st.st_mode & S_ISVTX == 0 { return true }
        return aclAllowsOthers(PathUtil.realpath(folder) ?? folder, folderWrites, owner: st.st_uid)
    }
}
