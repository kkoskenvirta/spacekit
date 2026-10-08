import Foundation

/// A span of time written the way people talk about file age: `14d`, `2w`, `3mo`, `1y`, `12h`, `60 days`.
public struct Age: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var seconds: TimeInterval

    public init(seconds: TimeInterval) { self.seconds = seconds }
    public static func days(_ n: Double) -> Age { Age(seconds: n * 86_400) }
    public static func hours(_ n: Double) -> Age { Age(seconds: n * 3600) }

    public var days: Double { seconds / 86_400 }

    /// The moment this long before `now`.
    public func ago(from now: Date = Date()) -> Date { now.addingTimeInterval(-seconds) }

    /// How long ago `date` was.
    public static func since(_ date: Date, now: Date = Date()) -> Age { Age(seconds: now.timeIntervalSince(date)) }

    public static func < (lhs: Age, rhs: Age) -> Bool { lhs.seconds < rhs.seconds }

    private static let minuteSuffixes = ["minutes", "minute", "min", "m"]
    private static let units: [(suffixes: [String], seconds: Double)] = [
        (["years", "year", "yr", "y"], 365 * 86_400),
        (["months", "month", "mo"], 30 * 86_400),
        (["weeks", "week", "wk", "w"], 7 * 86_400),
        (["days", "day", "d"], 86_400),
        (["hours", "hour", "hr", "h"], 3600),
        (minuteSuffixes, 60),
    ]

    /// The longest age accepted from text or config. Keeps every later conversion (descriptions, date arithmetic) finite.
    public static let maximum = Age.days(100 * 365)

    /// `seconds` as an age, or `nil` if it is negative, not finite, or above `maximum`.
    static func checked(seconds: Double) -> Age? {
        seconds.isFinite && seconds >= 0 && seconds <= maximum.seconds ? Age(seconds: seconds) : nil
    }

    public static func parse(_ text: String) -> Age? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        for (suffixes, multiplier) in units {
            for suffix in suffixes where s.hasSuffix(suffix) {
                let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let value = Double(number) { return checked(seconds: value * multiplier) }
            }
        }
        // A bare number means days, the most common unit for cleanup rules.
        if let value = Double(s) { return checked(seconds: value * 86_400) }
        return nil
    }

    /// Compact form for YAML: `14d`, `2w`, `3mo`.
    public var description: String {
        guard seconds.isFinite, seconds <= Age.maximum.seconds else { return "\(Int(Age.maximum.days / 365))y" }
        let d = days
        if d >= 365, d.truncatingRemainder(dividingBy: 365) == 0 { return "\(Int(d / 365))y" }
        if d >= 30, d.truncatingRemainder(dividingBy: 30) == 0 { return "\(Int(d / 30))mo" }
        if d >= 7, d.truncatingRemainder(dividingBy: 7) == 0 { return "\(Int(d / 7))w" }
        if d >= 1, d == d.rounded() { return "\(Int(d))d" }
        let h = seconds / 3600
        if h == h.rounded() { return "\(Int(h))h" }
        return "\(Int(seconds / 60))m"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            guard let checked = Age.checked(seconds: number * 86_400) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid age \(number). Use a number of days from 0 to \(Int(Age.maximum.days)).")
            }
            seconds = checked.seconds
        } else {
            let text = try container.decode(String.self)
            guard let parsed = Age.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid age '\(text)'. Use values like 14d, 2w, 3mo or 1y.")
            }
            seconds = parsed.seconds
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Age {
    /// Shortest `olderThan` / `keepRecent`. Anything below a day is almost always a typo, such as `6m`
    /// (minutes) for `6mo` (months).
    public static let minimumRetention = Age.days(1)

    /// Why `age`, written as `text`, can't be an `olderThan` or `keepRecent` value, or `nil` if it can.
    public static func retentionProblem(_ age: Age, text: String) -> String? {
        guard age < minimumRetention else { return nil }
        let written = text.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in minuteSuffixes where written.hasSuffix(suffix) {
            let number = written.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if Double(number) != nil {
                return "'\(text)' means \(number) minutes; did you mean \(number)mo (months)? Ages here must be at least 1 day."
            }
        }
        return "'\(text)' is shorter than a day. Ages here must be at least 1 day, e.g. 14d, 2w or 3mo."
    }

    /// Parses an `olderThan` / `keepRecent` value typed by a person. Returns the age or the reason it's rejected.
    public static func parseRetention(_ text: String) -> Result<Age, AgeError> {
        guard let age = parse(text) else {
            return .failure(AgeError(message: "Invalid age '\(text)'. Use values like 14d, 2w, 3mo or 1y."))
        }
        if let problem = retentionProblem(age, text: text) { return .failure(AgeError(message: problem)) }
        return .success(age)
    }
}

public struct AgeError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

extension KeyedDecodingContainer {
    /// Decodes an `olderThan` / `keepRecent` age, rejecting values below `Age.minimumRetention`.
    func decodeRetentionIfPresent(forKey key: Key) throws -> Age? {
        guard let age = try decodeIfPresent(Age.self, forKey: key) else { return nil }
        let text = ((try? decodeIfPresent(String.self, forKey: key)) ?? nil) ?? age.description
        if let problem = Age.retentionProblem(age, text: text) {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: problem)
        }
        return age
    }
}

extension Date {
    /// "18 days ago", "in 4 days", "just now".
    public func relativeDescription(now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(self)
        if abs(delta) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
