import Foundation

/// One point in storage history.
public struct HistoryRecord: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Only the volume's used/free numbers (cheap; recorded every few hours by the agent).
        case sample
        /// Full breakdown by category and rule group (after a complete analysis).
        case snapshot
    }

    public var date: Date
    public var kind: Kind
    public var total: UInt64
    /// Finder's "Used": total minus available (purgeable space doesn't count as used).
    public var used: UInt64
    /// Finder's "Available", including purgeable space.
    public var available: UInt64
    public var purgeable: UInt64
    /// Bytes per storage category id (snapshots only).
    public var categories: [String: UInt64]?
    /// Bytes per rule group, e.g. "Xcode", "Ollama" (snapshots only).
    public var groups: [String: UInt64]?

    public var id: Date { date }
}

public struct GrowthItem: Sendable, Identifiable {
    public var name: String
    public var delta: Int64
    public var current: UInt64
    public var id: String { name }
}

/// Storage history in JSON Lines: the data behind "+73 GB this month" and "what grew?".
public struct HistoryStore: Sendable {
    public let file: String
    /// Minimum spacing between cheap samples.
    public static let sampleInterval: TimeInterval = 6 * 3600

    public init(file: String) { self.file = file }

    public func records(since: Date? = nil) -> [HistoryRecord] {
        JSONLines.read(file, since: since, date: \HistoryRecord.date).sorted { $0.date < $1.date }
    }

    public func append(_ record: HistoryRecord) throws {
        try JSONLines.append([record], to: file)
    }

    public func recordVolumeSample(_ capacity: VolumeCapacity, now: Date = Date()) throws {
        if let last = records(since: now.addingTimeInterval(-HistoryStore.sampleInterval)).last,
            now.timeIntervalSince(last.date) < HistoryStore.sampleInterval
        {
            return
        }
        try append(
            HistoryRecord(
                date: now, kind: .sample, total: capacity.total, used: capacity.used,
                available: capacity.available, purgeable: capacity.purgeable))
    }

    /// Records a full breakdown from an analysis. A stopped analysis is missing whatever its scan didn't reach,
    /// so it isn't recorded.
    public func recordSnapshot(analysis: Analysis, now: Date = Date()) throws {
        guard !analysis.tree.stats.cancelled else { return }
        let capacity = analysis.tree.capacity ?? VolumeCapacity.of(path: "/")
        var groups: [String: UInt64] = [:]
        for group in analysis.groups { groups[group.name] = group.size }
        var categories: [String: UInt64] = [:]
        for slice in CategoryBreakdown.compute(tree: analysis.tree, findings: analysis.findings) { categories[slice.id] = slice.size }
        try append(
            HistoryRecord(
                date: now, kind: .snapshot, total: capacity?.total ?? 0, used: capacity?.used ?? 0,
                available: capacity?.available ?? 0, purgeable: capacity?.purgeable ?? 0,
                categories: categories, groups: groups))
    }

    public func lastSnapshotDate() -> Date? {
        records().last { $0.kind == .snapshot }?.date
    }

    /// Change in used space over a window.
    public func usedDelta(over window: Age, now: Date = Date()) -> Int64? {
        let recent = records(since: window.ago(from: now))
        guard let first = recent.first, let last = recent.last, first.date != last.date else { return nil }
        return Int64(bitPattern: last.used) - Int64(bitPattern: first.used)
    }

    /// Which rule groups grew the most between the oldest and newest snapshot in the window.
    public func whatGrew(over window: Age, now: Date = Date(), limit: Int = 8) -> [GrowthItem] {
        let snapshots = records(since: window.ago(from: now)).filter { $0.kind == .snapshot }
        guard let first = snapshots.first, let last = snapshots.last, first.date != last.date else { return [] }
        let before = first.groups ?? [:]
        let after = last.groups ?? [:]
        return Set(before.keys).union(after.keys)
            .map { name in
                GrowthItem(
                    name: name, delta: Int64(bitPattern: after[name] ?? 0) - Int64(bitPattern: before[name] ?? 0),
                    current: after[name] ?? 0)
            }
            .filter { $0.delta != 0 }
            .sorted { $0.delta > $1.delta }
            .prefix(limit)
            .map { $0 }
    }

    /// One used-space value per day (the last sample of each day), for charts.
    public func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [(date: Date, used: UInt64, total: UInt64)] {
        let since = Age.days(Double(days)).ago(from: now)
        var byDay: [Date: HistoryRecord] = [:]
        for record in records(since: since) {
            byDay[calendar.startOfDay(for: record.date)] = record
        }
        return byDay.keys.sorted().map { (date: $0, used: byDay[$0]!.used, total: byDay[$0]!.total) }
    }
}
