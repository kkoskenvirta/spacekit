import Foundation

/// Installs the background agent as a per-user launchd job that runs `spacekit agent run` periodically.
/// Nothing runs as root and nothing is installed system-wide.
public struct LaunchAgent: Sendable {
    public static let label = "dev.spacekit.agent"

    /// Runs `launchctl` with these arguments and returns its exit status and output.
    public typealias Launchctl = @Sendable (_ arguments: [String]) -> (status: Int32, output: String)

    public let paths: SpaceKitPaths
    /// Where the plist goes, normally `~/Library/LaunchAgents`.
    public let directory: String
    let launchctl: Launchctl
    let pause: @Sendable (TimeInterval) -> Void

    public init(paths: SpaceKitPaths, directory: String = PathUtil.home + "/Library/LaunchAgents") {
        self.init(
            paths: paths, directory: directory,
            launchctl: { arguments in
                let result = Shell.run("/bin/launchctl", arguments, timeout: 10)
                return (result.status, result.output)
            },
            pause: { Thread.sleep(forTimeInterval: $0) })
    }

    init(paths: SpaceKitPaths, directory: String, launchctl: @escaping Launchctl, pause: @escaping @Sendable (TimeInterval) -> Void) {
        self.paths = paths
        self.directory = directory
        self.launchctl = launchctl
        self.pause = pause
    }

    public var plistPath: String { directory + "/\(LaunchAgent.label).plist" }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(LaunchAgent.label)" }

    public struct Status: Sendable {
        public var installed: Bool
        public var loaded: Bool
        public var executable: String?
        public var interval: Int?
    }

    public func status() -> Status {
        let plist = NSDictionary(contentsOfFile: plistPath)
        let arguments = plist?["ProgramArguments"] as? [String]
        return Status(
            installed: plist != nil, loaded: launchctl(["print", service]).status == 0, executable: arguments?.first,
            interval: plist?["StartInterval"] as? Int)
    }

    /// The interval in seconds launchd is given for a requested `seconds`: within `AutomationSettings.checkEveryRange`.
    public static func clampedInterval(_ seconds: TimeInterval) -> Int {
        let range = AutomationSettings.checkEveryRange
        guard !seconds.isNaN else { return Int(range.lowerBound) }
        return Int(min(max(seconds, range.lowerBound), range.upperBound))
    }

    /// The agent runs with the config and state this installer used, so `--config` and `SPACEKIT_STATE_DIR`
    /// carry over into launchd's environment.
    public func plist(executable: String, interval: Int) -> [String: Any] {
        [
            "Label": LaunchAgent.label,
            "ProgramArguments": [executable, "agent", "run"],
            "StartInterval": interval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": paths.logDirectory + "/agent.log",
            "StandardErrorPath": paths.logDirectory + "/agent.log",
            "EnvironmentVariables": ["SPACEKIT_CONFIG": paths.configFile, "SPACEKIT_STATE_DIR": paths.stateDirectory],
        ]
    }

    /// Writes the plist and (re)loads it. Returns the interval launchd was given, which may differ from
    /// `interval` (see `clampedInterval`).
    @discardableResult
    public func install(executable: String, interval: TimeInterval) throws -> Int {
        let seconds = LaunchAgent.clampedInterval(interval)
        try paths.ensureDirectories()
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(executable: executable, interval: seconds), format: .xml, options: 0)
        unload()
        // 0644 in a 0755 folder whatever the umask: launchd won't load a plist other users can write.
        try LockedFile.write(data, to: plistPath)
        var result = launchctl(["bootstrap", domain, plistPath])
        // launchd can report EIO while it is still tearing down the previous instance.
        for _ in 0..<3 where result.status != 0 {
            pause(0.5)
            result = launchctl(["bootstrap", domain, plistPath])
        }
        if result.status != 0 {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(result.output)"])
        }
        return seconds
    }

    public func uninstall() throws {
        unload()
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }

    /// Boots the agent out and waits, up to five seconds, until launchd no longer lists it.
    private func unload() {
        _ = launchctl(["bootout", service])
        for _ in 0..<50 {
            if launchctl(["print", service]).status != 0 { return }
            pause(0.1)
        }
    }
}
