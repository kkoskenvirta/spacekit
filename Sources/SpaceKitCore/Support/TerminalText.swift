/// Makes untrusted text safe to print to a terminal.
///
/// File names, paths and rule text come from the disk and from rule files. A name holding an escape
/// sequence could otherwise rewrite the screen, hide a line of a cleanup preview or retitle the window,
/// so every front end that prints such text to a terminal passes it through `sanitize(_:)`.
public enum TerminalText {
    /// Replaces every C0 control character, DEL and every C1 control character with a visible escape
    /// (`\n`, `\r`, `\t`, or `\u{1B}` style). Everything else, including non-ASCII text, is unchanged.
    public static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var result = ""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard isControl(scalar) else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "\\u{" + (hex.count < 2 ? "0" + hex : hex) + "}"
            }
        }
        return result
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}
