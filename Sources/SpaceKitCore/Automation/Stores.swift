import Foundation

/// What the agent remembers about each job between runs.
public struct JobState: Codable, Sendable {
    /// When the agent first saw the job; the first run is scheduled after this.
    public var firstSeen: Date
    public var lastRun: Date?
    public var lastOutcome: String?
    /// Bytes the last run matched.
    public var lastMatchedBytes: UInt64?
    /// Bytes the last run would clean (after conditions).
    public var lastEligibleBytes: UInt64?

    public init(firstSeen: Date = Date()) { self.firstSeen = firstSeen }
}

public struct JobStateStore: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    public func load() -> [String: JobState] {
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        return (try? JSONDecoder.spaceKit.decode([String: JobState].self, from: data)) ?? [:]
    }

    public func update(_ jobID: String, _ change: (inout JobState) -> Void) throws {
        try modify { states in
            var state = states[jobID] ?? JobState()
            change(&state)
            states[jobID] = state
        }
    }

    /// Reads, changes and writes every job's state while holding the store's lock, so the agent, the CLI
    /// and the app don't overwrite each other's updates.
    public func modify(_ change: (inout [String: JobState]) throws -> Void) throws {
        try FileLock.withLock(for: file) {
            var states = load()
            try change(&states)
            let encoder = JSONEncoder.spaceKit
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try LockedFile.write(try encoder.encode(states), to: file)
        }
    }
}

/// A cleanup a `suggest` job prepared and is waiting for approval.
public struct Suggestion: Codable, Sendable, Identifiable {
    public var id: String
    public var jobID: String
    public var jobName: String
    public var created: Date
    public var plan: CleanupPlan

    public init(jobID: String, jobName: String, plan: CleanupPlan, created: Date = Date()) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.jobID = jobID
        self.jobName = jobName
        self.created = created
        self.plan = plan
    }
}

public struct SuggestionStore: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    public func all() -> [Suggestion] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        return ((try? JSONDecoder.spaceKit.decode([Suggestion].self, from: data)) ?? []).sorted { $0.created > $1.created }
    }

    /// Shortest id prefix `get` accepts, so a stray character can't pick a cleanup to approve.
    public static let minimumPrefix = 4

    /// The suggestion with exactly this id, or else the only one whose id starts with it
    /// (at least `minimumPrefix` characters).
    public func get(_ id: String) -> Suggestion? {
        let list = all()
        if let exact = list.first(where: { $0.id == id }) { return exact }
        guard id.count >= SuggestionStore.minimumPrefix else { return nil }
        let matches = list.filter { $0.id.hasPrefix(id) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Adds a suggestion, replacing any older one from the same job.
    public func add(_ suggestion: Suggestion) throws {
        try modify { list in
            list.removeAll { $0.jobID == suggestion.jobID }
            list.append(suggestion)
        }
    }

    public func remove(_ id: String) throws {
        try modify { list in list.removeAll { $0.id == id } }
    }

    private func modify(_ change: (inout [Suggestion]) -> Void) throws {
        try FileLock.withLock(for: file) {
            var list = all()
            change(&list)
            try LockedFile.write(try JSONEncoder.spaceKit.encode(list), to: file)
        }
    }
}

/// Posts user notifications.
public protocol Notifier: Sendable {
    func notify(title: String, body: String)
}

/// Notifications via `osascript`, which works from the CLI and the launchd agent without an app bundle.
public struct AppleScriptNotifier: Notifier {
    public init() {}

    public func notify(title: String, body: String) {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\" sound name \"default\""
        _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10)
    }
}
