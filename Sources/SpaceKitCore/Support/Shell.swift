import Foundation
import Synchronization

/// Runs external tools directly (never through a shell), with a timeout.
public enum Shell {
    /// Directories searched for tools. launchd agents start with a minimal PATH, so common
    /// package-manager locations are always included.
    public static var searchPath: [String] {
        searchPath(environmentPATH: ProcessInfo.processInfo.environment["PATH"], home: PathUtil.home)
    }

    /// Relative PATH entries are dropped: they would resolve against whatever directory SpaceKit runs in.
    static func searchPath(environmentPATH: String?, home: String) -> [String] {
        let env = environmentPATH?.split(separator: ":").map(String.init) ?? []
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.bun/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "\(home)/.orbstack/bin",
        ]
        var seen = Set<String>()
        return (env + extra).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// True for a tool name without any path: `docker`, not `/usr/bin/docker` or `../docker`.
    /// A path would bypass the name-based allowlist, and a `{…}` placeholder would let an item name pick the program.
    public static func isBareName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.contains("{")
    }

    /// Finds a tool by bare name in `directories` (`searchPath` unless a test names others), the first match in order.
    /// Paths are refused. The containing directory is canonicalized, but the tool keeps its own name: multi-call tools
    /// (rustup proxies, mise shims, bunx) pick their behavior from the name they were started as.
    public static func which(_ name: String, in directories: [String] = searchPath) -> String? {
        guard isBareName(name) else { return nil }
        for directory in directories {
            guard let real = PathUtil.realpath(directory) else { continue }
            let candidate = PathUtil.join(real, name)
            var st = stat()
            guard stat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public struct Result: Sendable {
        public var status: Int32
        /// Standard output, and standard error too unless the run kept it apart.
        public var output: String
        public var timedOut: Bool
        /// Standard error of a run that kept it apart (`separateErrors`); empty otherwise.
        public var errors: String = ""
    }

    /// How long a tool gets to exit after SIGTERM before it (and its process group) gets SIGKILL.
    static let terminationGrace: TimeInterval = 1

    /// Who started a tool, which decides the variables it keeps.
    public enum RunKind: Sendable {
        /// A person: their review showed the command, and the tool cleans the cache SpaceKit measured for them.
        case manual
        /// The background agent, with nobody watching. Any process of the person's can set the agent's variables
        /// (`launchctl setenv`), so a tool keeps only who the person is and their locale: no tool home, `XDG_*` folder
        /// or Homebrew setting that would steer what the tool deletes. HOME and TMPDIR, which decide where each tool's
        /// default cache is, come from the system instead.
        case automatic
    }

    /// Variables an automatic run's tool keeps: who the person is, and their locale (`LC_*` too). HOME and TMPDIR are
    /// set, never kept (`automaticFolders`).
    static let automaticVariables: Set<String> = ["USER", "LOGNAME", "LANG"]

    /// HOME and TMPDIR for an automatic run: SpaceKit's own home (`home`, from the password database) and the person's
    /// temporary folder as the system names it (`userTemporaryFolder`). A planted HOME would move every tool's default
    /// cache, the folder it cleans, to a folder of someone else's choosing.
    static func automaticFolders(home: String) -> [String: String] {
        var folders = ["HOME": home]
        folders["TMPDIR"] = userTemporaryFolder
        return folders
    }

    /// The person's temporary folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), which no variable moves; `nil` if the system
    /// doesn't say, and the tool then uses `/tmp`.
    static var userTemporaryFolder: String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        return String(cString: buffer)
    }

    /// An empty folder only root can change, handed to an automatic run's tools as their settings folder. A fresh
    /// temporary folder would be the person's own, which a program of theirs could fill before the tool reads it.
    public static let emptyFolder = "/var/empty"

    /// Variables an automatic run sets for its tools, so the built-in rules' tools leave the person's own settings files
    /// behind (`CommandTrust.isolatedTools`; docs/SAFETY.md lists what each tool reads): Docker reads its contexts,
    /// plugins and credential helpers from `emptyFolder`, Go reads no env file and starts no other toolchain, npm reads
    /// no user or global npmrc, uv no `uv.toml`, and xcrun doesn't consult its lookup cache in the person's temporary
    /// folder. Any program of the person's can write those files, and the tools run with Full Disk Access.
    public static let isolationVariables: [String: String] = [
        "DOCKER_CONFIG": emptyFolder,
        "GOENV": "off", "GOTOOLCHAIN": "local",
        "NPM_CONFIG_USERCONFIG": "/dev/null", "NPM_CONFIG_GLOBALCONFIG": "/dev/null",
        "UV_NO_CONFIG": "1",
        "xcrun_nocache": "1",
    ]

    /// Variables a manual run's tool keeps from SpaceKit's environment: who and where the person is, their locale, and
    /// the variables that move a tool's own cache, so a tool cleans the cache SpaceKit measured. DEVELOPER_DIR isn't one:
    /// it picks the folder `xcrun` starts developer tools from, so any process of the person's could set it (through
    /// `launchctl setenv`) to a folder of its own and have its program run with SpaceKit's Full Disk Access.
    static let keptVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "LANG", "TMPDIR",
        "CARGO_HOME", "RUSTUP_HOME", "GOPATH", "GOMODCACHE", "GOCACHE", "npm_config_cache", "NPM_CONFIG_CACHE", "PNPM_HOME",
        "YARN_CACHE_FOLDER", "GRADLE_USER_HOME", "OLLAMA_MODELS",
    ]
    /// `HOMEBREW_*` covers Homebrew's own settings, which decide what `brew cleanup` keeps (HOMEBREW_NO_CLEANUP_FORMULAE,
    /// HOMEBREW_CLEANUP_MAX_AGE_DAYS) as well as its cache and prefix.
    static let keptPrefixes = ["LC_", "XDG_", "HOMEBREW_"]
    /// Parts of a name that mark a credential, which stays behind even under a kept prefix (HOMEBREW_GITHUB_API_TOKEN).
    static let credentialMarks = ["TOKEN", "PASSWORD", "PASSWD", "SECRET", "KEY", "AUTH", "CREDENTIAL"]

    /// The folders of `folders` an automatic run's tools search: those nothing of the person's can change (`changeable`
    /// finds what could). Only each folder is judged, not the programs in it: an entry can still lead to a program the
    /// person can change (a link in `/usr/local/bin` into an app in `/Applications`). So the program `/usr/bin/env`
    /// starts for a script is judged on its own (`CommandTrust.automaticRefusal`). A helper a tool starts by name isn't,
    /// and no built-in rule's command is known to start one: xcrun, which would look on this PATH for a tool its
    /// developer folder lacks, runs only when the folder has the tool (`CommandTrust.settingsRefusal`).
    static func automaticSearchPath(_ folders: [String], changeable: (String) -> String?) -> [String] {
        folders.filter { changeable($0) == nil }
    }

    /// The environment a tool runs with: for a manual run `keptVariables` and `keptPrefixes` from `environment`, minus
    /// credentials, and PATH set to `searchPath`; for an automatic run `automaticVariables` and `LC_*`, HOME and TMPDIR
    /// from `automaticFolders(home:)`, PATH set to `automaticSearchPath` of it (`changeable` finds what the person could
    /// change; tests stand in their own) and `isolationVariables`. Everything else stays behind. A variable can point a tool somewhere else entirely
    /// (DOCKER_HOST at another machine's daemon, OLLAMA_HOST at another server), load code into it (DYLD_*,
    /// NODE_OPTIONS) or hand it credentials (tokens, SSH_AUTH_SOCK), and SpaceKit runs with Full Disk Access, often
    /// from an agent nobody watches. Every tool SpaceKit starts gets it, its own helpers too (launchctl, tmutil,
    /// osascript, open), so no caller can forget it.
    public static func toolEnvironment(
        from environment: [String: String], home: String, kind: RunKind = .manual,
        changeable: (String) -> String? = CommandTrust.changeablePart(of:)
    ) -> [String: String] {
        var kept = environment.filter { name, _ in
            if kind == .automatic { return automaticVariables.contains(name) || name.hasPrefix("LC_") }
            guard keptVariables.contains(name) || keptPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
            let upper = name.uppercased()
            return !credentialMarks.contains { upper.contains($0) }
        }
        let folders = searchPath(environmentPATH: environment["PATH"], home: home)
        guard kind == .automatic else {
            kept["PATH"] = folders.joined(separator: ":")
            return kept
        }
        kept["PATH"] = automaticSearchPath(folders, changeable: changeable).joined(separator: ":")
        return kept.merging(automaticFolders(home: home)) { _, set in set }.merging(isolationVariables) { _, isolated in isolated }
    }

    /// Runs a tool and waits until it has exited and closed its output, or until `timeout`. A tool that is still
    /// running then, or left a background child holding its output, is sent SIGTERM and then SIGKILL; its
    /// process group goes with it. Timed-out runs report status -2. The tool gets `toolEnvironment(from:kind:)` of
    /// `environment`, never SpaceKit's own environment as is. An automatic run's tool starts in the root folder, so no
    /// project settings in the folder SpaceKit happened to start in (`go.mod`, `.npmrc`, `uv.toml`) reach it.
    /// `separateErrors` keeps standard error out of `output` (in `errors`), for a tool whose output is read as an
    /// answer, where a warning must not pass for one.
    public static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 120,
        environment: [String: String] = ProcessInfo.processInfo.environment, separateErrors: Bool = false, kind: RunKind = .manual
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = toolEnvironment(from: environment, home: PathUtil.home, kind: kind)
        if kind == .automatic { process.currentDirectoryURL = URL(fileURLWithPath: "/") }
        process.standardInput = FileHandle.nullDevice
        let capture = Capture(process, separateErrors: separateErrors)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            capture.close()
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
        let timedOut = !finished(process.processIdentifier, exited: exited, ended: capture.ended, timeout: timeout)
        capture.close()
        return Result(
            status: timedOut ? -2 : process.terminationStatus, output: capture.output.text, timedOut: timedOut,
            errors: capture.errors.text)
    }

    /// Waits until the tool has exited and its output has ended, for at most `timeout`. A tool that hasn't by then
    /// gets SIGTERM, then SIGKILL after `terminationGrace`, with its process group. True when it finished in time.
    private static func finished(_ pid: pid_t, exited: DispatchSemaphore, ended: DispatchGroup, timeout: TimeInterval) -> Bool {
        // Process starts each tool in its own process group, so the group holds everything it spawned.
        let ownsGroup = getpgid(pid) == pid
        let deadline = DispatchTime.now() + timeout
        var hasExited = exited.wait(timeout: deadline) == .success
        var hasEnded = hasExited && ended.wait(timeout: deadline) == .success
        if hasExited && hasEnded { return true }
        func send(_ signal: Int32) {
            if ownsGroup { killpg(pid, signal) } else if !hasExited { kill(pid, signal) }
        }
        send(SIGTERM)
        let graceEnd = DispatchTime.now() + terminationGrace
        if !hasExited { hasExited = exited.wait(timeout: graceEnd) == .success }
        if hasExited && !hasEnded { hasEnded = ended.wait(timeout: graceEnd) == .success }
        if !(hasExited && hasEnded) {
            send(SIGKILL)
            if !hasExited { _ = exited.wait(timeout: .now() + terminationGrace) }
        }
        return false
    }

    /// A tool's output pipes and what has been read from them: standard output, and standard error in the same pipe
    /// unless it is kept apart.
    private struct Capture {
        let pipes: [Pipe]
        let output = OutputBuffer()
        let errors = OutputBuffer()
        /// Left once per pipe, when that pipe reaches its end.
        let ended = DispatchGroup()

        init(_ process: Process, separateErrors: Bool) {
            let pipe = Pipe()
            let errorPipe = separateErrors ? Pipe() : nil
            pipes = [pipe] + (errorPipe.map { [$0] } ?? [])
            process.standardOutput = pipe
            process.standardError = errorPipe ?? pipe
            for (reading, buffer) in zip(pipes, [output, errors]) {
                ended.enter()
                reading.fileHandleForReading.readabilityHandler = { [ended] handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil }
                    if buffer.append(chunk) { ended.leave() }
                }
            }
        }

        func close() {
            for reading in pipes {
                reading.fileHandleForReading.readabilityHandler = nil
                try? reading.fileHandleForReading.close()
            }
        }
    }

    /// Keeps the last 64 KB of a tool's output.
    private final class OutputBuffer: Sendable {
        private static let limit = 64 * 1024
        private let state = Mutex<(data: Data, ended: Bool)>((Data(), false))

        /// Returns true exactly once, when the output reaches its end.
        func append(_ chunk: Data) -> Bool {
            state.withLock { state in
                if chunk.isEmpty {
                    defer { state.ended = true }
                    return !state.ended
                }
                state.data.append(chunk)
                if state.data.count > 2 * OutputBuffer.limit { state.data = Data(state.data.suffix(OutputBuffer.limit)) }
                return false
            }
        }

        var text: String {
            state.withLock { String(decoding: $0.data.suffix(OutputBuffer.limit), as: UTF8.self) }
        }
    }
}
