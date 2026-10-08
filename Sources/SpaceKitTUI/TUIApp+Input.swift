import Foundation
import SpaceKitCore

extension TUIApp {
    var isCleaning: Bool {
        if case .cleaning = state.activity { return true }
        return false
    }

    func handle(_ key: TerminalKey) {
        if key == .character("q") || key == .control("c"), state.modal == nil || isCleaning {
            requestQuit()
            return
        }
        if state.modal != nil {
            handleModal(key)
            return
        }
        guard !isTooSmall(terminal.size) else { return }
        switch key {
        case .tab:
            switchTab(by: 1)
            return
        case .backTab:
            switchTab(by: -1)
            return
        case .character(let c) where ("1"..."5").contains(c):
            selectTab(Tab(rawValue: Int(String(c))! - 1)!)
            return
        case .character("?"):
            showHelp()
            return
        default:
            break
        }
        switch state.tab {
        case .explore: handleExplore(key)
        case .dev: handleDev(key)
        case .ai: handleAI(key)
        case .jobs: handleJobs(key)
        case .history: break
        }
    }

    func switchTab(by delta: Int) {
        let count = Tab.allCases.count
        selectTab(Tab(rawValue: (state.tab.rawValue + delta + count) % count)!)
    }

    func selectTab(_ tab: Tab) {
        state.tab = tab
        switch tab {
        case .dev, .ai: startAnalysis()
        case .jobs: refreshAutomation()
        case .history: refreshHistory()
        case .explore: break
        }
    }

    /// Keys that start a scan or a cleanup wait while a cleanup runs, so two never run at once.
    func refuseWhileBusy() -> Bool {
        guard let activity = state.activity else { return false }
        flash("Busy: \(activity.text)")
        return true
    }

    func handleModal(_ key: TerminalKey) {
        guard var modal = state.modal else { return }
        let size = terminal.size
        let layout = modalLayout(modal, width: size.columns, bodyHeight: size.rows - TUIApp.chromeRows)
        let page = max(1, layout.visible - 1)
        switch key {
        case .up, .character("k"): modal.scroll(by: -1, in: layout)
        case .down, .character("j"): modal.scroll(by: 1, in: layout)
        case .pageUp: modal.scroll(by: -page, in: layout)
        case .pageDown, .space: modal.scroll(by: page, in: layout)
        case .home: modal.scroll(by: -layout.rows.count, in: layout)
        case .end: modal.scroll(by: layout.rows.count, in: layout)
        case .character("y"), .character("Y"):
            guard let onConfirm = modal.onConfirm else {
                state.modal = nil
                return
            }
            guard modal.hasShownEveryLine else {
                flash("Scroll through the whole list first (↓ or PgDn), then press y")
                return
            }
            state.modal = nil
            onConfirm()
            return
        case .character("n"), .character("N"), .escape, .character("q"), .control("c"):
            state.modal = nil
            return
        default:
            if modal.onConfirm == nil { state.modal = nil }
            return
        }
        state.modal = modal
    }

    func showHelp() {
        state.modal = Modal(
            title: "Keys",
            lines: [
                "Tab / 1–5      switch view",
                "↑ ↓ PgUp PgDn  move (also scrolls dialogs)",
                "→ / Enter      open folder · details",
                "← / Backspace  go up",
                "t              toggle treemap (Explore)",
                "space          mark for cleanup",
                "d              clean marked items (asks first)",
                "o              reveal in Finder",
                "r              rescan (Explore) · refresh (Dev)",
                "n              create a job from a rule (Dev)",
                "e / m          enable / change mode of a job",
                "x              run a job now (asks first)",
                "i              install / remove the background agent",
                "q              quit (waits for a running cleanup)",
                "",
                "Everything is checked by the safety guard. Removed items go to the Trash",
                "unless your config says otherwise. See docs/SAFETY.md.",
            ])
    }

    // MARK: Explore

    func handleExplore(_ key: TerminalKey) {
        let items = state.current?.items ?? []
        let pageSize = max(1, terminal.size.rows - 8)
        switch key {
        case .up, .character("k"): state.explore.move(by: -1, count: items.count)
        case .down, .character("j"): state.explore.move(by: 1, count: items.count)
        case .pageUp: state.explore.move(by: -pageSize, count: items.count)
        case .pageDown: state.explore.move(by: pageSize, count: items.count)
        case .home: state.explore.move(by: -items.count, count: items.count)
        case .end: state.explore.move(by: items.count, count: items.count)
        case .right, .enter, .character("l"):
            guard let item = selectedItem(items), let directory = item.directory,
                !directory.children.isEmpty || !directory.files.isEmpty
            else { return }
            state.current = directory
            state.explore = ListCursor()
        case .left, .backspace, .character("h"):
            guard let current = state.current, let parent = current.parent,
                !parent.name.isEmpty || parent.parent != nil || !parent.children.isEmpty
            else { return }
            state.current = parent
            state.explore = ListCursor(selection: parent.items.firstIndex { $0.directory === current } ?? 0)
        case .character("t"):
            state.mapMode.toggle()
        case .character("r"):
            guard !refuseWhileBusy() else { return }
            startScan()
        case .space:
            guard let item = selectedItem(items), let path = item.path else { return }
            if state.marked[path] != nil {
                state.marked[path] = nil
            } else {
                state.marked[path] = cleanupItem(for: item)
            }
            state.explore.move(by: 1, count: items.count)
        case .character("o"):
            if let path = selectedItem(items)?.path { _ = Shell.run("/usr/bin/open", ["-R", path], timeout: 5) }
        case .character("d"):
            guard !refuseWhileBusy() else { return }
            var plan = CleanupPlan(items: Array(state.marked.values))
            if plan.items.isEmpty {
                guard let item = selectedItem(items).flatMap(cleanupItem(for:)) else { return }
                plan.items = [item]
            }
            confirmCleanup(plan, title: "Clean selected items")
        default:
            break
        }
    }

    func selectedItem(_ items: [DiskItem]) -> DiskItem? {
        items.indices.contains(state.explore.selection) ? items[state.explore.selection] : nil
    }

    func cleanupItem(for item: DiskItem) -> CleanupItem? {
        state.tree.flatMap { CleanupItem(item, in: $0, ruleID: item.path.flatMap { state.ruleIndex.rule(for: $0)?.id }) }
    }

    // MARK: Dev Intelligence

    /// Moves a selection off a group heading (or past the end) to the nearest row below it that keys act on,
    /// so the highlighted row is always the one `d`, `n` or Enter use.
    static func settle(_ selection: Int, on selectable: [Int]) -> Int {
        selectable.first { $0 >= selection } ?? selectable.last ?? 0
    }

    func handleDev(_ key: TerminalKey) {
        if key == .character("r") {
            guard !refuseWhileBusy() else { return }
            guard state.analysisProgress == nil else {
                flash("Already analysing")
                return
            }
            state.result = nil
            startAnalysis()
            return
        }
        let rows = state.devRows
        let selectable = rows.indices.filter { rows[$0].finding != nil }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: state.dev.selection) ?? 0
        func select(_ p: Int) { state.dev.selection = selectable[min(max(p, 0), selectable.count - 1)] }
        guard let finding = rows[selectable[position]].finding else { return }
        switch key {
        case .up, .character("k"): select(position - 1)
        case .down, .character("j"): select(position + 1)
        case .pageUp: select(position - 10)
        case .pageDown: select(position + 10)
        case .space:
            guard finding.isCleanable else { return }
            if state.markedRules.contains(finding.id) {
                state.markedRules.remove(finding.id)
            } else {
                state.markedRules.insert(finding.id)
            }
            select(position + 1)
        case .enter, .right:
            showFinding(finding)
        case .character("d"), .character("c"):
            guard !refuseWhileBusy(), let analysis = state.analysis else { return }
            let marked = state.markedRules
            let findings = rows.compactMap(\.finding).filter { marked.isEmpty ? $0.id == finding.id : marked.contains($0.id) }
            let plan = CleanupPlan.make(
                findings: findings.filter(\.isCleanable), trashPreference: context.trashPreference(for: .rule),
                scanStarted: analysis.scanStarted)
            let name = findings.count == 1 ? TerminalText.sanitize(findings[0].rule.name) : "\(findings.count) rules"
            confirmCleanup(plan, title: "Clean \(name)")
        case .character("n"):
            createJob(for: finding.rule)
        default:
            break
        }
    }

    func showFinding(_ finding: Finding) {
        let rule = finding.rule
        let clean = TerminalText.sanitize
        var lines: [String] = []
        if let description = rule.description { lines.append(clean(description)) }
        lines.append("")
        lines += finding.terminalFacts().map { "\($0.label): ".dim + $0.value }
        lines.append("")
        for item in finding.items {
            let age = item.idleDays().map { "\($0)d" } ?? "–"
            lines.append(
                ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true) + "  " + ANSI.pad(age, to: 5, alignRight: true) + "  "
                    + clean(PathUtil.abbreviate(item.path)))
        }
        state.modal = Modal(title: clean(rule.name), lines: lines)
    }

    // MARK: AI

    func handleAI(_ key: TerminalKey) {
        let rows = state.aiRows
        let selectable = rows.indices.filter { rows[$0].model != nil }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: state.ai.selection) ?? 0
        func select(_ p: Int) { state.ai.selection = selectable[min(max(p, 0), selectable.count - 1)] }
        switch key {
        case .up, .character("k"): select(position - 1)
        case .down, .character("j"): select(position + 1)
        case .pageUp: select(position - 10)
        case .pageDown: select(position + 10)
        case .character("d"), .character("x"):
            guard !refuseWhileBusy(), let model = rows[selectable[position]].model, let analysis = state.analysis else { return }
            guard let plan = CleanupPlan.removing(model, scanStarted: analysis.scanStarted) else {
                flash("\(TerminalText.sanitize(model.name)) can't be removed on its own; remove the models that use it")
                return
            }
            confirmCleanup(plan, title: "Remove \(TerminalText.sanitize(model.name))")
        default:
            break
        }
    }
}

extension TUIApp.State {
    /// Dev Intelligence rows: a heading per safety level, then its findings.
    var devRows: [(group: String, finding: Finding?)] {
        guard let analysis else { return [] }
        var rows: [(String, Finding?)] = []
        for level in SafetyLevel.allCases {
            let findings = analysis.findings(level)
            guard !findings.isEmpty else { continue }
            rows.append(("\(level.emoji) \(level.title) · \(ByteCount.format(analysis.total(level)))", nil))
            for finding in findings { rows.append((finding.rule.group, finding)) }
        }
        return rows
    }

    /// AI rows: a heading per tool, then its models.
    var aiRows: [(tool: String, model: AIModel?)] {
        guard let aiReport else { return [] }
        var rows: [(String, AIModel?)] = []
        for tool in aiReport.tools {
            rows.append((tool.name, nil))
            for model in tool.models { rows.append((tool.name, model)) }
        }
        return rows
    }

    /// Puts each list's selection on a row keys act on. Runs whenever the rows change, so drawing and key
    /// handling can trust the stored selection.
    mutating func settleSelections() {
        let findings = devRows
        dev.selection = TUIApp.settle(dev.selection, on: findings.indices.filter { findings[$0].finding != nil })
        let models = aiRows
        ai.selection = TUIApp.settle(ai.selection, on: models.indices.filter { models[$0].model != nil })
    }
}
