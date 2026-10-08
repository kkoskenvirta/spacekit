import Foundation

/// A record of something SpaceKit removed (or ran) to free space.
public struct JournalEntry: Codable, Sendable, Identifiable {
    public enum Method: String, Codable, Sendable { case trash, delete, command }

    public var id: UUID
    public var date: Date
    public var path: String
    public var bytes: UInt64
    public var method: Method
    public var ruleID: String?
    public var jobID: String?
    public var automatic: Bool
    /// Where a trashed item went, so it can be put back.
    public var trashedTo: String?

    public init(
        date: Date = Date(), path: String, bytes: UInt64, method: Method, ruleID: String? = nil, jobID: String? = nil,
        automatic: Bool, trashedTo: String? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.path = path
        self.bytes = bytes
        self.method = method
        self.ruleID = ruleID
        self.jobID = jobID
        self.automatic = automatic
        self.trashedTo = trashedTo
    }
}

/// Append-only log of every removal, in JSON Lines. It's the audit trail and the source of
/// "your Mac has recovered 284 GB" statistics.
public struct Journal: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    public func append(_ entries: [JournalEntry]) throws {
        try JSONLines.append(entries, to: file)
    }

    public func entries(since: Date? = nil) -> [JournalEntry] {
        JSONLines.read(file, since: since, date: \JournalEntry.date)
    }

    /// Bytes recovered since a date.
    public func recovered(since: Date? = nil) -> UInt64 {
        entries(since: since).reduce(0) { $0 &+ $1.bytes }
    }
}
