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

    /// Finds a tool by bare name in `searchPath`. Paths are refused. The containing directory is canonicalized,
    /// but the tool keeps its own name: multi-call tools (rustup proxies, mise shims, bunx) pick their behavior
    /// from the name they were started as.
    public static func which(_ name: String) -> String? {
        guard isBareName(name) else { return nil }
        for directory in searchPath {
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
        public var output: String
        public var timedOut: Bool
    }

    /// How long a tool gets to exit after SIGTERM before it (and its process group) gets SIGKILL.
    static let terminationGrace: TimeInterval = 1

    /// Runs a tool and waits until it has exited and closed its output, or until `timeout`. A tool that is still
    /// running then, or left a background child holding its output, is sent SIGTERM and then SIGKILL; its
    /// process group goes with it. Timed-out runs report status -2.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let output = OutputBuffer()
        let ended = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            if output.append(chunk) { ended.signal() }
        }
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
        let pid = process.processIdentifier
        // Process starts each tool in its own process group, so the group holds everything it spawned.
        let ownsGroup = getpgid(pid) == pid

        let deadline = DispatchTime.now() + timeout
        var hasExited = exited.wait(timeout: deadline) == .success
        var hasEnded = hasExited && ended.wait(timeout: deadline) == .success
        let timedOut = !(hasExited && hasEnded)
        if timedOut {
            func send(_ signal: Int32) {
                if ownsGroup { killpg(pid, signal) } else if !hasExited { kill(pid, signal) }
            }
            send(SIGTERM)
            let graceEnd = DispatchTime.now() + terminationGrace
            if !hasExited { hasExited = exited.wait(timeout: graceEnd) == .success }
            if hasExited && !hasEnded { hasEnded = ended.wait(timeout: graceEnd) == .success }
            if !(hasExited && hasEnded) {
                send(SIGKILL)
                if !hasExited { hasExited = exited.wait(timeout: .now() + terminationGrace) == .success }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        return Result(status: timedOut ? -2 : process.terminationStatus, output: output.text, timedOut: timedOut)
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
