import Foundation
import Testing

@testable import SpaceKitCore

/// A script's `#!` line read the way the macOS kernel reads it (`exec_shell_imgact`, `exec_extract_strings`): within the
/// first 512 bytes, the interpreter up to the first space or tab, then the rest of the line split at spaces and tabs,
/// one argument per word (`man env`: Darwin splits where other systems hand over one argument); the line ends at a
/// newline or a `#`. `env` then reads those words with getopt.
@Suite("Program headers")
struct ProgramHeaderTests {
    func header(_ bytes: [UInt8]) throws -> ProgramHeader? {
        let tree = try TempTree()
        let path = tree.path("program")
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return ProgramHeader(reading: path)
    }

    func header(_ text: String) throws -> ProgramHeader? { try header(Array(text.utf8)) }

    @Test("The interpreter ends at the first space or tab, and the rest of the line is split into one argument per word")
    func scripts() throws {
        let table: [(String, String, [String])] = [
            ("#!/bin/sh\n", "/bin/sh", []),
            ("#!/bin/sh -e\n", "/bin/sh", ["-e"]),
            ("#!  /bin/sh\t-e  -x \t\necho", "/bin/sh", ["-e", "-x"]),
            ("#!/usr/bin/env -S perl -w\n", "/usr/bin/env", ["-S", "perl", "-w"]),
            ("#!/usr/local/bin/php -n -q -dsafe_mode=0\n", "/usr/local/bin/php", ["-n", "-q", "-dsafe_mode=0"]),
            ("#!/bin/sh # a comment\n", "/bin/sh", []),
            ("#!/bin/sh -e#x\n", "/bin/sh", ["-e"]),
            // A carriage return is neither a space nor the end of the line: the kernel looks for `sh\r`.
            ("#!/bin/sh\r\n", "/bin/sh\r", []),
            ("#!/bin/sh -e\r\n", "/bin/sh", ["-e\r"]),
        ]
        for (text, interpreter, arguments) in table {
            #expect(try header(text) == .script(interpreter: interpreter, arguments: arguments), "\(text.debugDescription)")
        }
    }

    @Test("A #! line the kernel won't run is told apart, so the program is refused rather than guessed at")
    func unclearLines() throws {
        let longest = "#!/" + String(repeating: "a", count: 508) + "\n"
        #expect(longest.utf8.count == ProgramHeader.lineLimit)
        #expect(try header(longest) == .script(interpreter: String(longest.dropFirst(2).dropLast()), arguments: []))
        let unclear = [
            "#!/bin/sh",  // no end of line
            "#!\n", "#!   \t\n", "#!# comment\n",  // no interpreter
            "#!/" + String(repeating: "a", count: 509) + "\n",  // the end of the line is past the limit
        ]
        for text in unclear {
            let read = try header(text)
            guard case .unclear = read else {
                Issue.record("\(text.prefix(40).debugDescription) read as \(String(describing: read))")
                continue
            }
        }
        guard case .unclear = try header(Array("#!/bin/s".utf8) + [0] + Array("h\n".utf8)) else {
            Issue.record("a NUL byte in the line")
            return
        }
    }

    /// env, like any `execvp` caller, runs a file the kernel won't load with `/bin/sh`, so only a Mach-O file counts as
    /// a program the system loads itself.
    @Test("Mach-O files are programs the system loads itself; anything else without #! is told apart")
    func compiled() throws {
        for magic in ProgramHeader.machOMagic {
            #expect(try header(magic + [0x0C, 0, 0, 1]) == .compiled, "\(magic)")
        }
        for bytes in [[], [0xCF, 0xFA], Array("#".utf8), Array("# !/bin/sh\n".utf8), Array("rm -rf ~\n".utf8)] {
            #expect(try header(bytes) == .notLoadable, "\(bytes)")
        }
    }

    /// `env` gets the line's words: options are read from them with getopt, `-S` splits what follows it into more
    /// words, and the first word that is neither an option nor `NAME=value` is the program. Anything SpaceKit can't
    /// follow with certainty (`-P`, `-C`, options macOS's env doesn't have, quotes, escapes, `${VAR}`, long options)
    /// gives `nil`, so the script is refused. So does a line that names no program: `env` would then run the script
    /// itself again.
    @Test("env's words from a #! line are read as macOS's env reads them")
    func envArguments() throws {
        let table: [(String, String?)] = [
            ("node", "node"), ("node --flag", "node"), ("-S node --flag", "node"), ("-S  -i  LANG=C node", "node"),
            ("-iSruby", "ruby"), ("-S -u HOME node", "node"), ("-S -uHOME node", "node"), ("-S -- node", "node"),
            ("-S -S node", "node"), ("-S -v -0 node", "node"), ("-S\tnode", "node"),
            // The kernel hands over each word apart, so options work without -S too.
            ("-i node", "node"), ("-u HOME node", "node"), ("-uHOME node", "node"), ("-v -0 node", "node"), ("-- node", "node"),
            ("LANG=C node", "node"), ("-i LANG=C PATH=/x perl -w", "perl"),
            // Nothing left to name a program: env would start the script again.
            ("", nil), ("-i", nil), ("-", nil), ("--", nil), ("-S", nil), ("-S -i", nil), ("-S LANG=C", nil), ("-u", nil),
            ("LANG=C", nil),
            // Can't be followed with certainty.
            ("-P /usr/bin node", nil), ("-S -P /usr/bin node", nil), ("-C /tmp node", nil), ("--split-string=node", nil),
            ("-S ${HOME}/node", nil), ("-S 'node'", nil), ("-S \"node\"", nil), ("-S node\\ x", nil), ("-S -x node", nil),
            ("-x node", nil),
            // FreeBSD's -L and -U: macOS's env doesn't have them.
            ("-L user node", nil), ("-U user node", nil), ("-Luser node", nil),
        ]
        for (rest, program) in table {
            guard case .script(let interpreter, let arguments)? = try header("#!/usr/bin/env \(rest)\n") else {
                Issue.record("\(rest) isn't read as a script")
                continue
            }
            #expect(interpreter == "/usr/bin/env")
            #expect(CommandTrust.envProgram(arguments) == program, "\(rest)")
        }
    }
}
