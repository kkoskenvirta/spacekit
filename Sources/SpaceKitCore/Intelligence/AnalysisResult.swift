import Foundation

/// An analysis with what every front end derives from it: the AI Development report and the rule index that labels
/// folders. Built once per analysis, then kept current in place after cleanups instead of analysing again.
public struct AnalysisResult: Sendable {
    public private(set) var analysis: Analysis
    public private(set) var aiReport: AIReport
    public private(set) var ruleIndex: RuleIndex
    private var rules: [Rule]
    private let patternRoots: [String]

    /// `rules` is the whole active library (the index labels any folder, not only those with findings).
    /// `patternRoots`: the config's `scan.devRoots`, where pattern rules without their own roots apply.
    public init(_ analysis: Analysis, rules: [Rule], activeModelWindow: Age, patternRoots: [String] = ScanSettings.defaultDevRoots) {
        self.analysis = analysis
        self.rules = rules
        self.patternRoots = patternRoots
        aiReport = AIInspector.report(findings: analysis.findings, tree: analysis.tree, activeWindow: activeModelWindow)
        ruleIndex = AnalysisResult.index(rules, analysis, patternRoots)
    }

    private static func index(_ rules: [Rule], _ analysis: Analysis, _ patternRoots: [String]) -> RuleIndex {
        RuleIndex(rules: rules, findings: analysis.findings, patternRoots: patternRoots)
    }

    /// When the scan behind the findings began: the Explore scan's if the analysis reused it, its own otherwise.
    /// Plans built from the findings are dated by it.
    public var scanStarted: Date { analysis.tree.started }

    /// Drops what a cleanup removed from the findings, shrinking the analysis tree too when it's a separate scan
    /// from `exploreTree` (which the front end updates itself, see `Removal.apply(_:to:)`). Only call it while
    /// nothing else reads the trees. Returns the rules whose findings changed.
    @discardableResult
    public mutating func apply(_ removals: [Removal], exploreTree: ScanTree?) -> Set<String> {
        guard !removals.isEmpty else { return [] }
        if analysis.tree !== exploreTree { Removal.apply(removals, to: analysis.tree) }
        let touched = analysis.apply(removals)
        guard !touched.isEmpty else { return [] }
        ruleIndex = AnalysisResult.index(rules, analysis, patternRoots)
        if touched.contains(where: { id in rules.contains { $0.id == id && $0.ai != nil } }) {
            aiReport = AIInspector.report(findings: analysis.findings, tree: analysis.tree, activeWindow: aiReport.activeWindow)
        }
        return touched
    }

    /// Takes the findings and AI models of `ruleIDs` from `fresh`, a targeted re-evaluation of just those rules
    /// (after their tool commands freed space their own way).
    public mutating func merge(_ fresh: AnalysisResult, for ruleIDs: Set<String>) {
        analysis.replaceFindings(for: ruleIDs, with: fresh.analysis.findings)
        aiReport = aiReport.replacingModels(from: ruleIDs, with: fresh.aiReport)
        ruleIndex = AnalysisResult.index(rules, analysis, patternRoots)
    }

    /// Labels folders with a reloaded rule library.
    public mutating func reindex(rules: [Rule]) {
        self.rules = rules
        ruleIndex = AnalysisResult.index(rules, analysis, patternRoots)
    }
}

extension Removal {
    /// Applies removals to the tree a front end shows. Returns whether it changed.
    @discardableResult
    public static func apply(_ removals: [Removal], to tree: ScanTree) -> Bool {
        var changed = false
        for removal in removals where removal.apply(to: tree) { changed = true }
        return changed
    }
}

extension CleanupReport {
    /// Rules whose tool command removed something. Commands free space their own way, so only a re-evaluation of
    /// these rules shows what's left.
    public var rulesToReevaluate: Set<String> {
        Set(commands.filter(\.outcome.isRemoved).map(\.command.ruleID))
    }
}

extension SpaceKitContext {
    /// The analysis with its AI report and rule index, for this context's rules and active-model window.
    public func result(of analysis: Analysis) -> AnalysisResult {
        AnalysisResult(
            analysis, rules: library.rules, activeModelWindow: config.automation.activeModelWindow, patternRoots: config.scan.devRoots)
    }

    /// Labels folders with this context's rules, applying pattern rules only where scans look for them.
    public var ruleIndex: RuleIndex { RuleIndex(rules: library.rules, patternRoots: config.scan.devRoots) }
}
