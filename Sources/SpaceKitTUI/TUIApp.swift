import Foundation
import SpaceKitCore
import Synchronization

/// The full-screen terminal interface: `spacekit tui [path]`.
///
/// Threading: the UI thread (the one that calls `run()`) owns `state` and `context`, and is the only thread
/// that reads or changes a finished scan tree. Scans, analyses, job evaluations and cleanups run on
/// background threads that work on their own copies and report back through `inbox`; the UI thread applies
/// their results between frames.
public final class TUIApp {
    enum Tab: Int, CaseIterable {
        case explore, dev, ai, jobs, history
        var title: String {
            switch self {
            case .explore: return "Explore"
            case .dev: return "Dev Intelligence"
            case .ai: return "AI"
            case .jobs: return "Automation"
            case .history: return "History"
            }
        }
    }

    struct Modal {
        var title: String
        var lines: [String]
        /// Always visible below the scrolling lines, whatever the scroll position.
        var footer: [String] = []
        /// The first wrapped row on screen.
        var offset = 0
        /// Which of `lines` have been drawn whole. Jumping to the end doesn't mark the lines in between.
        var shown: [Bool]
        /// Runs when the person presses `y`, once every line has been on screen. `nil` makes it an information box.
        var onConfirm: (() -> Void)?
        var confirmLabel = "y confirm · n cancel"

        init(title: String, lines: [String], footer: [String] = [], onConfirm: (() -> Void)? = nil, confirmLabel: String? = nil) {
            self.title = title
            self.lines = lines
            self.footer = footer
            self.shown = Array(repeating: false, count: lines.count)
            self.onConfirm = onConfirm
            if let confirmLabel { self.confirmLabel = confirmLabel }
        }

        var hasShownEveryLine: Bool { !shown.contains(false) }

        /// Moves by `delta` rows without scrolling past either end of `layout`.
        mutating func scroll(by delta: Int, in layout: ModalLayout) {
            offset = layout.clamp(offset + delta)
        }

        /// The rows to draw with `layout`, recording which lines they show whole. Call it with what is drawn.
        mutating func display(_ layout: ModalLayout) -> Range<Int> {
            offset = layout.clamp(offset)
            guard layout.visible > 0 else { return offset..<offset }
            let range = offset..<min(layout.rows.count, offset + layout.visible)
            guard let first = range.first, let last = range.last else { return range }
            for line in layout.rows[first].line...layout.rows[last].line {
                let rows = layout.lineRows[line]
                // A line taller than the box can't be on screen at once; its last row coming into view counts.
                let isTall = rows.count > layout.visible
                if range.contains(rows.upperBound - 1), isTall || range.contains(rows.lowerBound) { shown[line] = true }
            }
            return range
        }
    }

    /// A dialog fitted to the screen: its lines wrapped to the box width, and how many rows of them fit.
    struct ModalLayout {
        var boxWidth: Int
        /// Every wrapped row and the index of the line it belongs to.
        var rows: [(text: String, line: Int)]
        /// The rows of each line.
        var lineRows: [Range<Int>]
        var footer: [String]
        var visible: Int

        func clamp(_ offset: Int) -> Int {
            min(max(offset, 0), max(0, rows.count - max(1, visible)))
        }
    }

    /// A selected row and the scroll position that keeps it in view.
    struct ListCursor {
        var selection = 0
        var window = ScrollWindow()

        mutating func move(by delta: Int, count: Int) {
            guard count > 0 else { return }
            selection = min(max(selection + delta, 0), count - 1)
        }

        mutating func visibleRows(_ visible: Int, count: Int) -> Range<Int> {
            window.follow(selection: selection, visible: visible, count: count)
        }
    }

    /// Long-running work that other keys must wait for.
    enum Activity {
        case evaluating(String)
        case cleaning

        var text: String {
            switch self {
            case .evaluating(let name): return "Evaluating \(name)…"
            case .cleaning: return "Cleaning… (q quits when it's done)"
            }
        }
    }

    /// Results posted by background threads.
    enum Event: Sendable {
        case scanned(generation: Int, Result<ScanTree, Error>)
        case analysed(generation: Int, Result<AnalysisResult, Error>)
        case refreshed(generation: Int, ruleIDs: Set<String>, Result<AnalysisResult, Error>)
        case evaluated(Job, Result<(JobEvaluation, CleanupPlan), Error>)
        /// The evaluation is set when the cleanup ran a job, so the result is recorded against it.
        case cleaned(CleanupReport, JobEvaluation?)
    }

    struct State {
        var tab: Tab = .explore
        var rootPath: String
        /// Bumped by every scan; results from an older scan are dropped.
        var generation = 0
        /// When the current scan started. Plans made from it don't touch loose files changed after this.
        var scanStarted = Date()
        var tree: ScanTree?
        var scanProgress: ScanProgress?
        var current: DirNode?
        var explore = ListCursor()
        var mapMode = false
        var marked: [String: CleanupItem] = [:]

        var result: AnalysisResult? {
            didSet { settleSelections() }
        }
        var analysis: Analysis? { result?.analysis }
        var aiReport: AIReport? { result?.aiReport }
        var analysisProgress: ScanProgress?
        var dev = ListCursor()
        var markedRules: Set<String> = []
        var ai = ListCursor()
        /// Removals that arrived while an analysis was reading the tree; applied when it finishes.
        var pendingRemovals: [Removal] = []

        var jobSelection = 0
        var automation: AutomationSnapshot?
        var history: HistorySnapshot?
        var activity: Activity?
        var quitWhenIdle = false

        /// Labels folders before an analysis exists.
        var libraryIndex: RuleIndex
        var ruleIndex: RuleIndex { result?.ruleIndex ?? libraryIndex }
        var modal: Modal?
        var flash: String?
        var flashUntil = Date.distantPast
        var quit = false
        var error: String?
        /// Printed after the terminal is restored.
        var exitMessage: String?
    }

    /// Hands results from background threads to the UI thread.
    final class Inbox: Sendable {
        private let events = Mutex<[Event]>([])
        func post(_ event: Event) { events.withLock { $0.append(event) } }
        func drain() -> [Event] { events.withLock { events in defer { events = [] }; return events } }
    }

    let terminal = Terminal()
    let inbox = Inbox()
    var state: State
    var context: SpaceKitContext

    public init(context: SpaceKitContext, path: String?) {
        let root = PathUtil.expand(path ?? context.config.scan.defaultPath)
        state = State(rootPath: root, libraryIndex: context.ruleIndex)
        self.context = context
    }

    public func run() {
        terminal.enter()
        startScan()
        var lastRender = Date.distantPast
        while !state.quit {
            let events = inbox.drain()
            for event in events { handle(event) }
            // A termination signal held during a cleanup has already put the terminal back: stop drawing and
            // reading keys, and quit once the cleanup is done.
            if terminal.heldSignal != nil {
                if isCleaning { state.quitWhenIdle = true } else { state.quit = true }
                Thread.sleep(forTimeInterval: 0.08)
                continue
            }
            let keys = terminal.readKeys(timeout: 0.08)
            // A signal arriving while keys were awaited has restored the terminal too: don't act or draw on it.
            guard terminal.heldSignal == nil else { continue }
            for key in keys where !state.quit { handle(key) }
            if !events.isEmpty || !keys.isEmpty || Date().timeIntervalSince(lastRender) > 0.12 {
                render()
                lastRender = Date()
            }
        }
        terminal.restore()
        if let message = state.exitMessage { print(message) }
        if let signal = terminal.heldSignal {
            fflush(stdout)
            raise(signal)
        }
    }

    // MARK: Background work

    func startScan() {
        state.scanProgress?.cancel()
        state.analysisProgress?.cancel()
        let progress = ScanProgress()
        state.generation += 1
        state.scanStarted = Date()
        state.scanProgress = progress
        state.tree = nil
        state.current = nil
        state.explore = ListCursor()
        state.result = nil
        state.analysisProgress = nil
        state.pendingRemovals = []
        state.dev = ListCursor()
        state.ai = ListCursor()
        state.error = nil
        let (path, options, generation, inbox) = (state.rootPath, context.scanOptions, state.generation, inbox)
        Thread.detachNewThread {
            let result = Result { try Scanner(options: options).scan(path, progress: progress) }
            inbox.post(.scanned(generation: generation, result))
        }
    }

    func startAnalysis() {
        guard state.analysis == nil, state.analysisProgress == nil, let tree = state.tree else { return }
        let progress = ScanProgress()
        state.analysisProgress = progress
        let (context, generation, inbox) = (context, state.generation, inbox)
        Thread.detachNewThread {
            let result = Result { () throws -> AnalysisResult in
                let analysis = try context.analyzer.analyzeSync(reusing: tree, progress: progress)
                try? context.history.recordSnapshot(analysis: analysis)
                return context.result(of: analysis)
            }
            inbox.post(.analysed(generation: generation, result))
        }
    }

    /// Re-evaluates only `ruleIDs`, after their tool commands freed space their own way.
    func refreshFindings(ruleIDs: Set<String>) {
        let rules = ruleIDs.compactMap { self.context.library.rule(id: $0) }
        guard !rules.isEmpty, state.analysis != nil else { return }
        let (context, generation, inbox) = (context, state.generation, inbox)
        Thread.detachNewThread {
            let result = Result { context.result(of: try context.analyzer.analyzeSync(rules: rules)) }
            inbox.post(.refreshed(generation: generation, ruleIDs: ruleIDs, result))
        }
    }

    func handle(_ event: Event) {
        switch event {
        case .scanned(let generation, let result):
            guard generation == state.generation else { return }
            state.scanProgress = nil
            switch result {
            case .success(let tree):
                state.tree = tree
                state.current = tree.root
                if state.tab == .dev || state.tab == .ai { startAnalysis() }
            case .failure(let error):
                state.error = TerminalText.sanitize(error.localizedDescription)
            }
        case .analysed(let generation, let result):
            guard generation == state.generation else { return }
            state.analysisProgress = nil
            switch result {
            case .success(let fresh):
                state.result = fresh
            case .failure(let error):
                state.error = TerminalText.sanitize(error.localizedDescription)
            }
            let pending = state.pendingRemovals
            state.pendingRemovals = []
            applyRemovals(pending)
        case .refreshed(let generation, let ruleIDs, let result):
            guard generation == state.generation, case .success(let fresh) = result else { return }
            state.result?.merge(fresh, for: ruleIDs)
        case .evaluated(let job, let result):
            jobEvaluated(job, result)
        case .cleaned(let report, let job):
            cleanupFinished(report, job: job)
        }
    }

    func flash(_ message: String) {
        state.flash = message
        state.flashUntil = Date().addingTimeInterval(4)
    }

    /// Quits now, or once the running cleanup is done: stopping mid-run would leave it half finished.
    func requestQuit() {
        guard case .cleaning = state.activity else {
            state.quit = true
            return
        }
        state.quitWhenIdle = true
        flash("Waiting for the cleanup to finish, then quitting")
    }
}
