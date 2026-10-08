import Foundation

extension LaunchAgent {
    /// The `spacekit` command the agent should run: the one bundled in `SpaceKit.app/Contents/Helpers` when called
    /// from the app, the running executable when called from the CLI or TUI, else `spacekit` on PATH. Symlinks are
    /// resolved because launchd keeps the path it's given, and a Homebrew or `/usr/local/bin` link could later point
    /// elsewhere. `nil` when there's none.
    public static func spacekitExecutable() -> String? {
        spacekitExecutable(bundle: Bundle.main.bundlePath, running: Bundle.main.executablePath)
    }

    static func spacekitExecutable(bundle: String, running: String?, onPath: () -> String? = { Shell.which("spacekit") }) -> String? {
        let bundled = PathUtil.join(bundle, "Contents/Helpers/spacekit")
        let candidate: String?
        if FileManager.default.isExecutableFile(atPath: bundled) {
            candidate = bundled
        } else if let running, PathUtil.lastComponent(running) == "spacekit" {
            candidate = running
        } else {
            candidate = onPath()
        }
        return candidate.map { PathUtil.realpath($0) ?? $0 }
    }

    /// A binary in a SwiftPM build folder moves or disappears with the next clean build, so an agent shouldn't
    /// point at it.
    public static func isDevelopmentBuild(_ executable: String) -> Bool { executable.contains("/.build/") }
}
