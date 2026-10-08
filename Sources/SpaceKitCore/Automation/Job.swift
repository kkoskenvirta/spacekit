import Foundation

/// A scheduled cleanup ("Automation" in the app, `jobs:` in the config).
public struct Job: Codable, Sendable, Identifiable, Hashable {
    /// Ordered as declared, by how much a job does on its own: `observe` < `suggest` < `automatic`.
    public enum Mode: String, Codable, Sendable, CaseIterable, Comparable {
        /// Tell me when this gets large.
        case observe
        /// Prepare a cleanup, but ask me first.
        case suggest
        /// Clean according to my rules (within the safety limits).
        case automatic

        public var title: String {
            switch self {
            case .observe: return "Observe"
            case .suggest: return "Suggest"
            case .automatic: return "Automatic"
            }
        }

        public var explanation: String {
            switch self {
            case .observe: return "Notify me when it grows past the threshold."
            case .suggest: return "Prepare a cleanup and ask before removing anything."
            case .automatic: return "Clean on schedule. Regenerable items only, unless review items are included."
            }
        }

        public static func < (lhs: Mode, rhs: Mode) -> Bool { lhs.declarationIndex < rhs.declarationIndex }
    }

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Move to the Trash.
        case trash
        /// Delete permanently (only honoured for regenerable items in automatic runs).
        case delete
        /// Follow each rule's `safety.trash`.
        case rule
    }

    public struct Conditions: Codable, Sendable, Hashable {
        /// Only act when the matched total exceeds this.
        public var sizeAbove: ByteCount?
        /// Only touch items unused for at least this long.
        public var olderThan: Age?
        /// Never touch items used within this window ("keep projects used within 14 days").
        public var keepRecent: Age?

        public init(sizeAbove: ByteCount? = nil, olderThan: Age? = nil, keepRecent: Age? = nil) {
            self.sizeAbove = sizeAbove
            self.olderThan = olderThan
            self.keepRecent = keepRecent
        }

        enum CodingKeys: String, CodingKey { case sizeAbove, olderThan, keepRecent }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sizeAbove = try c.decodeIfPresent(ByteCount.self, forKey: .sizeAbove)
            olderThan = try c.decodeRetentionIfPresent(forKey: .olderThan)
            keepRecent = try c.decodeRetentionIfPresent(forKey: .keepRecent)
        }

        public var isEmpty: Bool { sizeAbove == nil && olderThan == nil && keepRecent == nil }
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    /// Rule ids this job cleans.
    public var rules: [String]
    /// Your own folders to clean (in addition to rules).
    public var paths: [String]
    /// For `paths`: clean each entry inside the folder (`children`) or the folder itself (`whole`).
    public var granularity: Granularity
    public var mode: Mode
    public var schedule: Schedule
    public var when: Conditions
    public var action: Action
    /// Allow 🟡 review items in automatic mode.
    public var includeReview: Bool

    public init(
        id: String, name: String, enabled: Bool = true, rules: [String] = [], paths: [String] = [],
        granularity: Granularity = .children, mode: Mode = .suggest, schedule: Schedule = .weekly,
        when: Conditions = Conditions(), action: Action = .trash, includeReview: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.rules = rules
        self.paths = paths
        self.granularity = granularity
        self.mode = mode
        self.schedule = schedule
        self.when = when
        self.action = action
        self.includeReview = includeReview
    }

    enum CodingKeys: String, CodingKey { case id, name, enabled, rules, paths, granularity, mode, schedule, when, action, includeReview }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Rule.slug(name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try c.decodeIfPresent([String].self, forKey: .rules) ?? []
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        granularity = try c.decodeIfPresent(Granularity.self, forKey: .granularity) ?? .children
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .suggest
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? .weekly
        when = try c.decodeIfPresent(Conditions.self, forKey: .when) ?? Conditions()
        action = try c.decodeIfPresent(Action.self, forKey: .action) ?? .trash
        includeReview = try c.decodeIfPresent(Bool.self, forKey: .includeReview) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        if !rules.isEmpty { try c.encode(rules, forKey: .rules) }
        if !paths.isEmpty {
            try c.encode(paths, forKey: .paths)
            try c.encode(granularity, forKey: .granularity)
        }
        try c.encode(mode, forKey: .mode)
        try c.encode(schedule, forKey: .schedule)
        if !when.isEmpty { try c.encode(when, forKey: .when) }
        try c.encode(action, forKey: .action)
        if includeReview { try c.encode(includeReview, forKey: .includeReview) }
    }

    /// Summary like "Clean when > 30 GB · keep items used within 14 days".
    public var conditionSummary: String {
        var parts: [String] = []
        if let size = when.sizeAbove { parts.append("Clean when > \(size)") }
        if let age = when.olderThan { parts.append("Untouched for \(Int(age.days)) days") }
        if let keep = when.keepRecent { parts.append("Keep items used within \(Int(keep.days)) days") }
        return parts.isEmpty ? "Cleans everything matched, on schedule" : parts.joined(separator: " · ")
    }

    /// How long a project counts as active for a rule's `active_projects` exclusion when its policy sets no `keepRecent`.
    public static let defaultActiveProjectsWindow = Age.days(14)

    /// A job pre-filled from a rule's suggested policy. A rule whose action runs a tool command is suggested as `suggest`
    /// at most: an automatic run starts a tool only from folders the person can't change, which a typical install isn't
    /// (Homebrew under a prefix they own, apps in `/Applications`, `~/.cargo/bin`), so the job would skip every time.
    /// Suggested instead, the person approves it and it runs by hand.
    public static func suggested(for rule: Rule) -> Job {
        let policy = rule.policy
        let runsCommand = rule.action.command != nil || rule.action.itemCommand != nil
        let mode = runsCommand ? min(policyMode(of: rule), .suggest) : policyMode(of: rule)
        var keep = policy?.keepRecent
        if keep == nil && rule.exclusions.contains(where: RuleEngine.isActiveProjectsToken) { keep = Job.defaultActiveProjectsWindow }
        return Job(
            id: rule.id, name: rule.name, rules: [rule.id], mode: mode, schedule: policy?.schedule ?? .weekly,
            when: Conditions(sizeAbove: policy?.threshold, olderThan: policy?.olderThan, keepRecent: keep),
            action: .trash, includeReview: false)
    }
}

extension Job {
    /// The mode a rule's policy asks for: its own, or automatic for a regenerable rule and suggest otherwise.
    static func policyMode(of rule: Rule) -> Mode {
        rule.policy?.mode ?? (rule.safety.level == .safe ? .automatic : .suggest)
    }
}

extension CaseIterable where Self: Equatable, AllCases == [Self] {
    /// The case's position in `allCases`, which lists cases as they are declared. The orders above follow it, so a
    /// new case goes where it belongs in the order.
    var declarationIndex: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

public enum Weekday: String, Codable, Sendable, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    /// `Calendar` weekday number (Sunday = 1).
    public var number: Int { declarationIndex + 1 }
    public var title: String { rawValue.capitalized }
}

/// When a job runs. YAML accepts `weekly`, `daily at 03:00`, or an object `{every: weekly, weekday: sunday, at: "03:00"}`.
public struct Schedule: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Ordered as declared, by the time between runs: `hourly` < `daily` < `weekly` < `monthly`.
    public enum Frequency: String, Codable, Sendable, CaseIterable, Comparable {
        case hourly, daily, weekly, monthly

        public static func < (lhs: Frequency, rhs: Frequency) -> Bool { lhs.declarationIndex < rhs.declarationIndex }
    }

    public var every: Frequency
    /// `HH:mm`, local time.
    public var at: String
    public var weekday: Weekday?
    /// Day of month (1–28) for monthly schedules.
    public var day: Int?

    public init(every: Frequency, at: String = "03:00", weekday: Weekday? = nil, day: Int? = nil) {
        self.every = every
        self.at = at
        self.weekday = weekday
        self.day = day
    }

    public static let weekly = Schedule(every: .weekly, weekday: .sunday)
    /// When the background agent takes a full storage snapshot unless the config says otherwise.
    public static let defaultSnapshot = Schedule(every: .weekly, at: "04:00", weekday: .sunday)
    /// Days every month has, so a monthly job never skips a month.
    public static let monthDays = 1...28

    private static let frequencyWords: [String: Frequency] = [
        "hourly": .hourly, "hour": .hourly, "daily": .daily, "day": .daily, "nightly": .daily,
        "weekly": .weekly, "week": .weekly, "monthly": .monthly, "month": .monthly,
    ]

    /// Parses `weekly`, `daily at 02:30`, `every sunday 04:00`. Every word must be understood: one frequency
    /// and/or one weekday, at most one `HH:mm` time, and the fillers `at`, `on`, `every`. Anything else is `nil`.
    public static func parse(_ text: String) -> Schedule? {
        let fillers: Set<String> = ["at", "on", "every"]
        let separated: [Substring] = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
        let words: [String] = separated.map(String.init).filter { !fillers.contains($0) }
        var frequency: Frequency?
        var weekday: Weekday?
        var time: (hour: Int, minute: Int)?
        for word in words {
            if let value = frequencyWords[word] {
                guard frequency == nil else { return nil }
                frequency = value
            } else if let day = Weekday.allCases.first(where: { $0.rawValue == word || $0.rawValue.prefix(3) == word }) {
                guard weekday == nil else { return nil }
                weekday = day
            } else if let parsed = components(word) {
                guard time == nil else { return nil }
                time = parsed
            } else {
                return nil
            }
        }
        if weekday != nil {
            guard frequency == nil || frequency == .weekly else { return nil }
            frequency = .weekly
        }
        guard let every = frequency else { return nil }
        let at = time.map { String(format: "%02d:%02d", $0.hour, $0.minute) } ?? "03:00"
        return Schedule(every: every, at: at, weekday: every == .weekly ? weekday ?? .sunday : nil, day: every == .monthly ? 1 : nil)
    }

    enum CodingKeys: String, CodingKey { case every, at, weekday, day }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            guard let parsed = Schedule.parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown schedule '\(text)'. Try hourly, daily, weekly, monthly, or 'sunday 03:00'."))
            }
            self = parsed
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        every = try c.decode(Frequency.self, forKey: .every)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? "03:00"
        weekday = try c.decodeIfPresent(Weekday.self, forKey: .weekday)
        day = try c.decodeIfPresent(Int.self, forKey: .day)
        if every == .weekly && weekday == nil { weekday = .sunday }
        if every == .monthly && day == nil { day = 1 }
        guard Schedule.components(at) != nil else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath + [CodingKeys.at],
                    debugDescription: "Time '\(at)' must be HH:mm"))
        }
        if let day, !Schedule.monthDays.contains(day) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath + [CodingKeys.day],
                    debugDescription: "Day \(day) must be 1 to 28, so the job runs every month"))
        }
    }

    /// Hour and minute of an `HH:mm` time (`7:05` and `07:05` both work), or `nil` if it isn't one.
    public static func components(_ time: String) -> (hour: Int, minute: Int)? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
            let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    /// The first scheduled time strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        let (hour, minute) = Schedule.components(at) ?? (3, 0)
        var match = DateComponents()
        switch every {
        case .hourly:
            match.minute = minute
        case .daily:
            match.hour = hour
            match.minute = minute
        case .weekly:
            match.weekday = (weekday ?? .sunday).number
            match.hour = hour
            match.minute = minute
        case .monthly:
            match.day = min(max(day ?? 1, Schedule.monthDays.lowerBound), Schedule.monthDays.upperBound)
            match.hour = hour
            match.minute = minute
        }
        return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime) ?? date.addingTimeInterval(Age.days(1).seconds)
    }

    /// "Sunday · 03:00", "Every day · 03:00".
    public var description: String {
        switch every {
        case .hourly: return "Every hour at :\(at.split(separator: ":").last ?? "00")"
        case .daily: return "Every day · \(at)"
        case .weekly: return "\((weekday ?? .sunday).title) · \(at)"
        case .monthly: return "Monthly on day \(day ?? 1) · \(at)"
        }
    }
}
