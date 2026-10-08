import Foundation

/// Path helpers. All SpaceKit paths are plain absolute POSIX strings; `~` is expanded at the edges.
public enum PathUtil {
    /// The real user's home directory, even when `HOME` points elsewhere.
    public static var home: String {
        resolveHome(environment: ProcessInfo.processInfo.environment, honorsOverride: honorsHomeOverride)
    }

    /// `SPACEKIT_HOME` points the guard's notion of home at a sandbox. A release build that honoured it
    /// would strip every home protection from the real home, so only debug builds read it.
    #if DEBUG
        static let honorsHomeOverride = true
    #else
        static let honorsHomeOverride = false
    #endif

    static func resolveHome(environment: [String: String], honorsOverride: Bool) -> String {
        if honorsOverride, let override = environment["SPACEKIT_HOME"], !override.isEmpty {
            return standardize(override)
        }
        return standardize(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Expands a leading `~` and `$HOME`, then standardizes.
    public static func expand(_ path: String, home: String = PathUtil.home) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "~" {
            p = home
        } else if p.hasPrefix("~/") {
            p = home + p.dropFirst(1)
        }
        p = p.replacingOccurrences(of: "$HOME", with: home)
        return standardize(p)
    }

    /// Replaces the home prefix with `~` for display.
    public static func abbreviate(_ path: String, home: String = PathUtil.home) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Collapses `.`, `..` and duplicate slashes without touching the file system.
    public static func standardize(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return standardize(FileManager.default.currentDirectoryPath + "/" + path)
        }
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves symlinks in every component. Returns `nil` if the path doesn't exist.
    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves symlinks in the parent directory but not the final component,
    /// so a symlink is identified as itself rather than as its target.
    public static func resolveParent(_ path: String) -> String {
        let std = standardize(path)
        if std == "/" { return "/" }
        let parent = (std as NSString).deletingLastPathComponent
        let name = (std as NSString).lastPathComponent
        guard let realParent = realpath(parent) else { return std }
        return realParent == "/" ? "/" + name : realParent + "/" + name
    }

    /// `pattern` with symlinks resolved in the part of its glob-free prefix that exists, so it names locations
    /// the way a scan reports them (`/tmp/x/*` → `/private/tmp/x/*`). Globs stay as written, and the last
    /// component of a glob-free pattern isn't followed: a pattern naming a symlink means the link. Returns
    /// `pattern` itself when nothing resolves differently, or when it isn't an absolute or `~` path.
    public static func canonicalPattern(_ pattern: String, home: String = PathUtil.home) -> String {
        guard pattern.hasPrefix("/") || pattern == "~" || pattern.hasPrefix("~/") else { return pattern }
        let expanded = expand(pattern, home: home)
        let parts = components(expanded).map(String.init)
        let literal = parts.prefix { !isGlob($0) }.count
        var used = literal == parts.count ? literal - 1 : literal
        while used > 0 {
            if let base = realpath("/" + parts[0..<used].joined(separator: "/")) {
                let result = parts[used...].reduce(base) { join($0, $1) }
                return result == expanded ? pattern : result
            }
            used -= 1
        }
        return pattern
    }

    /// The form two paths are compared in when deciding whether one is protected. APFS is case-insensitive
    /// and normalization-insensitive by default, so `~/library` and `~/Library` are the same folder; comparing
    /// keys means a different spelling can't slip past a protected list. On a case-sensitive volume this
    /// over-matches, which only ever blocks more.
    public static func comparisonKey(_ path: String) -> String {
        path.lowercased().precomposedStringWithCanonicalMapping
    }

    /// True if `pattern` contains glob characters (`*`, `?`, `[`).
    public static func isGlob(_ pattern: String) -> Bool {
        pattern.contains { "*?[".contains($0) }
    }

    /// True if `path` is a location `pattern` describes, or lies inside one. `pattern` is an expanded path
    /// that may contain globs.
    public static func isInside(_ path: String, pattern: String) -> Bool {
        guard isGlob(pattern) else { return isAncestorOrEqual(pattern, of: path) }
        return matches(path, glob: pattern) || matches(path, glob: pattern + "/**")
    }

    /// True if `path` is a strict ancestor of a location `pattern` could describe: each of its components
    /// matches the pattern's component at the same depth, and the pattern goes deeper. Nothing is read from
    /// disk, so a folder counts as containing a match even before one exists there.
    public static func couldContain(_ path: String, pattern: String) -> Bool {
        guard isGlob(pattern) else { return isStrictAncestor(path, of: pattern) }
        let parts = components(path)
        let globParts = components(pattern)
        for (index, part) in parts.enumerated() {
            guard index < globParts.count else { return false }
            if globParts[index] == "**" { return true }
            guard fnmatch(String(globParts[index]), String(part), 0) == 0 else { return false }
        }
        return parts.count < globParts.count
    }

    public static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    /// True if `ancestor` equals `path` or contains it (component-wise, not string-prefix).
    public static func isAncestorOrEqual(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    public static func isStrictAncestor(_ ancestor: String, of path: String) -> Bool {
        ancestor != path && isAncestorOrEqual(ancestor, of: path)
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Expands shell-style globs (`*`, `?`, `[...]`) after `~` expansion. Non-glob paths are returned as-is if they exist.
    public static func glob(_ pattern: String, home: String = PathUtil.home) -> [String] {
        let expanded = expand(pattern, home: home)
        guard isGlob(expanded) else {
            return FileManager.default.fileExists(atPath: expanded) ? [expanded] : []
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(expanded, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// `fnmatch(3)` with `**` support (matches across `/`).
    public static func matches(_ path: String, glob pattern: String, home: String = PathUtil.home) -> Bool {
        let expanded = pattern.hasPrefix("~") ? expand(pattern, home: home) : pattern
        if expanded.contains("**") {
            let regex =
                "^"
                + NSRegularExpression.escapedPattern(for: expanded)
                .replacingOccurrences(of: "\\*\\*/", with: "(.*/)?")
                .replacingOccurrences(of: "\\*\\*", with: ".*")
                .replacingOccurrences(of: "\\*", with: "[^/]*")
                .replacingOccurrences(of: "\\?", with: "[^/]") + "$"
            return path.range(of: regex, options: .regularExpression) != nil
        }
        return fnmatch(expanded, path, FNM_PATHNAME) == 0
    }
}
