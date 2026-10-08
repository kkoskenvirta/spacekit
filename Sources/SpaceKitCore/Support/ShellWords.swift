/// Splits a command line such as `$EDITOR` (`code --wait`) into arguments the way a POSIX shell would, without
/// running a shell: whitespace separates words, single quotes are literal, double quotes allow `\"`, `\\`, `\$`
/// and `` \` `` escapes, and a backslash outside quotes escapes the next character. No expansion happens.
public enum ShellWords {
    /// The words of `text`, or `nil` if a quote is left open or the text ends in a lone backslash.
    public static func split(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                if quote == "\"" && !"\"\\$`".contains(character) { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            switch (quote, character) {
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case ("'", _):
                current.append(character)
            case ("\"", "\\"), (nil, "\\"):
                escaped = true
                inWord = true
            case ("\"", _):
                current.append(character)
            case (nil, "'"), (nil, "\""):
                quote = character
                inWord = true
            case (nil, _) where character.isWhitespace:
                if inWord { words.append(current) }
                current = ""
                inWord = false
            default:
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if inWord { words.append(current) }
        return words
    }
}
