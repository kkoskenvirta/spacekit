import Foundation

/// One labeled fact about a finding, as every front end lists them.
public struct FindingFact: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case reclaimable, risk, recreatedBy, lastUsed, items, cleansWith, howToClean }
    public var kind: Kind
    public var label: String
    /// Plain text. Rule text comes from rule files, so terminals sanitize it before printing.
    public var value: String
}

extension Finding {
    /// What a finding's detail view lists, in order. Risk is the level's word; front ends add their badge.
    public func facts(now: Date = Date()) -> [FindingFact] {
        var facts: [FindingFact] = []
        func add(_ kind: FindingFact.Kind, _ label: String, _ value: String?) {
            if let value { facts.append(FindingFact(kind: kind, label: label, value: value)) }
        }
        add(.reclaimable, "Reclaimable", isCleanable ? ByteCount.format(size) : nil)
        add(.risk, "Risk", rule.safety.level.risk)
        add(.recreatedBy, "Recreated by", rule.recreatedBy)
        add(.lastUsed, "Last used", lastUsed?.relativeDescription(now: now))
        if items.count > 1 || rule.isPattern { add(.items, rule.isPattern ? "Projects" : "Items", "\(items.count)") }
        add(.cleansWith, "Cleans with", rule.action.command?.joined(separator: " "))
        add(.howToClean, "How to clean", rule.action.manual)
        return facts
    }
}

extension AIModel {
    /// How the AI view labels a model: caches and orphaned blobs by what they are, models and datasets by use.
    public enum Status: String, Sendable { case active, idle, cache, orphaned }

    public func status(within window: Age, now: Date = Date()) -> Status {
        switch kind {
        case .orphaned: return .orphaned
        case .cache: return .cache
        case .model, .dataset: return isActive(within: window, now: now) ? .active : .idle
        }
    }
}

extension VolumeCapacity {
    /// How full a disk looks: front ends color its capacity bar by this.
    public enum Fullness: Sendable { case comfortable, filling, nearlyFull }

    /// Used share above which a disk counts as filling up, and as nearly full.
    public static let fillingShare = 0.75
    public static let nearlyFullShare = 0.9

    public var fullness: Fullness {
        usedFraction > VolumeCapacity.nearlyFullShare ? .nearlyFull : usedFraction > VolumeCapacity.fillingShare ? .filling : .comfortable
    }
}

extension DiskItem {
    /// What Explore notes next to an entry: the rule that knows it, otherwise why its size may not be what it seems.
    public enum Note: Sendable {
        case rule(Rule)
        /// Privacy-protected: its size is unknown without Full Disk Access.
        case noAccess
        /// A firmlink to the named top-level folder, counted there instead.
        case sameAs(String)
        case otherVolume
    }

    /// `rule` is the front end's lookup for this entry's path.
    public func note(rule: Rule?) -> Note? {
        if let rule { return .rule(rule) }
        guard let directory else { return nil }
        if directory.flags.contains(.unreadable) { return .noAccess }
        if directory.flags.contains(.firmlinkDuplicate) { return .sameAs(directory.name) }
        if directory.flags.contains(.otherVolume) { return .otherVolume }
        return nil
    }
}
