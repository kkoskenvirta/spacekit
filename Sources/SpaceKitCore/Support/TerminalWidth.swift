/// How many terminal columns text takes, for laying out aligned terminal output.
///
/// Terminals draw emoji shown as pictures and East Asian wide characters two columns wide, and combining
/// marks and joiners not at all. Widths are counted per grapheme cluster, so a flag, a family emoji or a
/// symbol followed by the emoji variation selector (U+FE0F) count as one two-column picture.
/// Escape sequences (the styling SpaceKit adds itself) take no columns.
public enum TerminalWidth {
    /// Columns `text` takes on screen.
    public static func columns(_ text: String) -> Int {
        var scanner = EscapeScanner()
        var total = 0
        for character in text where !scanner.consume(character) {
            total += columns(character)
        }
        return total
    }

    /// The longest start of `text` that fits in `limit` columns, with every escape sequence in that start
    /// kept whole, and the columns it takes.
    public static func prefix(_ text: String, columns limit: Int) -> (text: String, columns: Int) {
        var scanner = EscapeScanner()
        var result = ""
        var used = 0
        for character in text {
            if scanner.consume(character) {
                result.append(character)
                continue
            }
            let width = columns(character)
            if used + width > limit { break }
            result.append(character)
            used += width
        }
        return (result, used)
    }

    /// Columns one grapheme cluster takes: 0, 1 or 2.
    public static func columns(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.contains("\u{FE0F}") { return 2 }
        if scalars.contains("\u{FE0E}") { return min(1, columns(first)) }
        if first.properties.isEmojiPresentation { return 2 }
        // A text-style emoji base turned into a picture by a skin-tone modifier or a joined sequence.
        if scalars.count > 1, first.properties.isEmoji,
            scalars.contains(where: { $0.properties.isEmojiModifier || $0 == "\u{200D}" })
        {
            return 2
        }
        return columns(first)
    }

    static func columns(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        return wideRanges.contains { $0.contains(value) } ? 2 : 1
    }

    /// East Asian Wide and Fullwidth blocks (Hangul, CJK, kana, fullwidth forms).
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD,
    ]
}

/// Recognises escape sequences one character at a time: CSI sequences (`ESC [` … final byte, which covers
/// colors and cursor movement) and two-character `ESC x` sequences.
private struct EscapeScanner {
    private enum Mode { case text, escape, csi }
    private var mode = Mode.text

    /// True if `character` belongs to an escape sequence.
    mutating func consume(_ character: Character) -> Bool {
        let first = character.unicodeScalars.first?.value ?? 0
        switch mode {
        case .text:
            guard first == 0x1B else { return false }
            mode = .escape
        case .escape:
            mode = first == 0x5B ? .csi : .text
        case .csi:
            if (0x40...0x7E).contains(first) { mode = .text }
        }
        return true
    }
}
