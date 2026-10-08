import Testing

@testable import SpaceKitCore

@Suite("Terminal text")
struct TerminalTextTests {
    @Test("Plain text, including non-ASCII names, passes through unchanged")
    func plainText() {
        #expect(TerminalText.sanitize("~/Library/Caches/com.example") == "~/Library/Caches/com.example")
        #expect(TerminalText.sanitize("Café 📸 写真") == "Café 📸 写真")
        #expect(TerminalText.sanitize("") == "")
    }

    @Test("Escape sequences can't reach the terminal")
    func escapes() {
        #expect(TerminalText.sanitize("evil\u{1B}]0;title\u{07}name") == "evil\\u{1B}]0;title\\u{07}name")
        #expect(TerminalText.sanitize("\u{1B}[2J\u{1B}[H") == "\\u{1B}[2J\\u{1B}[H")
    }

    @Test("Line breaks and tabs are shown, not applied")
    func whitespaceControls() {
        #expect(TerminalText.sanitize("a\nb\rc\td") == "a\\nb\\rc\\td")
        #expect(TerminalText.sanitize("a\r\nb") == "a\\r\\nb")
    }

    @Test("Every C0, DEL and C1 control character is replaced")
    func allControls() {
        let controls = (0x00...0x1F).map { $0 } + [0x7F] + (0x80...0x9F).map { $0 }
        for value in controls {
            let scalar = Unicode.Scalar(UInt32(value))!
            let sanitized = TerminalText.sanitize("x" + String(Character(scalar)) + "y")
            #expect(!sanitized.unicodeScalars.contains(scalar), "U+\(String(value, radix: 16)) must be escaped")
            #expect(sanitized.hasPrefix("x\\") && sanitized.hasSuffix("y"))
        }
        #expect(TerminalText.sanitize("\u{9B}31m") == "\\u{9B}31m")
        #expect(TerminalText.sanitize("\u{7F}") == "\\u{7F}")
    }
}
