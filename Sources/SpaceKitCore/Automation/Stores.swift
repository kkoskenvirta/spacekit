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
public struct Suggestion: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var jobID: String
    public var jobName: String
    public var created: Date
    public var plan: CleanupPlan
    /// What an earlier approval left undone, one line each; the plan then holds only what's left (`ManualJobRun`).
    public var problems: [String] = []

    public init(jobID: String, jobName: String, plan: CleanupPlan, created: Date = Date()) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.jobID = jobID
        self.jobName = jobName
        self.created = created
        self.plan = plan
    }

    enum CodingKeys: String, CodingKey { case id, jobID, jobName, created, plan, problems }

    /// Suggestions saved before approvals could leave problems have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        jobID = try container.decode(String.self, forKey: .jobID)
        jobName = try container.decode(String.self, forKey: .jobName)
        created = try container.decode(Date.self, forKey: .created)
        plan = try container.decode(CleanupPlan.self, forKey: .plan)
        problems = try container.decodeIfPresent([String].self, forKey: .problems) ?? []
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

    /// Narrows the suggestion `id` to the rows of `left` it still holds when the store is read, under the store's lock,
    /// and attaches `problems`; removes it when nothing is left. A row another approval settled meanwhile isn't in the
    /// stored suggestion, so it stays settled: two approvals of one suggestion never bring back what either ran.
    func narrow(_ id: String, to left: CleanupPlan, problems: [String]) throws -> ManualJobRun.SuggestionFate {
        try modify { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return .gone }
            var suggestion = list[index]
            let plan = left.narrowed(to: suggestion.plan)
            guard !plan.isEmpty else {
                list.remove(at: index)
                return .dismissed
            }
            suggestion.plan = plan
            suggestion.problems = problems
            list[index] = suggestion
            return .kept(suggestion)
        }
    }

    private func modify<Result>(_ change: (inout [Suggestion]) -> Result) throws -> Result {
        try FileLock.withLock(for: file) {
            var list = all()
            let result = change(&list)
            try LockedFile.write(try JSONEncoder.spaceKit.encode(list), to: file)
            return result
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
