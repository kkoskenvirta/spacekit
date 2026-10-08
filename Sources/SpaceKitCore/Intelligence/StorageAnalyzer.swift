import Foundation

/// The result of evaluating rules.
public struct Analysis: Sendable {
    public var findings: [Finding]
    public var tree: ScanTree
    /// Problems with the rules as the analysis resolved them (`RuleEngine.issues`).
    public var ruleIssues: [RuleIssue]

    public init(findings: [Finding], tree: ScanTree, ruleIssues: [RuleIssue] = []) {
        self.findings = findings
        self.tree = tree
        self.ruleIssues = ruleIssues
    }

    /// When the scan behind the findings started: the tree's. Findings merged in from a later targeted scan keep
    /// this earlier time, which only ever leaves more alone.
    public var scanStarted: Date { tree.scanStarted }

    public func findings(_ level: SafetyLevel) -> [Finding] { findings.filter { $0.safety == level } }

    public func total(_ level: SafetyLevel) -> UInt64 { findings(level).reduce(0) { $0 &+ $1.size } }

    /// Findings grouped by `rule.group` (Xcode, JavaScript, Ollama, …), largest group first.
    public var groups: [FindingGroup] {
        Dictionary(grouping: findings, by: \.rule.group)
            .map { FindingGroup(name: $0.key, findings: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
    }

    public func finding(ruleID: String) -> Finding? { findings.first { $0.rule.id == ruleID } }
}

public struct FindingGroup: Sendable, Identifiable {
    public var name: String
    public var findings: [Finding]
    public var id: String { name }
    public var size: UInt64 { findings.reduce(0) { $0 &+ $1.size } }
}

/// Runs the scans that rules need and evaluates them.
public struct StorageAnalyzer: Sendable {
    public var library: RuleLibrary
    public var scanOptions: ScanOptions
    public var devRoots: [String]

    public init(library: RuleLibrary, scanOptions: ScanOptions = ScanOptions(), devRoots: [String] = ScanSettings.defaultDevRoots) {
        self.library = library
        var options = scanOptions
        // Pattern rules read these marker bits, so the scan must record exactly this library's markers.
        options.markers = library.markerRegistry
        self.scanOptions = options
        self.devRoots = devRoots
    }

    /// Evaluates `rules` (all rules by default). If `tree` already covers every location the rules need,
    /// no scanning happens; otherwise the needed locations are scanned in one parallel pass. With nothing
    /// to look at, the home folder is scanned and there are no findings.
    ///
    /// Only the locations of `rules` are scanned, but every rule of the library claims its share there, so each
    /// of `rules` finds what it would in a full analysis: never something another rule (or a protected rule) claims.
    public func analyze(
        rules: [Rule]? = nil,
        reusing tree: ScanTree? = nil,
        progress: ScanProgress = ScanProgress()
    ) async throws -> Analysis {
        let plan = prepare(rules)
        if let tree, plan.roots.allSatisfy(tree.covers) { return evaluate(plan, on: tree) }
        let roots = plan.roots.isEmpty ? [PathUtil.home] : plan.roots
        return evaluate(plan, on: try await Scanner(options: scanOptions).scan(roots: roots, progress: progress))
    }

    /// Synchronous variant of `analyze` for command-line use.
    public func analyzeSync(rules: [Rule]? = nil, reusing tree: ScanTree? = nil, progress: ScanProgress = ScanProgress()) throws
        -> Analysis
    {
        let plan = prepare(rules)
        if let tree, plan.roots.allSatisfy(tree.covers) { return evaluate(plan, on: tree) }
        let roots = plan.roots.isEmpty ? [PathUtil.home] : plan.roots
        return evaluate(plan, on: try Scanner(options: scanOptions).scan(roots: roots, progress: progress))
    }

    /// What one analysis evaluates: an engine with every rule, the locations to scan, and whose findings to keep
    /// (`nil`: all).
    private struct Plan {
        var engine: RuleEngine
        var roots: [String]
        var selected: Set<String>?
    }

    private func prepare(_ rules: [Rule]?) -> Plan {
        guard let rules else {
            let engine = RuleEngine(rules: library.rules, devRoots: devRoots)
            return Plan(engine: engine, roots: engine.requiredRoots(), selected: nil)
        }
        let roots = RuleEngine(rules: rules, devRoots: devRoots).requiredRoots()
        // The library's order decides ties between equally specific rules, as in a full analysis. Rules from
        // elsewhere (a job's own folders) come last.
        var given: [String: Rule] = [:]
        for rule in rules where given[rule.id] == nil { given[rule.id] = rule }
        var seen = Set(library.rules.map(\.id))
        let others = rules.filter { seen.insert($0.id).inserted }
        let all = library.rules.map { given[$0.id] ?? $0 } + others
        return Plan(engine: RuleEngine(rules: all, devRoots: devRoots), roots: roots, selected: Set(given.keys))
    }

    private func evaluate(_ plan: Plan, on tree: ScanTree) -> Analysis {
        let issues = plan.engine.issues
        guard !plan.roots.isEmpty else { return Analysis(findings: [], tree: tree, ruleIssues: issues) }
        let findings = plan.engine.evaluate(tree)
        guard let selected = plan.selected else { return Analysis(findings: findings, tree: tree, ruleIssues: issues) }
        return Analysis(findings: findings.filter { selected.contains($0.rule.id) }, tree: tree, ruleIssues: issues)
    }
}
