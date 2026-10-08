import AppKit
import Foundation
import Observation
import SpaceKitCore

/// Sidebar destinations.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case explore, dev, ai, automation, history, rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .dev: return "Dev Intelligence"
        case .ai: return "AI Development"
        case .automation: return "Automation"
        case .history: return "History"
        case .rules: return "Rules Library"
        }
    }

    var subtitle: String {
        switch self {
        case .explore: return "Where is my disk going?"
        case .dev: return "What is actually safe to remove?"
        case .ai: return "Local models and caches"
        case .automation: return "Automate the cleanup"
        case .history: return "What grew?"
        case .rules: return "What SpaceKit knows"
        }
    }

    var symbol: String {
        switch self {
        case .explore: return "circle.circle"
        case .dev: return "hammer"
        case .ai: return "cpu"
        case .automation: return "clock.arrow.2.circlepath"
        case .history: return "chart.xyaxis.line"
        case .rules: return "books.vertical"
        }
    }
}

/// App-wide state. Everything heavy (scans, analysis, cleanup) runs off the main actor;
/// results are published back here.
@Observable
@MainActor
final class AppModel {
    // MARK: Context
    private(set) var context: SpaceKitContext
    var section: AppSection = .explore
    var showOnboarding = false
    var showSafety = false
    var errorMessage: String?

    // MARK: Explore
    private(set) var tree: ScanTree?
    private(set) var scanProgress: ScanProgress?
    private(set) var progressSnapshot: ScanProgress.Snapshot?
    private(set) var scanPath: String
    /// The directory at the center of the map.
    var focus: DirNode?
    var selection: MapItem?
    var hovered: MapItem?
    private var backStack: [DirNode] = []
    private(set) var categories: [CategorySlice] = []
    /// Labels folders until an analysis exists.
    private var libraryIndex: RuleIndex {
        didSet { ruleCache.removeAll() }
    }
    var ruleIndex: RuleIndex { analysisResult?.ruleIndex ?? libraryIndex }
    var visualization: UISettings.Visualization
    var colorMode: UISettings.ColorMode
    var mapDepth: Int
    private var scanTask: Task<Void, Never>?
    /// Bumped by every scan; a scan that finishes after a newer one started is dropped.
    @ObservationIgnored private var scanGeneration = 0
    /// When the scan behind `tree` started. Plans made from it don't touch loose files changed after this.
    @ObservationIgnored private(set) var treeScanStarted = Date()
    /// The folder the current `tree` is a scan of (`scanPath` moves on as soon as another scan starts).
    @ObservationIgnored private var treeScanPath: String?
    /// Off-main work reading the trees, and tree changes waiting for it to finish (see `readingTrees`).
    @ObservationIgnored private var treeReaders = 0
    @ObservationIgnored private var treeWriters: [CheckedContinuation<Void, Never>] = []

    // MARK: Intelligence
    /// The latest analysis with its AI report and rule index.
    private(set) var analysisResult: AnalysisResult? {
        didSet { ruleCache.removeAll() }
    }
    var analysis: Analysis? { analysisResult?.analysis }
    var aiReport: AIReport? { analysisResult?.aiReport }
    private(set) var analysisProgress: ScanProgress?
    /// Bumped by every analysis; only the latest one's result is used.
    @ObservationIgnored private var analysisGeneration = 0

    // MARK: Cleanup
    /// Items collected from Explore and Dev Intelligence for one combined review.
    var cleanupList: [CleanupItem] = []
    /// The plan currently shown in the cleanup sheet.
    var pendingCleanup: PendingCleanup?
    /// The job currently open in the job editor.
    var jobDraft: JobDraft?
    /// Bumped whenever the tree changes in place, so cached map layouts are rebuilt.
    private(set) var treeRevision = 0 {
        didSet { itemsCache.removeAll() }
    }
    /// Rules currently being re-evaluated after a tool command ran (cards show a spinner).
    private(set) var refreshingRules: Set<String> = []
    /// Cleanups removing things right now. Quitting waits for them (see `AppDelegate`).
    private(set) var runningCleanups = 0
    /// Set when the person chose to quit while a cleanup ran; the app quits once the last one finishes.
    @ObservationIgnored private var quitWhenCleanupsFinish = false

    // Render-time caches. Not observed, so filling them during a view update doesn't trigger another one.
    @ObservationIgnored private var itemsCache: [UInt: [DiskItem]] = [:]
    @ObservationIgnored private var ruleCache: [String: Rule?] = [:]
    @ObservationIgnored private var rulesIncludingDisabledCache: [Rule]?

    // MARK: Automation & history
    private(set) var jobStates: [String: JobState] = [:]
    private(set) var suggestions: [Suggestion] = []
    private(set) var agentStatus: LaunchAgent.Status?
    private(set) var recovered90Days: UInt64 = 0
    private(set) var journal: [JournalEntry] = []
    private(set) var history: [HistoryRecord] = []
    private(set) var volumes: [VolumeCapacity] = []
    /// Live capacity of the volume being explored, refreshed every few seconds while the app is active.
    private(set) var scanCapacity: VolumeCapacity?
    /// Size of the Trash, once measured (nil if it can't be read without Full Disk Access).
    private(set) var trashBytes: UInt64?
    /// Local Time Machine snapshots on the startup disk; they hold deleted files' space as "purgeable".
    private(set) var localSnapshotCount = 0
    @ObservationIgnored private var capacityMonitor: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private(set) var runningJobID: String?

    struct PendingCleanup: Identifiable {
        let id = UUID()
        var title: String
        var plan: CleanupPlan
        /// Called with the report after a successful run.
        var completion: (@MainActor (CleanupReport) -> Void)?
    }

    init() {
        let context = SpaceKitContext.load()
        self.context = context
        scanPath = PathUtil.expand(context.config.scan.defaultPath)
        libraryIndex = context.ruleIndex
        visualization = context.config.ui.visualization
        colorMode = context.config.ui.colorBy
        mapDepth = context.config.ui.mapDepth
        showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
        refreshVolumes()
        refreshAutomation()
        startMonitoring()
        AppDelegate.model = self
    }

    var config: SpaceKitConfig { context.config }
    var library: RuleLibrary { context.library }
    var paths: SpaceKitPaths { context.paths }
    var historyStore: HistoryStore { context.history }
    var configFileExists: Bool { context.configStore.exists }
    var configError: String? { context.configError }

    // MARK: Config

    /// Applies one change to the config file as it is on disk now, so changes made elsewhere (jobs added with the CLI,
    /// hand edits) are kept, and saves it. A config file that doesn't parse is left untouched and the problem shown.
    /// Only what changed is reloaded: the rule library only when rule settings differ.
    func updateConfig(_ change: (inout SpaceKitConfig) -> Void) {
        let before = context.config
        let saved: SpaceKitConfig
        do {
            saved = try context.configStore.update(change)
        } catch let error as ConfigError {
            errorMessage =
                "SpaceKit didn't save this change because the config file has a problem: \(error.localizedDescription). "
                + "Fix it (spacekit config validate), then Reload."
            return
        } catch {
            errorMessage = "Couldn't save the config: \(error.localizedDescription)"
            return
        }
        if saved.rules != before.rules || context.configError != nil {
            reloadContext()
        } else if saved != before {
            context.config = saved
            if saved.jobs != before.jobs { refreshJournal() }
        }
    }

    /// Writes the commented starter config if there's no config file yet, and loads it.
    func createStarterConfig() {
        do {
            try context.configStore.initialize()
        } catch {
            errorMessage = "Couldn't create the config: \(error.localizedDescription)"
        }
        reloadContext()
    }

    /// Opens the config file in the default editor, creating the starter config first if there's none.
    func openConfigInEditor() {
        do {
            try context.configStore.initialize()
        } catch {
            errorMessage = "Couldn't create the config: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: paths.configFile))
    }

    /// Re-reads config and rules from disk (after edits in the YAML file).
    func reloadContext() {
        rulesIncludingDisabledCache = nil
        context = SpaceKitContext.load(paths: context.paths)
        libraryIndex = context.ruleIndex
        analysisResult?.reindex(rules: context.library.rules)
        if let error = context.configError { errorMessage = "Config problem: \(error)" }
        refreshAutomation()
    }

    // MARK: Automation

    /// Everything on the Automation screen, including the agent status (which asks launchd).
    func refreshAutomation() {
        refreshJournal()
        refreshHistory()
        refreshAgentStatus()
    }

    /// Cheap file reads only: job state, suggestions and the journal.
    func refreshJournal() {
        let context = self.context
        jobStates = context.jobStates.load()
        suggestions = context.suggestions.all()
        journal = context.journal.entries(since: Age.days(90).ago())
        recovered90Days = journal.reduce(0) { $0 + $1.bytes }
    }

    func refreshAgentStatus() {
        let paths = context.paths
        Task.detached {
            let status = LaunchAgent(paths: paths).status()
            await MainActor.run { self.agentStatus = status }
        }
    }

    func refreshHistory() {
        history = context.history.records(since: Age.days(365).ago())
    }

    /// Evaluates a job off the main actor, marking it as running meanwhile (cards show a spinner).
    func evaluate(_ job: Job, with runner: JobRunner) async -> Result<JobEvaluation, Error> {
        runningJobID = job.id
        defer { runningJobID = nil }
        return await Task.detached { Result { try runner.evaluate(job) } }.value
    }

    // MARK: Scanning

    var isScanning: Bool { scanProgress != nil }

    func scan(_ path: String? = nil) {
        if let path { scanPath = PathUtil.expand(path) }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let started = Date()
        let progress = ScanProgress()
        scanProgress = progress
        progressSnapshot = progress.snapshot
        selection = nil
        hovered = nil
        backStack = []
        let options = context.scanOptions
        let root = scanPath
        scanTask = Task {
            // Lives only as long as the scan task (cancelled in the defer below).
            let poller = Task { @MainActor in
                while !Task.isCancelled {
                    self.progressSnapshot = progress.snapshot
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { poller.cancel() }
            do {
                let tree = try await Scanner(options: options).scan(root, progress: progress)
                guard self.scanGeneration == generation else { return }
                if tree.stats.cancelled {
                    self.stopScan()
                } else {
                    self.finishScan(tree, path: root, started: started)
                }
            } catch {
                guard self.scanGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
                self.stopScan()
            }
        }
    }

    func cancelScan() {
        scanProgress?.cancel()
    }

    /// A stopped scan's tree is missing whatever wasn't reached yet, so it isn't shown, analysed or recorded in
    /// history. The previous scan stays on screen.
    private func stopScan() {
        scanProgress = nil
        progressSnapshot = nil
        if let treeScanPath { scanPath = treeScanPath }
    }

    private func finishScan(_ tree: ScanTree, path: String, started: Date) {
        self.tree = tree
        treeScanPath = path
        treeScanStarted = started
        treeRevision += 1
        focus = tree.root
        scanProgress = nil
        progressSnapshot = nil
        analysisResult = nil
        categories = CategoryBreakdown.compute(tree: tree)
        refreshVolumes()
        refreshTrash(resync: false)
        analyze()
    }

    /// The scan root's subfolders while scanning, for progressive drawing.
    var liveChildren: [DirNode] { scanProgress?.liveChildren ?? [] }

    // MARK: Navigation

    func open(_ node: DirNode) {
        guard node !== focus, !node.children.isEmpty || !node.files.isEmpty else { return }
        if let focus { backStack.append(focus) }
        focus = node
        selection = nil
    }

    func goUp() {
        guard let focus, let parent = focus.parent, !(parent.name.isEmpty && parent.parent == nil && tree?.isMultiRoot == false) else {
            return
        }
        backStack.append(focus)
        selection = .item(.directory(focus))
        self.focus = parent
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        focus = previous
        selection = nil
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { focus?.parent != nil }

    /// Folders from the scan root to the focus, for the breadcrumb.
    var breadcrumb: [DirNode] {
        guard let focus else { return [] }
        return focus.ancestors.filter { !$0.name.isEmpty } + [focus]
    }

    // MARK: Intelligence

    var isAnalysing: Bool { analysisProgress != nil }

    /// Evaluates all rules, reusing the Explore scan when it covers the locations rules need. Starting again (after a
    /// rescan, or Refresh) stops the analysis in progress and drops its result, so the current tree is always the one
    /// analysed.
    func analyze() {
        analysisProgress?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        let progress = ScanProgress()
        analysisProgress = progress
        let analyzer = context.analyzer
        let tree = self.tree
        let window = context.config.automation.activeModelWindow
        let rules = context.library.rules
        let patternRoots = context.config.scan.devRoots
        let history = context.history
        Task {
            let result: AnalysisResult
            do {
                result = try await self.readingTrees {
                    let analysis = try await analyzer.analyze(reusing: tree, progress: progress)
                    return AnalysisResult(analysis, rules: rules, activeModelWindow: window, patternRoots: patternRoots)
                }
            } catch {
                guard self.analysisGeneration == generation else { return }
                self.analysisProgress = nil
                self.errorMessage = error.localizedDescription
                return
            }
            guard self.analysisGeneration == generation else { return }
            self.analysisProgress = nil
            self.analysisResult = result
            let analysis = result.analysis
            if let tree = self.tree, tree.covers(PathUtil.home) {
                self.categories = CategoryBreakdown.compute(tree: tree, findings: analysis.findings)
            }
            try? history.recordSnapshot(analysis: analysis)
            self.refreshHistory()
        }
    }

    // MARK: Monitoring

    /// Keeps capacity live: every few seconds (one cheap system call per volume), and immediately when SpaceKit
    /// becomes active, which is also when the Trash is re-measured (you may have emptied it in Finder).
    private func startMonitoring() {
        observers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshVolumes()
                    self.refreshTrash(resync: true)
                    self.refreshSnapshots()
                }
            })
        startCapacityLoop()
        refreshSnapshots()
    }

    private func startCapacityLoop() {
        capacityMonitor?.cancel()
        capacityMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshVolumes()
            }
        }
    }

    // MARK: State changes
    // Extensions in other files change private state only through these methods, so it keeps its private setters.

    func beginCleanup() { runningCleanups += 1 }

    /// Asks the app to quit once the last running cleanup finishes.
    func quitWhenCleanupsAreDone() { quitWhenCleanupsFinish = true }

    /// Moves the map to `node` with an empty back history, after the folders it held were removed.
    func refocus(on node: DirNode?) {
        focus = node
        backStack = []
    }

    func endCleanup() {
        runningCleanups -= 1
        if runningCleanups == 0 && quitWhenCleanupsFinish {
            quitWhenCleanupsFinish = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Shrinks the trees and findings in place after a cleanup: trashed items move into the Trash folder (they
    /// still use space until it's emptied), the AI report and category totals update only if they were affected.
    func applyToTreesAndFindings(_ removals: [Removal]) {
        let exploreChanged = tree.map { Removal.apply(removals, to: $0) } ?? false
        if var result = analysisResult, !result.apply(removals, exploreTree: tree).isEmpty { analysisResult = result }

        // Categories: subtract instead of recomputing.
        if exploreChanged {
            categories = CategoryBreakdown.subtracting(removals, from: categories, findings: analysis?.findings ?? [])
            treeRevision += 1
        }
    }

    /// Re-evaluates a few rules with a targeted scan of only their locations, then merges the results.
    func refreshFindings(ruleIDs: Set<String>) {
        let rules = ruleIDs.compactMap { library.rule(id: $0) }
        guard !rules.isEmpty, analysis != nil else { return }
        refreshingRules.formUnion(ruleIDs)
        let context = self.context
        Task {
            let fresh = try? await context.analyzer.analyze(rules: rules)
            refreshingRules.subtract(ruleIDs)
            guard let fresh else { return }
            analysisResult?.merge(context.result(of: fresh), for: ruleIDs)
        }
    }

    func trashMeasured(_ bytes: UInt64?) {
        if trashBytes != bytes { trashBytes = bytes }
    }

    /// The trees changed in place (the Trash folder re-synced): rebuild map layouts and category totals.
    func treesChangedInPlace() {
        treeRevision += 1
        if let tree, tree.roots == ["/"] || tree.covers(PathUtil.home) {
            categories = CategoryBreakdown.compute(tree: tree, findings: analysis?.findings ?? [], capacity: scanCapacity)
        }
    }

    /// Re-reads volume capacities. Values only change (and views only update) when the disk changed.
    func refreshVolumes() {
        let fresh = VolumeTable.current().userVisibleVolumes.compactMap { VolumeCapacity.of(path: $0.mountPoint) }
        if fresh != volumes { volumes = fresh }
        let live = VolumeCapacity.of(path: scanPath)
        if live != scanCapacity {
            scanCapacity = live
            if let live, let tree, tree.roots == ["/"] {
                categories = CategoryBreakdown.updatingHidden(categories, capacity: live, scannedBytes: tree.root.size)
            }
        }
    }

    func refreshSnapshots() {
        Task {
            let count = await Task.detached(priority: .utility) { LocalSnapshots.list().count }.value
            if count != localSnapshotCount { localSnapshotCount = count }
        }
    }

    // MARK: Tree access

    /// Runs `work` off the main actor while it reads the scan trees (rule evaluation, map layout). Trees change only
    /// on the main actor and only while no such work runs (see `untilTreesAreFree`), because a `DirNode` can't be
    /// read while it changes.
    func readingTrees<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        treeReaders += 1
        defer { endTreeRead() }
        return try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private func endTreeRead() {
        treeReaders -= 1
        guard treeReaders == 0 else { return }
        let waiting = treeWriters
        treeWriters = []
        for writer in waiting { writer.resume() }
    }

    /// Suspends until no off-main work reads the trees. Change them right after, without suspending in between.
    func untilTreesAreFree() async {
        while treeReaders > 0 {
            await withCheckedContinuation { treeWriters.append($0) }
        }
    }

    /// Every rule that loads, disabled ones included, so Settings can turn them back on. Cached until the next reload.
    func rulesIncludingDisabled() -> [Rule] {
        if let cached = rulesIncludingDisabledCache { return cached }
        let rules = RuleLibrary.load(directories: context.ruleDirectories).rules
        rulesIncludingDisabledCache = rules
        return rules
    }

    func rule(for path: String?) -> Rule? {
        guard let path else { return nil }
        if let cached = ruleCache[path] { return cached }
        let rule = ruleIndex.rule(for: path)
        ruleCache[path] = rule
        return rule
    }

    /// A directory's items, largest first; cached until the tree changes.
    func items(of node: DirNode) -> [DiskItem] {
        if let cached = itemsCache[node.address] { return cached }
        let items = node.items
        itemsCache[node.address] = items
        return items
    }

    // MARK: Finder

    func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func chooseFolder() {
        if let path = AppModel.askForFolder(prompt: "Scan") { scan(path) }
    }

    /// Asks for one folder (hidden ones shown) and returns its path, or `nil` if the person cancelled.
    static func askForFolder(prompt: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let prompt { panel.prompt = prompt }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
