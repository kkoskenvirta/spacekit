import Testing

@testable import SpaceKitCore

@Suite("Terminal width")
struct TerminalWidthTests {
    @Test("ASCII, accents and combining marks take one column per letter")
    func narrow() {
        #expect(TerminalWidth.columns("report.pdf") == 10)
        #expect(TerminalWidth.columns("Café") == 4)
        #expect(TerminalWidth.columns("Cafe\u{301}") == 4)
        #expect(TerminalWidth.columns("") == 0)
    }

    @Test("Emoji shown as pictures take two columns")
    func emoji() {
        #expect(TerminalWidth.columns("🟢") == 2)
        #expect(TerminalWidth.columns("📸 photos") == 9)
        #expect(TerminalWidth.columns("⌚") == 2)
        #expect(TerminalWidth.columns("👍🏽") == 2)
        #expect(TerminalWidth.columns("👨‍👩‍👧") == 2)
        #expect(TerminalWidth.columns("🇫🇮") == 2)
        #expect(TerminalWidth.columns("1️⃣") == 2)
    }

    @Test("A text symbol is one column, or two with the emoji variation selector")
    func variationSelectors() {
        #expect(TerminalWidth.columns("⚠") == 1)
        #expect(TerminalWidth.columns("⚠\u{FE0F}") == 2)
        #expect(TerminalWidth.columns("❤\u{FE0F} x") == 4)
        #expect(TerminalWidth.columns("⌚\u{FE0E}") == 1)
        #expect(TerminalWidth.columns("●") == 1)
    }

    @Test("East Asian wide characters take two columns")
    func wide() {
        #expect(TerminalWidth.columns("写真") == 4)
        #expect(TerminalWidth.columns("한국") == 4)
        #expect(TerminalWidth.columns("ＡＢ") == 4)
    }

    @Test("Escape sequences take no columns")
    func escapes() {
        #expect(TerminalWidth.columns("\u{1B}[1;38;5;75mbold\u{1B}[0m") == 4)
        #expect(TerminalWidth.columns("\u{1B}[?25lx\u{1B}[2J") == 1)
        #expect(TerminalWidth.columns("\u{1B}[48;5;237m🟢 ok\u{1B}[0m") == 5)
    }

    @Test("A prefix never splits a wide character or an escape sequence")
    func prefix() {
        #expect(TerminalWidth.prefix("abcdef", columns: 3) == ("abc", 3))
        #expect(TerminalWidth.prefix("a🟢b", columns: 2) == ("a", 1))
        #expect(TerminalWidth.prefix("a🟢b", columns: 3) == ("a🟢", 3))
        #expect(TerminalWidth.prefix("\u{1B}[1mab\u{1B}[0mcd", columns: 3) == ("\u{1B}[1mab\u{1B}[0mc", 3))
        #expect(TerminalWidth.prefix("abc", columns: 0) == ("", 0))
        #expect(TerminalWidth.prefix("abc", columns: -4) == ("", 0))
    }
}

@Suite("Key parser")
struct KeyParserTests {
    private func keys(_ text: String) -> [TerminalKey] { KeyParser.parse(Array(text.utf8)).keys }

    @Test("Every key in one read is returned")
    func severalKeys() {
        #expect(keys("jjk") == [.character("j"), .character("j"), .character("k")])
        #expect(keys("\u{1B}[B\u{1B}[B\u{1B}[A") == [.down, .down, .up])
        #expect(keys("d y") == [.character("d"), .space, .character("y")])
    }

    @Test("Cursor, paging and editing keys")
    func sequences() {
        #expect(keys("\u{1B}[A\u{1B}OB\u{1B}[C\u{1B}[D") == [.up, .down, .right, .left])
        #expect(keys("\u{1B}[5~\u{1B}[6~") == [.pageUp, .pageDown])
        #expect(keys("\u{1B}[H\u{1B}[F\u{1B}[1~\u{1B}[4~") == [.home, .end, .home, .end])
        #expect(keys("\u{1B}[Z\t\r\u{7F}") == [.backTab, .tab, .enter, .backspace])
        #expect(keys("\u{1B}[1;5A") == [.up])
        #expect(keys("\u{3}") == [.control("c")])
    }

    @Test("Escape twice and as Alt")
    func escapeKey() {
        #expect(keys("\u{1B}\u{1B}[B") == [.escape, .down])
        #expect(keys("\u{1B}q") == [.escape])
    }

    @Test("A lone Escape at the end of a read waits for the rest of a possible arrow key")
    func trailingEscape() {
        let alone = KeyParser.parse([0x1B])
        #expect(alone.keys.isEmpty && alone.rest == [0x1B])
        let split = KeyParser.parse(alone.rest + Array("[B".utf8))
        #expect(split.keys == [.down] && split.rest.isEmpty)
        #expect(KeyParser.parse(Array("j\u{1B}\u{1B}".utf8)).keys == [.character("j"), .escape])
    }

    @Test("When no more bytes come, a lone Escape is the Escape key and a cut-off sequence is dropped")
    func flushing() {
        #expect(KeyParser.flush([0x1B]) == [.escape])
        #expect(KeyParser.flush(Array("\u{1B}[".utf8)).isEmpty)
        #expect(KeyParser.flush(Array(Array("🟢".utf8).prefix(2))).isEmpty)
        #expect(KeyParser.flush([]).isEmpty)
    }

    @Test("Unknown sequences are skipped without eating the next key")
    func unknown() {
        #expect(keys("\u{1B}[3~x") == [.character("x")])
        #expect(keys("\u{1B}[200~q") == [.character("q")])
        #expect(keys("\u{1B}OPq") == [.character("q")])
    }

    @Test("Multi-byte characters are kept whole")
    func unicode() {
        #expect(keys("é写🟢") == [.character("é"), .character("写"), .character("🟢")])
        #expect(KeyParser.parse([0xFF, UInt8(ascii: "a")]).keys == [.character("a")])
    }

    @Test("A sequence cut off at the end of a read is handed back")
    func incomplete() {
        let cut = KeyParser.parse(Array("j\u{1B}[".utf8))
        #expect(cut.keys == [.character("j")])
        #expect(cut.rest == Array("\u{1B}[".utf8))
        let resumed = KeyParser.parse(cut.rest + Array("B".utf8))
        #expect(resumed.keys == [.down] && resumed.rest.isEmpty)

        let photo = Array("🟢".utf8)
        let half = KeyParser.parse(Array(photo.prefix(2)))
        #expect(half.keys.isEmpty && half.rest == Array(photo.prefix(2)))
        #expect(KeyParser.parse(Array("\u{1B}O".utf8)).rest == Array("\u{1B}O".utf8))
    }
}

@Suite("Scrolling")
struct ScrollingTests {
    @Test("The window follows the selection and stays inside the list")
    func follow() {
        var window = ScrollWindow()
        #expect(window.follow(selection: 0, visible: 5, count: 20) == 0..<5)
        #expect(window.follow(selection: 7, visible: 5, count: 20) == 3..<8)
        #expect(window.follow(selection: 5, visible: 5, count: 20) == 3..<8)
        #expect(window.follow(selection: 1, visible: 5, count: 20) == 1..<6)
        #expect(window.follow(selection: 19, visible: 5, count: 20) == 15..<20)
        #expect(window.follow(selection: 19, visible: 50, count: 20) == 0..<20)
    }

    @Test("Tiny screens, empty lists and stale selections never give an invalid range")
    func degenerate() {
        var window = ScrollWindow(offset: 40)
        #expect(window.follow(selection: 3, visible: 0, count: 10) == 0..<0)
        #expect(window.follow(selection: 3, visible: -7, count: 10) == 0..<0)
        #expect(window.follow(selection: 0, visible: 5, count: 0) == 0..<0)
        #expect(window.follow(selection: 99, visible: 3, count: 10) == 7..<10)
        #expect(window.follow(selection: -4, visible: 3, count: 10) == 0..<3)
        var shrunk = ScrollWindow(offset: 18)
        #expect(shrunk.follow(selection: 2, visible: 4, count: 3) == 0..<3)
        for visible in -2...12 {
            for count in 0...12 {
                for selection in -1...13 {
                    var any = ScrollWindow(offset: 6)
                    let range = any.follow(selection: selection, visible: visible, count: count)
                    #expect(range.lowerBound >= 0 && range.upperBound <= max(0, count))
                }
            }
        }
    }
}
