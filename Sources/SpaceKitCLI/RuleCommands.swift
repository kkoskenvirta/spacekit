import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI
import Yams

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Browse, validate and write storage rules.",
        subcommands: [List.self, Show.self, Validate.self, New.self, Dirs.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List known rules.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var selection: RuleSelection
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            let rules = try selection.select(from: context.library)
            if json {
                try Output.json(rules)
                return
            }
            var group = ""
            for rule in rules.sorted(by: { ($0.group, $0.name) < ($1.group, $1.name) }) {
                if rule.group != group {
                    group = rule.group
                    print()
                    print(Output.safe(group).bold)
                }
                let location = Output.safe(
                    rule.paths.first.map { PathUtil.abbreviate($0) } ?? rule.match.map { "**/" + $0.names.joined(separator: ", ") } ?? "")
                print(
                    "  " + "●".fg(ANSI.color(for: rule.safety.level)) + " " + ANSI.pad(Output.safe(rule.id), to: 36)
                        + ANSI.pad(ANSI.truncate(Output.safe(rule.name), to: 30), to: 32) + location.dim)
            }
            print()
            print(
                "\(rules.count) rules · ".dim
                    + "built-in: \(Output.safe(BuiltinRules.standard.origin))".dim)
            for issue in context.library.issues where issue.severity == .error { Output.warn(Output.safe(issue.description)) }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a rule as YAML.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Rule id.") var id: String
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            guard let rule = context.library.rule(id: id) else { throw ValidationError("Unknown rule '\(Output.safe(id))'") }
            if json {
                try Output.json(rule)
                return
            }
            if let source = rule.source { print("# \(Output.path(source))".dim) }
            print(Output.safeLines(try YAMLEncoder().encode(rule)))
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate rule files (default: every loaded rule).",
            discussion: "Files are judged as your own rules, including whether a rule with a built-in id only narrows it.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Rule files to check.") var files: [String] = []
        @Flag(name: .long, help: "Judge the files as built-in rules (for a file in the repository's rules/ folder).")
        var builtin = false

        func run() throws {
            var issues: [RuleIssue] = []
            var count = 0
            if files.isEmpty {
                let library = global.loadContext().library
                issues = library.issues
                count = library.rules.count
            } else {
                let checked = RuleLibrary.check(files: files.map { PathUtil.expandArgument($0) }, asBuiltin: builtin)
                issues = checked.issues
                count = checked.rules.count
            }
            for issue in issues {
                let text = Output.safe(issue.description)
                print(issue.severity == .error ? text.fg(ANSI.protected) : text.fg(ANSI.review))
            }
            let errors = issues.filter { $0.severity == .error }.count
            print(
                "\(count) rules checked, \(errors) error\(errors == 1 ? "" : "s"), \(issues.count - errors) warning\(issues.count - errors == 1 ? "" : "s")."
            )
            if errors > 0 { throw ExitCode.failure }
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Scaffold a new rule in your rules folder.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Display name.") var name: String
        @Option(name: .long, help: "Location (repeatable).") var path: [String] = []
        @Option(name: .long, help: "Folder name to match anywhere (instead of --path).") var match: String?
        @Option(name: .long, help: "File that must sit next to a match (e.g. package.json).") var sibling: String?
        @Option(name: .long, help: "safe, review or protected.") var safety: SafetyLevel = .review
        @Option(name: .long, help: "Group name.") var group: String = "Custom"
        @Flag(name: .customLong("print"), help: "Print instead of writing a file.") var printOnly = false

        func validate() throws {
            guard !path.isEmpty || match != nil else { throw ValidationError("Give --path or --match") }
        }

        func run() throws {
            let rule = RuleScaffold.rule(name: name, paths: path, match: match, sibling: sibling, safety: safety, group: group)
            let id = rule.id
            let yaml = try RuleScaffold.yaml(rule)
            let issues = RuleLibrary(rules: [rule]).validate()
            for issue in issues { Output.warn(Output.safe(issue.message)) }
            if printOnly {
                print(yaml)
                return
            }
            let context = global.loadContext()
            let file = context.paths.userRulesDirectory + "/\(Rule.slug(name)).yaml"
            guard !FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("\(Output.path(file)) already exists")
            }
            try context.paths.ensureUserRulesDirectory()
            try SpaceKitPaths.writeRuleFile(yaml, to: file)
            print("Wrote \(Output.path(file)). Try it: " + "spacekit dev --rule \(Output.safe(id))".bold)
        }
    }

    struct Dirs: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dirs", abstract: "Print where rules are loaded from.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            print("built-in: \(Output.safe(BuiltinRules.standard.origin))")
            for directory in context.ruleDirectories {
                let missing = FileManager.default.fileExists(atPath: directory) ? "" : " (not created yet)".dim
                print("user:     \(Output.safe(directory))" + missing)
            }
        }
    }
}
