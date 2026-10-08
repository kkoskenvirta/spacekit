import Foundation

/// A number of bytes that reads and writes human-friendly strings such as `30GB`, `1.5 TB` or `512MiB`.
///
/// Decimal units (`KB`, `MB`, `GB`, `TB`) are powers of 1000, matching Finder.
/// Binary units (`KiB`, `MiB`, `GiB`, `TiB`) are powers of 1024.
public struct ByteCount: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    public var bytes: UInt64

    public init(_ bytes: UInt64) { self.bytes = bytes }
    public init(integerLiteral value: UInt64) { self.bytes = value }

    public static let zero = ByteCount(0)
    public static func mb(_ n: Double) -> ByteCount { ByteCount(UInt64(n * 1e6)) }
    public static func gb(_ n: Double) -> ByteCount { ByteCount(UInt64(n * 1e9)) }
    public static func tb(_ n: Double) -> ByteCount { ByteCount(UInt64(n * 1e12)) }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool { lhs.bytes < rhs.bytes }

    public var description: String { ByteCount.format(bytes) }

    // MARK: Parsing

    private static let units: [(suffix: String, multiplier: Double)] = [
        ("tib", 1_099_511_627_776), ("gib", 1_073_741_824), ("mib", 1_048_576), ("kib", 1024),
        ("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3),
        ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3),
        ("bytes", 1), ("b", 1),
    ]

    /// Parses `"30GB"`, `"1.5 tb"`, `"512MiB"`, `"1000"`. Returns `nil` for malformed input.
    public static func parse(_ text: String) -> ByteCount? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "")
        guard !s.isEmpty else { return nil }
        for (suffix, multiplier) in units where s.hasSuffix(suffix) {
            let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value >= 0, value.isFinite else { return nil }
            let bytes = (value * multiplier).rounded()
            // 2^64 is exactly representable; anything at or above it would trap converting to UInt64.
            guard bytes < 18_446_744_073_709_551_616.0 else { return nil }
            return ByteCount(UInt64(bytes))
        }
        guard let value = UInt64(s) else { return nil }
        return ByteCount(value)
    }

    // MARK: Formatting

    /// Formats bytes the way Finder does (base 10): `34.8 GB`, `143 GB`, `512 KB`.
    public static func format(_ bytes: UInt64) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1000
        var index = 0
        while value >= 999.95 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let digits = value >= 100 ? 0 : 1
        return String(format: "%.\(digits)f %@", value, units[index])
    }

    /// Like `format(_:)` but signed, for deltas: `+31 GB`, `-2.1 GB`.
    public static func formatDelta(_ delta: Int64) -> String {
        let sign = delta < 0 ? "-" : "+"
        return sign + format(delta.magnitude)
    }

    /// Compact form used when writing YAML: `30GB`, `1.5TB`, `500MB`.
    public var compact: String {
        let steps: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (size, unit) in steps where Double(bytes) >= size {
            let value = Double(bytes) / size
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int(rounded))\(unit)" : "\(rounded)\(unit)"
        }
        return "\(bytes)B"
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(UInt64.self) {
            bytes = number
        } else {
            let text = try container.decode(String.self)
            guard let parsed = ByteCount.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid size '\(text)'. Use values like 500MB, 30GB or 1.5TB.")
            }
            bytes = parsed.bytes
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(compact)
    }
}

extension UInt64 {
    /// Shorthand for `ByteCount.format(self)`.
    public var formattedBytes: String { ByteCount.format(self) }
}
