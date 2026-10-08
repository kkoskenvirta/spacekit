import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

/// Shared rule-selection options.
struct RuleSelection: ParsableArguments {
    @Option(name: .customLong("rule"), help: "Only this rule id (repeatable).")
    var rules: [String] = []
    @Option(name: .long, help: "Only rules in this category prefix (e.g. developer, ai, cache).")
    var category: String?
    @Option(name: .long, help: "Only rules with this safety level: safe, review or protected.")
    var safety: SafetyLevel?

    /// No filter given: every rule is selected.
    var selectsEverything: Bool { rules.isEmpty && category == nil && safety == nil }

    func select(from library: RuleLibrary) throws -> [Rule] {
        var selected = try rules.isEmpty
            ? library.rules
            : rules.map { id in
                guard let rule = library.rule(id: id) else {
                    throw ValidationError("Unknown rule '\(Output.safe(id))'. See `spacekit rules list`.")
                }
                return rule
            }
        if let category {
            let inCategory = Set(library.rules(inCategory: category).map(\.id))
            selected = selected.filter { inCategory.contains($0.id) }
        }
        if let safety { selected = selected.filter { $0.safety.level == safety } }
        return selected
    }
}

struct DevCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Dev Intelligence: developer storage on this Mac, and what's actually safe to remove."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var selection: RuleSelection
    @Option(name: .long, help: "Items to list per rule (0 = none).")
    var items: Int = 0
    @Flag(name: .long, help: "Machine-readable output.")
    var json = false

    func validate() throws {
        guard items >= 0 else { throw ValidationError("--items must be 0 or more") }
    }

    func run() throws {
        let context = global.loadContext()
        let rules = try selection.select(from: context.library)
        let analysis = try ProgressReporter.run("Analysing") { try context.analyzer.analyzeSync(rules: rules, progress: $0) }
        // Only a run over every rule is a complete picture worth keeping in the history.
        if selection.selectsEverything {
            try? context.history.recordSnapshot(analysis: analysis)
        }
        if json {
            try Output.json(analysis.findings.map(FindingJSON.init))
            return
        }
        if analysis.findings.isEmpty {
            print("Nothing found for these rules.")
            return
        }
        if selection.rules.count == 1, let finding = analysis.findings.first {
            printDetail(finding)
            return
        }
        print(
            "DEV INTELLIGENCE".bold
                + "  ·  scanned \(analysis.tree.stats.files.formatted()) files in \(String(format: "%.1f", analysis.tree.stats.duration))s"
                .dim)
        for level in SafetyLevel.allCases {
            let findings = analysis.findings(level)
            guard !findings.isEmpty else { continue }
            print()
            print(level.heading.bold.fg(ANSI.color(for: level)) + " · " + ByteCount.format(analysis.total(level)).bold)
            for finding in findings {
                let used = finding.lastUsed.map { "used " + $0.relativeDescription() } ?? ""
                let count = "\(finding.items.count) item\(finding.items.count == 1 ? "" : "s")"
                print(
                    "  " + ANSI.pad(Output.safe(finding.rule.name), to: 34) + ANSI.pad(Output.safe(finding.rule.group).dim, to: 18)
                        + Output.size(finding.size).bold
                        + "  " + ANSI.pad(count.dim, to: 12) + used.dim)
                if items > 0 {
                    for item in finding.items.prefix(items) {
                        print(
                            "      " + Output.size(item.size) + "  " + Output.path(item.path).dim
                                + (item.idleDays().map { "  \($0)d idle".dim } ?? ""))
                    }
                }
            }
        }
        print()
        let safe = analysis.total(.safe)
        if safe > 0 {
            print("Regenerable data you can reclaim: " + ByteCount.format(safe).bold.fg(ANSI.safe))
            print(
                "Preview a cleanup:  ".dim + "spacekit clean --safety safe".bold + "    Details:  ".dim
                    + "spacekit dev --rule <id> --items 20".bold)
        }
    }

    private func printDetail(_ finding: Finding) {
        let rule = finding.rule
        print(Output.safe(rule.name).bold + " — " + ByteCount.format(finding.size).bold)
        print()
        if let description = rule.description { print(Output.safe(description)) }
        print()
        for fact in finding.terminalFacts() { print("  " + ANSI.pad(fact.label + ":", to: 15).dim + fact.value) }
        print()
        for item in finding.items.prefix(max(items, 15)) {
            print(
                "  " + Output.size(item.size) + "  " + ANSI.pad((item.idleDays().map { "\($0)d" } ?? "–").dim, to: 6, alignRight: true)
                    + "  " + Output.path(item.path))
        }
        if finding.items.count > max(items, 15) { print("  … \(finding.items.count - max(items, 15)) more".dim) }
        if finding.isCleanable {
            print()
            print("Clean \(ByteCount.format(finding.size)):  ".dim + "spacekit clean \(Output.safe(rule.id))".bold)
        }
    }
}

struct FindingJSON: Encodable {
    var rule: String
    var name: String
    var group: String
    var category: String
    var safety: String
    var bytes: UInt64
    var lastUsed: Date?
    var items: [FindingItem]

    init(_ finding: Finding) {
        rule = finding.rule.id
        name = finding.rule.name
        group = finding.rule.group
        category = finding.rule.category
        safety = finding.safety.rawValue
        bytes = finding.size
        lastUsed = finding.lastUsed
        items = finding.items
    }
}

struct AICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "AI Development storage: local models, hubs and caches, and how much is idle."
    )

    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Machine-readable output.")
    var json = false

    func run() throws {
        let context = global.loadContext()
        let rules = context.library.rules.filter { $0.ai != nil }
        let analysis = try ProgressReporter.run("Looking for local AI storage") {
            try context.analyzer.analyzeSync(rules: rules, progress: $0)
        }
        let report = AIInspector.report(
            findings: analysis.findings, tree: analysis.tree, activeWindow: context.config.automation.activeModelWindow)
        if json {
            try Output.json(AIJSON(report))
            return
        }
        guard report.total > 0 else {
            print("No local AI storage found (Ollama, Hugging Face, LM Studio, PyTorch, Whisper, …).")
            return
        }
        let days = Int(report.activeWindow.days)
        print("LOCAL AI".bold + String(repeating: " ", count: 34) + ByteCount.format(report.total).bold)
        print()
        for tool in report.tools {
            print(ANSI.pad(Output.safe(tool.name).bold, to: 42) + Output.size(tool.size).bold)
            for (index, model) in tool.models.enumerated() {
                let branch = index == tool.models.count - 1 ? "└ " : "├ "
                let state = model.status(within: report.activeWindow).terminalText
                let used = model.lastUsed.map { $0.relativeDescription() } ?? ""
                print(
                    branch.dim + ANSI.pad(ANSI.truncate(Output.safe(model.name), to: 38), to: 40) + Output.size(model.size) + "  "
                        + ANSI.pad(state, to: 9) + " " + used.dim)
            }
            print()
        }
        print("AI storage".bold + "                                " + ByteCount.format(report.total).bold)
        print("Potentially reclaimable".fg(ANSI.safe) + "                   " + ByteCount.format(report.reclaimable()))
        print("Models you're actively using".dim + "              " + ByteCount.format(report.active()))
        print("Unused for \(days)+ days".fg(ANSI.review) + "                    " + ByteCount.format(report.unused()))
        print()
        print("Remove an Ollama model with `ollama rm <name>`; other models from the TUI's AI view (spacekit tui).".dim)
    }
}

struct AIJSON: Encodable {
    struct Model: Encodable {
        var name: String
        var kind: String
        var bytes: UInt64
        var lastUsed: Date?
        var active: Bool
        var paths: [String]
        var removeCommand: [String]?
    }
    struct Tool: Encodable {
        var name: String
        var bytes: UInt64
        var models: [Model]
    }
    var total: UInt64
    var reclaimable: UInt64
    var active: UInt64
    var unused: UInt64
    var activeWindowDays: Int
    var tools: [Tool]

    init(_ report: AIReport) {
        total = report.total
        reclaimable = report.reclaimable()
        active = report.active()
        unused = report.unused()
        activeWindowDays = Int(report.activeWindow.days)
        tools = report.tools.map { tool in
            Tool(
                name: tool.name, bytes: tool.size,
                models: tool.models.map {
                    Model(
                        name: $0.name, kind: $0.kind.rawValue, bytes: $0.size, lastUsed: $0.lastUsed,
                        active: $0.isActive(within: report.activeWindow), paths: $0.paths, removeCommand: $0.removeCommand)
                })
        }
    }
}
