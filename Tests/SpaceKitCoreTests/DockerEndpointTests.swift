import Foundation
import Testing

@testable import SpaceKitCore

/// A Docker set up as the test says, answering the queries SpaceKit makes before a `docker` command. Nothing runs:
/// the recording runner hands these answers back.
struct ScriptedDocker: Sendable {
    /// What `docker context inspect` prints for the active context.
    var context = Shell.Result(status: 0, output: "unix:///var/run/docker.sock\n", timedOut: false)
    /// What `docker buildx version` prints: a buildx plugin is installed unless the test says otherwise.
    var version = Shell.Result(status: 0, output: "github.com/docker/buildx v0.17.1 257815a\n", timedOut: false)
    /// What `docker buildx ls --format json` prints.
    var builders = Shell.Result(status: 0, output: "", timedOut: false)
    /// What `docker buildx inspect` prints for the selected builder.
    var inspected = Shell.Result(status: 0, output: "", timedOut: false)
    /// Endpoints of contexts by name, for `docker context inspect <name>`; others aren't found.
    var named: [String: String] = [:]

    static let activeContext = ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]
    static let builderList = ["docker", "buildx", "ls", "--format", "json"]
    static let buildxVersion = ["docker", "buildx", "version"]
    static let builderInspect = ["docker", "buildx", "inspect"]
    static func namedContext(_ name: String) -> [String] { activeContext + [name] }

    func respond(_ call: [String]) -> Shell.Result {
        if call == ScriptedDocker.activeContext { return context }
        if call == ScriptedDocker.builderList { return builders }
        if call == ScriptedDocker.buildxVersion { return version }
        if call == ScriptedDocker.builderInspect { return inspected }
        if call.count == ScriptedDocker.activeContext.count + 1, call.starts(with: ScriptedDocker.activeContext), let name = call.last {
            guard let endpoint = named[name] else {
                return Shell.Result(status: 1, output: "", timedOut: false, errors: "context \"\(name)\" does not exist\n")
            }
            return Shell.Result(status: 0, output: endpoint + "\n", timedOut: false)
        }
        return Shell.Result(status: 0, output: "", timedOut: false)
    }

    /// `docker buildx inspect` output for one builder, as buildx before 0.13 prints it too.
    static func inspect(name: String, driver: String, endpoints: [String]) -> Shell.Result {
        let nodes = endpoints.enumerated().map { index, endpoint in
            "Name:      \(name)\(index)\nEndpoint:  \(endpoint)\nStatus:    running\nBuildkit:  v0.12.5\nPlatforms: linux/arm64\n"
        }
        let text =
            "Name:          \(name)\nDriver:        \(driver)\nLast Activity: 2026-10-01 10:00:00 +0000 UTC\n\nNodes:\n"
            + nodes.joined(separator: "\n")
        return Shell.Result(status: 0, output: text, timedOut: false)
    }

    /// Docker without the buildx plugin, in the words older and newer Docker CLIs use.
    static let withoutBuildx = [
        Shell.Result(status: 1, output: "", timedOut: false, errors: "docker: 'buildx' is not a docker command.\nSee 'docker --help'\n"),
        Shell.Result(status: 1, output: "", timedOut: false, errors: "docker: unknown command: docker buildx\n\nRun 'docker --help'\n"),
    ]

    /// `docker buildx ls --format json` output: one JSON object per builder and line.
    static func builders(_ entries: [(name: String, driver: String, endpoints: [String], current: Bool)]) -> Shell.Result {
        let lines = entries.map { entry in
            let nodes = entry.endpoints.map { #"{"Name":"\#(entry.name)0","Endpoint":"\#($0)","Status":"running"}"# }
            let fields = #""Name":"\#(entry.name)","Driver":"\#(entry.driver)","Current":\#(entry.current)"#
            return "{" + fields + #","Nodes":["# + nodes.joined(separator: ",") + "]}"
        }
        return Shell.Result(status: 0, output: lines.joined(separator: "\n") + "\n", timedOut: false)
    }
}

@Suite("Docker endpoint")
struct DockerEndpointTests {
    let tree: TempTree
    let builderPrune = ["docker", "builder", "prune", "--force"]
    let imagePrune = ["docker", "image", "prune", "--all", "--force"]

    init() throws { tree = try TempTree() }

    /// Runs `command` from a built-in rule in an automatic run against `docker`; returns the outcome and every call.
    func run(_ command: [String], _ docker: ScriptedDocker) -> (outcome: CleanupOutcome?, calls: [[String]]) {
        let (outcome, runner) = runRecorded(command, docker)
        return (outcome, runner.calls)
    }

    func runRecorded(_ command: [String], _ docker: ScriptedDocker) -> (outcome: CleanupOutcome?, runner: RecordingRunner) {
        var rule = Rule(
            id: "docker.cache", name: "Docker", paths: [], granularity: .children, safety: SafetySpec(level: .safe),
            action: ActionSpec(command: command))
        rule.isBuiltin = true
        let runner = RecordingRunner(installed: ["docker"], in: tree) { docker.respond($0) }
        var executor = sandboxExecutor(tree, rules: [rule])
        executor.runner = runner
        // The stand-in docker is in the test's own folder, which an automatic run would refuse; that isn't tested here.
        executor.changeable = { _ in nil }
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: rule.id, arguments: command, estimatedBytes: 1)])
        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        return (report.commands.first?.outcome, runner)
    }

    func skipReason(_ outcome: CleanupOutcome?) -> String? {
        if case .skipped(let reason, _) = outcome { return reason }
        return nil
    }

    func context(_ endpoint: String, errors: String = "") -> Shell.Result {
        Shell.Result(status: 0, output: endpoint + "\n", timedOut: false, errors: errors)
    }

    @Test("Docker commands run only when the active context is a socket on this Mac; its warnings don't matter")
    func activeContext() {
        for endpoint in ["tcp://build.example.com:2376", "ssh://me@build.example.com", "npipe:////./pipe/docker_engine", ""] {
            let result = run(imagePrune, ScriptedDocker(context: context(endpoint)))
            #expect(skipReason(result.outcome)?.contains("Docker") == true, "\(endpoint)")
            #expect(result.calls == [ScriptedDocker.activeContext], "\(endpoint)")
        }
        // Docker Desktop, OrbStack and Colima all listen on a unix socket. A warning on standard error is not the endpoint.
        for endpoint in [
            "unix:///var/run/docker.sock", "unix:///Users/tester/.orbstack/run/docker.sock",
            "unix:///Users/tester/.colima/default/docker.sock",
        ] {
            let docker = ScriptedDocker(context: context(endpoint, errors: "WARNING: Plugin \"/x/docker-scan\" is not valid\n"))
            let result = run(imagePrune, docker)
            #expect(result.outcome?.isRemoved == true, "\(endpoint)")
            #expect(result.calls == [ScriptedDocker.activeContext, imagePrune], "\(endpoint)")
        }
    }

    @Test("When Docker can't say which context is active, nothing runs")
    func contextUnknown() {
        let failures = [
            Shell.Result(status: 1, output: "", timedOut: false, errors: "context not found: remote\n"),
            Shell.Result(status: -2, output: "unix:///var/run/docker.sock\n", timedOut: true),
            Shell.Result(status: 0, output: "unix:///var/run/docker.sock\ntcp://build.example.com:2376\n", timedOut: false),
        ]
        for failure in failures {
            let result = run(imagePrune, ScriptedDocker(context: failure))
            #expect(skipReason(result.outcome) != nil, "\(failure.output)")
            #expect(result.calls == [ScriptedDocker.activeContext])
        }
        let named = run(imagePrune, ScriptedDocker(context: failures[0]))
        #expect(skipReason(named.outcome)?.contains("context not found") == true)
    }

    @Test("docker builder commands run only when the selected buildx builder is this Mac's Docker")
    func localBuilder() {
        let local: [ScriptedDocker] = [
            // Docker Desktop: the docker driver on the active context, named by context.
            ScriptedDocker(
                builders: ScriptedDocker.builders([
                    ("default", "docker", ["default"], false), ("desktop-linux", "docker", ["desktop-linux"], true),
                ]),
                named: ["desktop-linux": "unix:///Users/tester/.docker/run/docker.sock"]),
            // A BuildKit container in the local Docker, by socket.
            ScriptedDocker(
                builders: ScriptedDocker.builders([("kit", "docker-container", ["unix:///var/run/docker.sock"], true)])),
        ]
        for docker in local {
            let result = run(builderPrune, docker)
            #expect(result.outcome?.isRemoved == true, "\(docker.builders.output)")
            #expect(result.calls.first == ScriptedDocker.activeContext && result.calls.last == builderPrune)
            #expect(result.calls.contains(ScriptedDocker.builderList))
        }
        // Commands that act on the daemon itself never ask about builders.
        #expect(run(imagePrune, local[0]).calls == [ScriptedDocker.activeContext, imagePrune])
        // Docker is asked in the environment the command gets, so it describes the Docker the command will use.
        let recorded = runRecorded(builderPrune, local[0]).runner
        #expect(recorded.kinds.count == recorded.calls.count && recorded.kinds.allSatisfy { $0 == .automatic })
    }

    @Test("A remote, cloud or unknown buildx builder, or one Docker can't describe, refuses docker builder commands")
    func remoteBuilder() {
        let refused: [(ScriptedDocker, String)] = [
            (ScriptedDocker(builders: ScriptedDocker.builders([("ci", "remote", ["tcp://buildkitd.example.com:1234"], true)])), "remote"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("cloud-me", "cloud", ["cloud://me/builder"], true)])), "cloud"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("k8s", "kubernetes", ["kubernetes:///kit"], true)])), "kubernetes"),
            (
                ScriptedDocker(builders: ScriptedDocker.builders([("kit", "docker-container", ["tcp://build.example.com:2376"], true)])),
                "tcp://build.example.com:2376"
            ),
            (
                ScriptedDocker(
                    builders: ScriptedDocker.builders([("ci", "docker", ["ci-box"], true)]), named: ["ci-box": "ssh://me@ci.example.com"]),
                "ssh://me@ci.example.com"
            ),
            (ScriptedDocker(builders: ScriptedDocker.builders([("gone", "docker", ["gone"], true)])), "does not exist"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("odd", "docker", ["-H"], true)])), "-H"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("empty", "docker-container", [], true)])), "no nodes"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("idle", "docker", ["default"], false)])), "selected"),
            (ScriptedDocker(builders: Shell.Result(status: 0, output: "{\"Name\": \"kit\", \"Driver\":\n", timedOut: false)), "buildx ls"),
            (ScriptedDocker(builders: Shell.Result(status: 0, output: "NAME/NODE DRIVER/ENDPOINT\n", timedOut: false)), "buildx ls"),
            (
                ScriptedDocker(builders: Shell.Result(status: 1, output: "", timedOut: false, errors: "unknown command: docker buildx\n")),
                "unknown command"
            ),
        ]
        for (docker, mentioning) in refused {
            let result = run(builderPrune, docker)
            let reason = skipReason(result.outcome)
            #expect(reason?.contains(mentioning) == true, "\(mentioning): \(reason ?? "ran")")
            #expect(!result.calls.contains(builderPrune), "\(mentioning)")
        }
        // Noise on standard error doesn't spoil a builder list that is fine.
        var noisy = ScriptedDocker(builders: ScriptedDocker.builders([("kit", "docker-container", ["unix:///var/run/docker.sock"], true)]))
        noisy.builders.errors = "WARNING: buildx: git was not found in the system\n"
        #expect(run(builderPrune, noisy).outcome?.isRemoved == true)
    }

    @Test("Without the buildx plugin, docker builder prunes the active context's daemon, so the context check is enough")
    func classicBuilder() {
        for missing in ScriptedDocker.withoutBuildx {
            let result = run(builderPrune, ScriptedDocker(version: missing))
            #expect(result.outcome?.isRemoved == true, "\(missing.errors)")
            #expect(result.calls == [ScriptedDocker.activeContext, ScriptedDocker.buildxVersion, builderPrune])
            // The context still has to be this Mac's.
            let remote = run(builderPrune, ScriptedDocker(context: context("tcp://build.example.com:2376"), version: missing))
            #expect(skipReason(remote.outcome)?.contains("tcp://build.example.com:2376") == true)
        }
        // buildx there but broken, or no answer: SpaceKit can't tell which builder runs. Only docker's own line on standard
        // error says the plugin is missing: not the words on standard output or inside another line.
        let failures = [
            Shell.Result(status: 1, output: "", timedOut: false, errors: "fork/exec docker-buildx: permission denied\n"),
            Shell.Result(status: -2, output: "", timedOut: true),
            Shell.Result(status: 1, output: "docker: 'buildx' is not a docker command.\n", timedOut: false),
            Shell.Result(
                status: 1, output: "", timedOut: false, errors: "buildx: plugin says docker: unknown command: docker buildx elsewhere\n"),
        ]
        for failure in failures {
            let result = run(builderPrune, ScriptedDocker(version: failure))
            #expect(skipReason(result.outcome)?.contains("docker buildx version") == true, "\(failure.errors)")
            #expect(!result.calls.contains(builderPrune))
        }
    }

    @Test("A buildx too old for ls --format json is read from docker buildx inspect; nothing readable refuses")
    func olderBuildx() {
        let noJSON = Shell.Result(status: 1, output: "", timedOut: false, errors: "unknown flag: --format\n")
        let local = [
            ScriptedDocker.inspect(name: "default", driver: "docker", endpoints: ["default"]),
            ScriptedDocker.inspect(name: "kit", driver: "docker-container", endpoints: ["unix:///var/run/docker.sock"]),
        ]
        for inspected in local {
            let docker = ScriptedDocker(builders: noJSON, inspected: inspected, named: ["default": "unix:///var/run/docker.sock"])
            let result = run(builderPrune, docker)
            #expect(result.outcome?.isRemoved == true, "\(inspected.output)")
            #expect(result.calls.contains(ScriptedDocker.builderInspect) && result.calls.last == builderPrune)
        }
        let refused: [(Shell.Result, String)] = [
            (ScriptedDocker.inspect(name: "ci", driver: "remote", endpoints: ["tcp://buildkitd.example.com:1234"]), "remote"),
            (ScriptedDocker.inspect(name: "kit", driver: "docker-container", endpoints: ["ssh://me@ci.example.com"]), "ssh://"),
            (ScriptedDocker.inspect(name: "kit", driver: "docker-container", endpoints: []), "no nodes"),
            (Shell.Result(status: 0, output: "Name: kit\nDriver: docker\nDriver: remote\nEndpoint: default\n", timedOut: false), "inspect"),
            (Shell.Result(status: 0, output: "Name: kit\nEndpoint: default\n", timedOut: false), "inspect"),
            (Shell.Result(status: 0, output: "", timedOut: false), "unknown flag: --format"),
            (Shell.Result(status: 1, output: "", timedOut: false, errors: "no builder \"kit\" found\n"), "no builder"),
        ]
        for (inspected, mentioning) in refused {
            let result = run(
                builderPrune, ScriptedDocker(builders: noJSON, inspected: inspected, named: ["default": "unix:///var/run/docker.sock"]))
            let reason = skipReason(result.outcome)
            #expect(reason?.contains(mentioning) == true, "\(mentioning): \(reason ?? "ran")")
            #expect(!result.calls.contains(builderPrune), "\(mentioning)")
        }
    }
}
