import Foundation
import SpaceKitCore

// Pieces the CLI and the TUI both print, so the two terminal front ends say the same thing the same way.

extension AIModel.Status {
    /// The status word, colored.
    public var terminalText: String {
        switch self {
        case .active: return "active".fg(ANSI.safe)
        case .idle: return "idle".fg(ANSI.review)
        case .cache: return "cache".dim
        case .orphaned: return "orphaned".fg(ANSI.review)
        }
    }
}

extension VolumeCapacity.Fullness {
    /// The color of a capacity bar.
    public var terminalColor: UInt8 {
        switch self {
        case .comfortable: return ANSI.accent
        case .filling: return ANSI.review
        case .nearlyFull: return ANSI.protected
        }
    }
}

extension GrowthItem {
    /// A "WHAT GREW?" row: the rule group and how much it changed, amber when it grew.
    public var terminalLine: String {
        "  " + ANSI.pad(ANSI.truncate(TerminalText.sanitize(name), to: 27), to: 28)
            + ANSI.pad(ByteCount.formatDelta(delta), to: 10, alignRight: true).fg(delta > 0 ? ANSI.review : ANSI.safe)
    }
}

extension Job {
    /// `ON ●` or `OFF ○`.
    public var terminalToggle: String { enabled ? "ON ●".fg(ANSI.safe) : "OFF ○".dim }

    /// "next in 3 days" for an enabled job with a next run, otherwise empty.
    public func nextRunText(_ next: Date?) -> String {
        guard enabled, let next else { return "" }
        return "next " + next.relativeDescription()
    }
}

extension Finding {
    /// `facts()` sanitized for a terminal, with the safety badge after the risk.
    public func terminalFacts() -> [(label: String, value: String)] {
        facts().map { fact in
            let value = TerminalText.sanitize(fact.value)
            return (fact.label, fact.kind == .risk ? value + "  " + safety.badge : value)
        }
    }
}

extension DiskItem.Note {
    /// The note after an Explore row.
    public var terminalText: String {
        switch self {
        case .rule(let rule): return rule.safety.level.badge + " " + TerminalText.sanitize(rule.name).dim
        case .noAccess: return "no access".fg(ANSI.review)
        case .sameAs(let name): return "same as /\(TerminalText.sanitize(name))".dim
        case .otherVolume: return "other volume".dim
        }
    }
}
