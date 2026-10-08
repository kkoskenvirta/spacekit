import Foundation

/// Disk usage the way the scanner measures it: allocated blocks, not logical length, so sparse and
/// compressed files count what they actually occupy.
public enum FileSize {
    /// Allocated bytes of one entry, without following a final symlink. `nil` if it doesn't exist.
    public static func allocated(atPath path: String) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return allocated(st)
    }

    public static func allocated(_ st: stat) -> UInt64 {
        UInt64(max(0, st.st_blocks)) * 512
    }
}
