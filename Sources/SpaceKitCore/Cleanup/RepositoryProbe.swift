import Foundation

/// Re-reads git working copies at removal time, since a plan's `isRepository`/`containsRepository` can be stale.
enum RepositoryProbe {
    /// `.git` (a folder, or the file worktrees and submodules use) directly inside `path`.
    static func isRepository(_ path: String) -> Bool {
        var st = stat()
        return lstat(PathUtil.join(path, ".git"), &st) == 0
    }

    /// A `.git` somewhere below `path`'s subfolders. The search is bounded so a huge tree can't stall a cleanup;
    /// beyond the bound the scan's answer (which the executor keeps) stands. Symlinks are not followed.
    static func containsRepository(_ path: String) -> Bool {
        var queue: [(path: String, depth: Int)] = [(path, 0)]
        var index = 0
        while index < queue.count, index < maxDirectories {
            let (directory, depth) = queue[index]
            index += 1
            guard let handle = opendir(directory) else { continue }
            defer { closedir(handle) }
            while let entry = readdir(handle) {
                let name = entryName(entry)
                if name == "." || name == ".." { continue }
                if name == ".git" {
                    if directory != path { return true }
                    continue
                }
                if Int32(entry.pointee.d_type) == DT_DIR && depth + 1 < maxDepth {
                    queue.append((PathUtil.join(directory, name), depth + 1))
                }
            }
        }
        return false
    }

    private static let maxDepth = 6
    private static let maxDirectories = 5_000

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { buffer in
            String(decoding: buffer.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }
    }
}
