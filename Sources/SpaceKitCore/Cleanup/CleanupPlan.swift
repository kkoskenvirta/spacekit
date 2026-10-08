import Foundation

/// One thing a cleanup will remove.
public struct CleanupItem: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var kind: FindingItem.Kind
    public var name: String
    public var size: UInt64
    public var ruleID: String?
    public var isRepository: Bool
    public var containsRepository: Bool
    public var lastUsed: Date?
    /// For loose files: the names the preview counted, the only ones the executor removes. `nil` for other kinds,
    /// and for loose-files items saved before names were recorded (those can't remove anything; refresh them).
    public var looseFileNames: [String]?
    /// When the scan this item came from started. Loose files and Trash entries changed after it weren't in the
    /// preview, so the executor leaves them alone. Each item keeps its own time, so a plan may mix items from
    /// different scans (a cleanup list kept across rescans). `nil` for an item from no scan, or one saved before
    /// this was recorded: its loose files and Trash entries are never removed.
    public var scanStarted: Date?

    public var id: String { kind == .looseFiles ? CleanupItem.looseFilesPath(in: path) : path }

    /// How "the plain files directly inside `directory`" is written in verdicts, ids and the journal.
    public static func looseFilesPath(in directory: String) -> String { PathUtil.join(directory, "*") }

    public init(
        path: String, kind: FindingItem.Kind = .directory, name: String? = nil, size: UInt64, ruleID: String? = nil,
        isRepository: Bool = false, containsRepository: Bool = false, lastUsed: Date? = nil, looseFileNames: [String]? = nil,
        scanStarted: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.name = name ?? PathUtil.lastComponent(path)
        self.size = size
        self.ruleID = ruleID
        self.isRepository = isRepository
        self.containsRepository = containsRepository
        self.lastUsed = lastUsed
        self.looseFileNames = looseFileNames
        self.scanStarted = scanStarted
    }

    /// A finding's item, from a scan that started at `scanStarted`.
    public init(_ item: FindingItem, ruleID: String?, scanStarted: Date) {
        self.init(
            path: item.path, kind: item.kind, name: item.displayName, size: item.size, ruleID: ruleID,
            isRepository: item.isRepository, containsRepository: item.containsRepository, lastUsed: item.lastUsed,
            looseFileNames: item.looseFileNames, scanStarted: scanStarted)
    }
}

/// A tool command that frees space its own way (e.g. `docker builder prune`).
public struct PlannedCommand: Codable, Sendable, Hashable, Identifiable {
    public var ruleID: String
    public var arguments: [String]
    /// Best guess of what it frees, from the rule's last scan.
    public var estimatedBytes: UInt64
    /// Paths the command is expected to shrink; rescanned afterwards to measure the result.
    public var measurePaths: [String]
    /// For a rule's `itemCommand`: the item substituted for `{path}` and `{name}`. The executor checks it with
    /// the `SafetyGuard` like any other item. `nil` for whole-rule commands.
    public var itemPath: String?
    /// For a rule's `ai.removeCommand`: the model substituted for `{name}`. `nil` otherwise.
    public var modelName: String?
    public var id: String { ruleID + ":" + arguments.joined(separator: " ") }

    public init(
        ruleID: String, arguments: [String], estimatedBytes: UInt64, measurePaths: [String] = [], itemPath: String? = nil,
        modelName: String? = nil
    ) {
        self.ruleID = ruleID
        self.arguments = arguments
        self.estimatedBytes = estimatedBytes
        self.measurePaths = measurePaths
        self.itemPath = itemPath
        self.modelName = modelName
    }

    public var displayString: String {
        arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// What a cleanup will do, computed before anything is touched. Plans are shown to the person (or saved as a
/// suggestion) and then executed by `CleanupExecutor`, which re-checks every item.
public struct CleanupPlan: Codable, Sendable, Equatable {
    public var items: [CleanupItem]
    public var commands: [PlannedCommand]
    /// Instructions for things that must be cleaned in another app.
    public var manualSteps: [String]
    /// Move items to the Trash instead of deleting them.
    public var useTrash: Bool

    public init(items: [CleanupItem] = [], commands: [PlannedCommand] = [], manualSteps: [String] = [], useTrash: Bool = true) {
        self.items = items
        self.commands = commands
        self.manualSteps = manualSteps
        self.useTrash = useTrash
    }

    public var totalBytes: UInt64 {
        items.reduce(0) { $0 &+ $1.size } &+ commands.reduce(0) { $0 &+ $1.estimatedBytes }
    }

    public var isEmpty: Bool { items.isEmpty && commands.isEmpty }

    /// This plan with only the items and commands `other` also has, by id. The rest (manual steps, the Trash setting)
    /// is this plan's.
    func narrowed(to other: CleanupPlan) -> CleanupPlan {
        let items = Set(other.items.map(\.id))
        let commands = Set(other.commands.map(\.id))
        var narrowed = self
        narrowed.items = self.items.filter { items.contains($0.id) }
        narrowed.commands = self.commands.filter { commands.contains($0.id) }
        return narrowed
    }

    /// The order every preview lists items in.
    public var itemsLargestFirst: [CleanupItem] { items.sorted { $0.size > $1.size } }

    /// Builds a plan from findings. `select` chooses which items of each finding to include (all by default).
    /// `trashPreference`: `true` forces the Trash; `nil` follows each rule's `safety.trash`.
    /// `scanStarted`: when the scan behind the findings started (`Analysis.scanStarted`).
    public static func make(
        findings: [Finding],
        trashPreference: Bool? = true,
        scanStarted: Date,
        select: (Finding) -> [FindingItem] = { $0.items }
    ) -> CleanupPlan {
        var plan = CleanupPlan(useTrash: true)
        var allRulesWantDelete = !findings.isEmpty
        for finding in findings where finding.rule.safety.level != .protected {
            let rule = finding.rule
            let chosen = select(finding)
            guard !chosen.isEmpty else { continue }
            if let command = rule.action.command {
                plan.commands.append(
                    PlannedCommand(
                        ruleID: rule.id, arguments: command,
                        estimatedBytes: chosen.reduce(0) { $0 &+ $1.size },
                        measurePaths: rule.paths.flatMap { PathUtil.glob($0) }))
            } else if let template = rule.action.itemCommand {
                // Per-item commands name real entries (a toolchain, a spec repo); loose files aren't one.
                for item in chosen where item.kind != .looseFiles {
                    plan.commands.append(
                        PlannedCommand(
                            ruleID: rule.id, arguments: itemArguments(template, path: item.path), estimatedBytes: item.size,
                            measurePaths: [item.path], itemPath: item.path))
                }
            } else if rule.action.remove {
                plan.items += chosen.map { CleanupItem($0, ruleID: rule.id, scanStarted: scanStarted) }
                if rule.safety.trash || rule.safety.level != .safe { allRulesWantDelete = false }
            } else if let manual = rule.action.manual {
                plan.manualSteps.append("\(rule.name): \(manual)")
            }
        }
        plan.useTrash = trashPreference ?? !allRulesWantDelete
        return plan
    }

    /// An `itemCommand` filled in for one item: `{path}` is its absolute path, `{name}` its last path component
    /// (not the display name, which may carry a project prefix).
    static func itemArguments(_ template: [String], path: String) -> [String] {
        template.map {
            $0.replacingOccurrences(of: "{name}", with: PathUtil.lastComponent(path)).replacingOccurrences(of: "{path}", with: path)
        }
    }
}
