import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

@Suite("Launch agent")
struct LaunchAgentTests {
    /// Plays launchctl: the old agent stays listed for a few polls after bootout, and the first bootstrap fails
    /// with EIO the way launchd does while it is still unloading.
    final class FakeLaunchctl: Sendable {
        let calls = Mutex<[[String]]>([])
        let state = Mutex((listedPolls: 3, failedBootstraps: 1))

        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            calls.withLock { $0.append(arguments) }
            return state.withLock { state in
                switch arguments.first {
                case "print":
                    guard state.listedPolls > 0 else { return (113, "Could not find service") }
                    state.listedPolls -= 1
                    return (0, "state = running")
                case "bootstrap":
                    guard state.failedBootstraps == 0 else {
                        state.failedBootstraps -= 1
                        return (5, "Bootstrap failed: 5: Input/output error")
                    }
                    return (0, "")
                default:
                    return (0, "")
                }
            }
        }
    }

    func agent(_ tree: TempTree, _ fake: FakeLaunchctl) -> LaunchAgent {
        LaunchAgent(
            paths: SpaceKitPaths(configFile: tree.path("custom/config.yaml"), stateDirectory: tree.path("state")),
            directory: tree.path("LaunchAgents"), launchctl: { fake.run($0) }, pause: { _ in })
    }

    @Test("Reinstalling waits for launchd to unload the old agent and retries bootstrap")
    func reinstall() throws {
        let tree = try TempTree()
        let fake = FakeLaunchctl()
        try agent(tree, fake).install(executable: "/usr/local/bin/spacekit", interval: 3600)
        let verbs = fake.calls.withLock { $0.map { $0[0] } }
        let firstBootstrap = try #require(verbs.firstIndex(of: "bootstrap"))
        #expect(verbs.prefix(firstBootstrap).filter { $0 == "print" }.count == 4)
        #expect(verbs.filter { $0 == "bootstrap" }.count == 2)
    }

    @Test("The plist carries the config and state paths and a clamped interval")
    func plistContents() throws {
        let tree = try TempTree()
        let installed = agent(tree, FakeLaunchctl())
        #expect(try installed.install(executable: "/usr/local/bin/spacekit", interval: 10) == 300)
        let plist = try #require(NSDictionary(contentsOfFile: installed.plistPath))
        let environment = try #require(plist["EnvironmentVariables"] as? [String: String])
        #expect(environment["SPACEKIT_CONFIG"] == tree.path("custom/config.yaml"))
        #expect(environment["SPACEKIT_STATE_DIR"] == tree.path("state"))
        #expect(plist["StartInterval"] as? Int == 300)
        #expect(try installed.install(executable: "/usr/local/bin/spacekit", interval: .infinity) == 86_400)
        #expect(LaunchAgent.clampedInterval(.nan) == 300)
    }

    @Test("The plist is written 0644 in a folder made 0755, whatever the umask")
    func plistModes() throws {
        let tree = try TempTree()
        let installed = agent(tree, FakeLaunchctl())
        try withUmask(0o077) { _ = try installed.install(executable: "/usr/local/bin/spacekit", interval: 3600) }
        #expect(FileTrustTests.mode(installed.directory) == 0o755)
        #expect(FileTrustTests.mode(installed.plistPath) == 0o644)
    }

    @Test("The agent runs the bundled CLI, else the running spacekit, else spacekit on PATH, links resolved")
    func executable() throws {
        let tree = try TempTree()
        let real = try tree.file("bin/spacekit-real/spacekit", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: real)
        let none: () -> String? = { nil }
        #expect(LaunchAgent.spacekitExecutable(bundle: tree.path("App"), running: tree.path("link"), onPath: none) == nil)
        try FileManager.default.createSymbolicLink(atPath: tree.path("spacekit"), withDestinationPath: real)
        #expect(LaunchAgent.spacekitExecutable(bundle: tree.path("App"), running: tree.path("spacekit"), onPath: none) == real)
        #expect(LaunchAgent.spacekitExecutable(bundle: tree.path("App"), running: "/x/SpaceKitApp", onPath: { tree.path("spacekit") }) == real)

        let helper = try tree.file("SpaceKit.app/Contents/Helpers/spacekit", bytes: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        #expect(LaunchAgent.spacekitExecutable(bundle: tree.path("SpaceKit.app"), running: "/x/SpaceKitApp", onPath: none) == helper)
        #expect(LaunchAgent.isDevelopmentBuild("/src/spacekit/.build/debug/spacekit"))
        #expect(!LaunchAgent.isDevelopmentBuild("/opt/homebrew/bin/spacekit"))
    }
}
