import Foundation
import SpaceKitCore

/// Terminal text styling with 256-color support. Respects `NO_COLOR`.
public struct Style: Sendable, Equatable {
    public var foreground: UInt8?
    public var background: UInt8?
    public var bold = false
    public var dim = false

    public init(fg: UInt8? = nil, bg: UInt8? = nil, bold: Bool = false, dim: Bool = false) {
        self.foreground = fg
        self.background = bg
        self.bold = bold
        self.dim = dim
    }

    public static let plain = Style()
    public static let bold = Style(bold: true)
    public static let dim = Style(dim: true)

    public var sequence: String {
        var codes: [String] = []
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if let foreground { codes.append("38;5;\(foreground)") }
        if let background { codes.append("48;5;\(background)") }
        return codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
    }
}

public enum ANSI {
    public static let reset = "\u{1B}[0m"

    /// Whether to emit colors on standard output.
    public static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let noColor = env["NO_COLOR"], !noColor.isEmpty { return false }
        if let force = env["SPACEKIT_FORCE_COLOR"], !force.isEmpty { return true }
        return isatty(STDOUT_FILENO) != 0
    }()

    public static func styled(_ text: String, _ style: Style) -> String {
        guard enabled, style != .plain else { return text }
        return style.sequence + text + reset
    }

    // Palette (xterm-256 indices), chosen to stay readable on light and dark backgrounds.
    public static let accent: UInt8 = 75
    public static let safe: UInt8 = 71
    public static let review: UInt8 = 178
    public static let protected: UInt8 = 167
    public static let branches: [UInt8] = [68, 73, 108, 179, 173, 168, 134, 110, 143, 175, 72, 137]

    public static func color(for level: SafetyLevel) -> UInt8 {
        switch level {
        case .safe: return safe
        case .review: return review
        case .protected: return protected
        }
    }

    /// Display width of a string, ignoring escape sequences and counting wide characters and emoji as 2 columns.
    public static func width(_ text: String) -> Int { TerminalWidth.columns(text) }

    /// Truncates plain text to `width` columns, adding "…" when cut.
    public static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if self.width(text) <= width { return text }
        return TerminalWidth.prefix(text, columns: width - 1).text + "…"
    }

    /// Truncates in the middle, which keeps both ends of a path readable.
    public static func truncateMiddle(_ text: String, to width: Int) -> String {
        guard self.width(text) > width, width > 3 else { return truncate(text, to: width) }
        let head = TerminalWidth.prefix(text, columns: (width - 1) / 2)
        var tail: [Character] = []
        var used = 0
        for character in text.reversed() {
            let columns = TerminalWidth.columns(character)
            if head.columns + 1 + used + columns > width { break }
            tail.append(character)
            used += columns
        }
        return head.text + "…" + String(tail.reversed())
    }

    /// Pads or cuts a styled line to exactly `width` columns, keeping its escape sequences intact.
    static func fit(_ line: String, to width: Int) -> String {
        let width = max(0, width)
        let cut = TerminalWidth.prefix(line, columns: width)
        return cut.text + reset + String(repeating: " ", count: width - cut.columns)
    }

    /// Splits a styled line into rows of at most `width` columns, breaking after a space where there is one.
    /// Later rows keep the line's leading indent and reopen the styles in effect where the previous row ended.
    static func wrap(_ line: String, to width: Int) -> [String] {
        guard width > 0, self.width(line) > width else { return [line] }
        let indent = String(repeating: " ", count: min(line.prefix { $0 == " " }.count, width / 2))
        var rows: [String] = []
        var rest = Substring(line)
        var styles = ""
        while true {
            let lead = rows.isEmpty ? "" : indent
            let room = width - lead.count
            if self.width(String(rest)) <= room {
                rows.append(lead + styles + rest)
                return rows
            }
            var row = Substring(TerminalWidth.prefix(String(rest), columns: room).text)
            if row.isEmpty { row = rest.prefix(1) }
            if let space = row.lastIndex(of: " "), row[..<space].contains(where: { $0 != " " }) {
                row = row[...space]
            }
            rows.append(lead + styles + row)
            styles = openStyles(after: styles + row)
            rest = rest.dropFirst(row.count).drop { $0 == " " }
        }
    }

    /// The style sequences in `text` that no later reset cancels.
    private static func openStyles(after text: Substring) -> String {
        var open = ""
        var sequence = ""
        for character in text {
            if sequence.isEmpty, character != "\u{1B}" { continue }
            sequence.append(character)
            guard sequence.count > 2, let last = character.asciiValue, (0x40...0x7E).contains(last) else { continue }
            open = sequence == reset ? "" : open + sequence
            sequence = ""
        }
        return open
    }

    public static func pad(_ text: String, to width: Int, alignRight: Bool = false) -> String {
        let w = self.width(text)
        guard w < width else { return text }
        let space = String(repeating: " ", count: width - w)
        return alignRight ? space + text : text + space
    }

    /// A horizontal bar like `██████▌░░░░`.
    public static func bar(fraction: Double, width: Int, color: UInt8, trackColor: UInt8 = 238) -> String {
        guard width > 0 else { return "" }
        let clamped = min(max(fraction, 0), 1)
        let eighths = Int((clamped * Double(width) * 8).rounded())
        let full = eighths / 8
        let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var filled = String(repeating: "█", count: full)
        var used = full
        if full < width, eighths % 8 > 0 {
            filled += partials[eighths % 8]
            used += 1
        }
        let track = String(repeating: "░", count: max(0, width - used))
        return styled(filled, Style(fg: color)) + styled(track, Style(fg: trackColor))
    }

    /// `▁▂▃▅▇` sparkline for a series.
    public static func sparkline(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max(), high > low else {
            return String(repeating: "▄", count: values.count)
        }
        let blocks = Array("▁▂▃▄▅▆▇█")
        return String(values.map { blocks[Int(((($0 - low) / (high - low)) * 7).rounded())] })
    }
}

extension String {
    public func styled(_ style: Style) -> String { ANSI.styled(self, style) }
    public func fg(_ color: UInt8) -> String { ANSI.styled(self, Style(fg: color)) }
    public var bold: String { ANSI.styled(self, .bold) }
    public var dim: String { ANSI.styled(self, .dim) }
}

extension SafetyLevel {
    /// Colored dot and label for terminals.
    public var badge: String {
        let symbol = self == .protected ? "⚠" : "●"
        return "\(symbol) \(title)".fg(ANSI.color(for: self))
    }
}

extension SafetyVerdict.Decision {
    /// The color of a verdict in the terminal front ends: green allowed, amber needs confirmation, red blocked.
    public var color: UInt8 {
        switch self {
        case .allow: return ANSI.safe
        case .confirm: return ANSI.review
        case .block: return ANSI.protected
        }
    }

    /// The mark before an item in a cleanup preview: ✓ allowed, ! needs confirmation, ✗ blocked.
    public var mark: String {
        switch self {
        case .allow: return "✓".fg(color)
        case .confirm: return "!".fg(color)
        case .block: return "✗".fg(color)
        }
    }
}
