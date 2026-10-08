/// A key press read from a terminal in raw mode.
public enum TerminalKey: Equatable, Sendable {
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, escape, backspace, tab, backTab, space
    case character(Character)
    case control(Character)
}

/// Turns the bytes a raw-mode terminal sends into key presses.
///
/// One read can hold many keys (a held arrow key, pasted text), so every key in it is returned. A sequence
/// cut off at the end of the read (part of an escape sequence or of a UTF-8 character) is returned as `rest`
/// for the caller to put in front of the next read. A lone `ESC` at the end of a read is held back the same way,
/// because a terminal can split an arrow key's `ESC [ B` across two reads; when no more bytes follow, `flush`
/// turns it into the Escape key.
public enum KeyParser {
    public static func parse(_ bytes: [UInt8]) -> (keys: [TerminalKey], rest: [UInt8]) {
        var keys: [TerminalKey] = []
        var index = 0
        while index < bytes.count {
            switch next(in: bytes, at: index) {
            case .key(let key, let length):
                keys.append(key)
                index += length
            case .skip(let length):
                index += length
            case .incomplete:
                return (keys, Array(bytes[index...]))
            }
        }
        return (keys, [])
    }

    /// The keys in bytes `parse` held back once the terminal sent nothing more: a lone `ESC` is the Escape key,
    /// and anything else is a sequence the terminal never finished.
    public static func flush(_ rest: [UInt8]) -> [TerminalKey] {
        rest == [0x1B] ? [.escape] : []
    }

    private enum Step {
        case key(TerminalKey, length: Int)
        /// Bytes that aren't a key SpaceKit uses (function keys, invalid UTF-8).
        case skip(length: Int)
        case incomplete
    }

    private static func next(in bytes: [UInt8], at index: Int) -> Step {
        let byte = bytes[index]
        switch byte {
        case 0x1B: return escape(in: bytes, at: index)
        case 13, 10: return .key(.enter, length: 1)
        case 127, 8: return .key(.backspace, length: 1)
        case 9: return .key(.tab, length: 1)
        case 32: return .key(.space, length: 1)
        case 1...26: return .key(.control(Character(UnicodeScalar(byte + 96))), length: 1)
        case 0..<32: return .skip(length: 1)
        default: return character(in: bytes, at: index)
        }
    }

    /// `ESC` before another `ESC` is the Escape key. `ESC [ … final` (CSI) and `ESC O x` (SS3) are cursor and
    /// editing keys; `ESC` before anything else is an Alt combination, read as Escape.
    private static func escape(in bytes: [UInt8], at index: Int) -> Step {
        guard index + 1 < bytes.count else { return .incomplete }
        switch bytes[index + 1] {
        case UInt8(ascii: "["):
            var end = index + 2
            while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
            guard end < bytes.count else { return .incomplete }
            let parameters = bytes[(index + 2)..<end]
            let length = end - index + 1
            guard let key = csiKey(final: bytes[end], parameters: parameters) else { return .skip(length: length) }
            return .key(key, length: length)
        case UInt8(ascii: "O"):
            guard index + 2 < bytes.count else { return .incomplete }
            guard let key = csiKey(final: bytes[index + 2], parameters: []) else { return .skip(length: 3) }
            return .key(key, length: 3)
        case 0x1B:
            return .key(.escape, length: 1)
        default:
            return .key(.escape, length: 2)
        }
    }

    private static func csiKey(final: UInt8, parameters: ArraySlice<UInt8>) -> TerminalKey? {
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "Z"): return .backTab
        case UInt8(ascii: "~"):
            let code = parameters.prefix { $0 != UInt8(ascii: ";") }
            switch String(decoding: code, as: UTF8.self) {
            case "1", "7": return .home
            case "4", "8": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            default: return nil
            }
        default: return nil
        }
    }

    private static func character(in bytes: [UInt8], at index: Int) -> Step {
        let lead = bytes[index]
        let length: Int
        switch lead {
        case 0x00...0x7F: length = 1
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return .skip(length: 1)
        }
        guard index + length <= bytes.count else { return .incomplete }
        guard let text = String(validating: bytes[index..<(index + length)], as: UTF8.self), let character = text.first else {
            return .skip(length: 1)
        }
        return .key(.character(character), length: length)
    }
}
