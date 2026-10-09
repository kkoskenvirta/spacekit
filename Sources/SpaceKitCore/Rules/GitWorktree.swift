import Foundation

/// A linked git worktree: a folder whose `.git` is a file naming its metadata folder in another repository's
/// `.git/worktrees/` (or a bare repository's `worktrees/`), the way `git worktree add` leaves it. Submodules also
/// have a `.git` file, but theirs names a folder in `.git/modules/`, so they aren't worktrees.
public struct GitWorktree: Sendable, Equatable {
    /// `<repository>/.git/worktrees/<name>`, as the `.git` file names it, with `.` and `..` resolved.
    public let metadata: String
    /// The metadata folder is gone: the repository was deleted or moved, or `git worktree prune` dropped the entry.
    /// Git can't use the worktree any more.
    public let isOrphaned: Bool
    /// When git last recorded something for the worktree (its index, HEAD or reflog), which commits and checkouts
    /// change without touching the worktree's own files. `nil` when orphaned.
    public let lastGitActivity: Date?

    /// The repository the worktree belongs to: the folder holding `.git`, or the bare repository itself.
    public var repository: String { Self.repository(of: metadata) }

    /// The worktree at `folder`, or `nil` when `folder` isn't one, or is one whose state can't be told. Reads only
    /// `folder/.git` and a few entries of the metadata folder it names; a symlinked `.git` doesn't count.
    public static func at(_ folder: String) -> GitWorktree? {
        guard let gitdir = gitdir(in: folder) else { return nil }
        // Git writes a relative gitdir from the worktree's real location.
        let base = PathUtil.realpath(folder) ?? folder
        let metadata = PathUtil.standardize(gitdir.hasPrefix("/") ? gitdir : PathUtil.join(base, gitdir))
        guard PathUtil.lastComponent(PathUtil.parent(metadata)) == "worktrees" else { return nil }
        var st = stat()
        if stat(metadata, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            let activity = activityEntries.compactMap { modified(PathUtil.join(metadata, $0)) }.max()
            return GitWorktree(metadata: metadata, isOrphaned: false, lastGitActivity: activity)
        }
        // Orphaned only when the metadata folder is surely gone: missing while the folder around the repository is
        // there. A volume that isn't mounted, or a folder that can't be read, says nothing about whether it's in use.
        guard errno == ENOENT, isDirectory(PathUtil.parent(repository(of: metadata))) else { return nil }
        return GitWorktree(metadata: metadata, isOrphaned: true, lastGitActivity: nil)
    }

    private static func repository(of metadata: String) -> String {
        let gitFolder = PathUtil.parent(PathUtil.parent(metadata))
        return PathUtil.lastComponent(gitFolder) == ".git" ? PathUtil.parent(gitFolder) : gitFolder
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// What git updates in the metadata folder as the worktree is used.
    private static let activityEntries = ["index", "HEAD", "logs/HEAD"]
    /// A `.git` file holds one short line; anything larger isn't one.
    private static let maxGitFileSize = 4_096

    /// The path after `gitdir: ` in `folder/.git`, if that is a plain file in git's format.
    private static func gitdir(in folder: String) -> String? {
        let path = PathUtil.join(folder, ".git")
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxGitFileSize,
            let data = FileManager.default.contents(atPath: path),
            let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first,
            line.hasPrefix("gitdir: ")
        else { return nil }
        let gitdir = line.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespaces)
        return gitdir.isEmpty ? nil : gitdir
    }

    private static func modified(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }
}
