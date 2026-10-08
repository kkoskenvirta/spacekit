import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI
import Synchronization

enum Output {
    static func warn(_ text: String) {
        FileHandle.standardError.write(Data(("warning: ".fg(ANSI.review) + text + "\n").utf8))
    }

    /// Writes lines to stdout, or to stderr when stdout is reserved for JSON.
    static func emit(_ lines: [String], toStandardError: Bool = false) {
        guard toStandardError else {
            lines.forEach { print($0) }
            return
        }
        FileHandle.standardError.write(Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// Asks a yes/no question on an interactive terminal; returns `false` otherwise.
    static func confirm(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print(question + " [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    static func size(_ bytes: UInt64, width: Int = 9) -> String {
        ANSI.pad(ByteCount.format(bytes), to: width, alignRight: true)
    }

    /// Text from the disk, a rule file, the config or a tool, made safe to print (see `TerminalText`).
    static func safe(_ text: String) -> String { TerminalText.sanitize(text) }

    /// A path for display: abbreviated and made safe to print.
    static func path(_ path: String) -> String { TerminalText.sanitize(PathUtil.abbreviate(path)) }

    /// Multi-line text (YAML, tool output) made safe to print line by line, keeping its line breaks.
    static func safeLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { TerminalText.sanitize(String($0)) }.joined(separator: "\n")
    }
}

/// Live progress on stderr while a scan runs (only on a terminal).
final class ProgressReporter: Sendable {
    private let progress: ScanProgress
    private let label: String
    private let running = Atomic<Bool>(false)
    private let enabled = isatty(STDERR_FILENO) != 0

    init(_ progress: ScanProgress, label: String) {
        self.progress = progress
        self.label = label
    }

    func start() {
        guard enabled else { return }
        running.store(true, ordering: .sequentiallyConsistent)
        Thread { [self] in
            var tick = 0
            while running.load(ordering: .sequentiallyConsistent) {
                let p = progress.snapshot
                let line =
                    "\r\u{1B}[2K\(Spinner.frame(tick)) \(label) \(ByteCount.format(p.bytes)) · \(p.files.formatted()) files · \(p.directories.formatted()) folders"
                FileHandle.standardError.write(Data(line.utf8))
                tick += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        }
        .start()
    }

    func stop() {
        guard enabled else { return }
        running.store(false, ordering: .sequentiallyConsistent)
        Thread.sleep(forTimeInterval: 0.12)
    }

    /// Runs `body` with a live progress line.
    static func run<T>(_ label: String, progress: ScanProgress = ScanProgress(), _ body: (ScanProgress) throws -> T) rethrows -> T {
        let reporter = ProgressReporter(progress, label: label)
        reporter.start()
        defer { reporter.stop() }
        return try body(progress)
    }
}

extension SafetyLevel {
    var heading: String { "\(emoji) \(title.uppercased())" }
}

// MARK: Arguments

extension SafetyLevel: ExpressibleByArgument {
    public init?(argument: String) { self.init(alias: argument) }
}

extension Job.Mode: ExpressibleByArgument {}
extension Job.Action: ExpressibleByArgument {}

/// Parsers for option values, so a bad value is rejected with a useful message before a command runs.
enum Parse {
    /// An `--older-than` / `--keep-recent` age: at least a day, so `6m` (minutes) isn't taken for `6mo`.
    static func retention(_ text: String) throws -> Age {
        switch Age.parseRetention(text) {
        case .success(let age): return age
        case .failure(let error): throw ValidationError(error.message)
        }
    }

    static func age(_ text: String) throws -> Age {
        guard let age = Age.parse(text) else { throw ValidationError("Invalid age '\(Output.safe(text))'. Use values like 30m, 1h or 2d.") }
        return age
    }

    static func size(_ text: String) throws -> ByteCount {
        guard let size = ByteCount.parse(text) else {
            throw ValidationError("Invalid size '\(Output.safe(text))'. Use values like 500MB, 30GB.")
        }
        return size
    }

    static func schedule(_ text: String) throws -> Schedule {
        guard let schedule = Schedule.parse(text) else { throw ValidationError("Couldn't understand schedule '\(Output.safe(text))'") }
        return schedule
    }
}
