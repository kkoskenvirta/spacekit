import Foundation

/// Where SpaceKit keeps its files. The CLI, TUI, app and background agent all share these.
///
/// - Config (yours, dotfile-friendly): `~/.config/spacekit/config.yaml`, rules in `~/.config/spacekit/rules/`
/// - State (SpaceKit's): `~/Library/Application Support/SpaceKit/` — history, journal, job state, suggestions
///
/// Override with `SPACEKIT_CONFIG` (config file) and `SPACEKIT_STATE_DIR` (state directory).
public struct SpaceKitPaths: Sendable {
    public var configFile: String
    public var stateDirectory: String

    public init(configFile: String, stateDirectory: String) {
        self.configFile = PathUtil.expand(configFile)
        self.stateDirectory = PathUtil.expand(stateDirectory)
    }

    public static var standard: SpaceKitPaths {
        let env = ProcessInfo.processInfo.environment
        let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.config"
        let config = env["SPACEKIT_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(configHome)/spacekit/config.yaml"
        let state = env["SPACEKIT_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/Library/Application Support/SpaceKit"
        return SpaceKitPaths(configFile: config, stateDirectory: state)
    }

    public var configDirectory: String { PathUtil.parent(configFile) }
    public var userRulesDirectory: String { configDirectory + "/rules" }
    public var journalFile: String { stateDirectory + "/journal.jsonl" }
    public var historyFile: String { stateDirectory + "/history.jsonl" }
    public var jobStateFile: String { stateDirectory + "/jobs-state.json" }
    public var suggestionsFile: String { stateDirectory + "/suggestions.json" }
    public var logDirectory: String { stateDirectory + "/logs" }

    public func ensureDirectories() throws {
        for directory in [configDirectory, stateDirectory, logDirectory] {
            try LockedFile.createDirectory(directory)
        }
    }

    /// Creates the folder for the person's own rule files, as SpaceKit creates its folders (see `LockedFile`).
    public func ensureUserRulesDirectory() throws {
        try LockedFile.createDirectory(userRulesDirectory)
    }

    /// Writes a rule file SpaceKit made for the person, as SpaceKit writes its own files (see `LockedFile`), so the
    /// library doesn't refuse it as one other users could change. Replaces a file already at `path`.
    public static func writeRuleFile(_ yaml: String, to path: String) throws {
        try LockedFile.write(Data(yaml.utf8), to: path)
    }
}

/// Writes SpaceKit's own files: appends under an advisory lock, so the app and the background agent can share a
/// file, and atomic replacement.
///
/// Files are created with `fileMode` and folders with `folderMode`, set explicitly rather than left to the umask:
/// under a umask of 002 the config would come out group-writable and `FileTrust` would refuse SpaceKit's own file.
enum LockedFile {
    static let fileMode: mode_t = 0o644
    static let folderMode: mode_t = 0o755

    /// The mode a rewrite of `path` keeps: its own permissions within `fileMode`, plus owner read and write.
    static func keptMode(of path: String) -> mode_t? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (st.st_mode & fileMode) | 0o600
    }

    static func append(_ text: String, to path: String) throws {
        try createDirectory(PathUtil.parent(path))
        let fd = openForWriting(path, flags: O_WRONLY | O_APPEND)
        guard fd >= 0 else { throw failure(path) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        try writeAll(Array(text.utf8), to: fd, path: path)
    }

    /// Writes atomically: a new file next to `path`, renamed over it. A file that already exists keeps any
    /// permission the person took away (a private 0600 config stays 0600); `like` gives a new file the mode of
    /// another one, so a backup is no more open than its original. Neither ever grants group or other write.
    static func write(_ data: Data, to path: String, like original: String? = nil) throws {
        let folder = PathUtil.parent(path)
        try createDirectory(folder)
        let mode = original.flatMap(keptMode(of:)) ?? keptMode(of: path) ?? fileMode
        let temporary = PathUtil.join(folder, ".\(PathUtil.lastComponent(path)).\(UUID().uuidString)")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw failure(temporary) }
        fchmod(fd, mode)
        do {
            try writeAll(Array(data), to: fd, path: temporary)
        } catch {
            close(fd)
            unlink(temporary)
            throw error
        }
        guard close(fd) == 0, rename(temporary, path) == 0 else {
            let failed = failure(path)
            unlink(temporary)
            throw failed
        }
    }

    /// Creates `path` and any missing folders above it.
    static func createDirectory(_ path: String) throws {
        var missing: [String] = []
        var folder = PathUtil.standardize(path)
        var st = stat()
        while folder != "/" && lstat(folder, &st) != 0 {
            missing.append(folder)
            folder = PathUtil.parent(folder)
        }
        for folder in missing.reversed() {
            if mkdir(folder, folderMode) == 0 {
                chmod(folder, folderMode)
            } else if errno != EEXIST {
                throw failure(folder)
            }
        }
    }

    /// Opens `path` with `flags`, creating it with `fileMode` if it isn't there. Returns -1 on failure.
    static func openForWriting(_ path: String, flags: Int32) -> Int32 {
        let created = open(path, flags | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        if created >= 0 {
            fchmod(created, fileMode)
            return created
        }
        guard errno == EEXIST else { return -1 }
        return open(path, flags | O_CLOEXEC)
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32, path: String) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { throw failure(path) }
            offset += written
        }
    }

    private static func failure(_ path: String) -> Error {
        let reason = String(cString: strerror(errno))
        return CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "\(path): \(reason)"])
    }

    static func readLines(_ path: String) -> [Substring] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }
}

extension JSONEncoder {
    static var spaceKit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var spaceKit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
